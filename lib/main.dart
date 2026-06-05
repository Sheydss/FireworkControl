import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:usb_serial/usb_serial.dart';
import 'package:file_picker/file_picker.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Models
// ─────────────────────────────────────────────────────────────────────────────

enum FireworkState {
  preparation, armement, play, pause, stop, fin;

  int get value => index;

  String get label => switch (this) {
    FireworkState.preparation => '🔧 Préparation',
    FireworkState.armement    => '⚡ Armement',
    FireworkState.play        => '▶ Lancer',
    FireworkState.pause       => '⏸ Pause',
    FireworkState.stop        => '⏹ Stop',
    FireworkState.fin         => '✅ Fin',
  };

  Color get color => switch (this) {
    FireworkState.preparation => const Color(0xFF3B82F6),
    FireworkState.armement    => const Color(0xFFF59E0B),
    FireworkState.play        => const Color(0xFF10B981),
    FireworkState.pause       => const Color(0xFF8B5CF6),
    FireworkState.stop        => const Color(0xFFEF4444),
    FireworkState.fin         => const Color(0xFF6B7280),
  };
}

class HeadFile {
  final String name;
  final int    size;
  const HeadFile({required this.name, required this.size});
}

class Head {
  final String      mac;
  String            name;
  bool              active;
  int               state;
  double?           lat;
  double?           lng;
  List<HeadFile>    files      = [];
  int               freeBytes  = 0;
  int               totalBytes = 0;

  Head({
    required this.mac,
    required this.name,
    required this.active,
    required this.state,
    this.lat,
    this.lng,
  });
}

class LogEntry {
  final String  time;
  final String  message;
  final LogType type;
  const LogEntry({required this.time, required this.message, required this.type});
}

enum LogType { log, error, status }

// ─────────────────────────────────────────────────────────────────────────────
//  Constants
// ─────────────────────────────────────────────────────────────────────────────

const int    kChunkSize     = 128;  // raw bytes per chunk
const String kPlanDir       = '/plans/';

// ─────────────────────────────────────────────────────────────────────────────
//  Main
// ─────────────────────────────────────────────────────────────────────────────

void main() => runApp(const FireworksApp());

class FireworksApp extends StatelessWidget {
  const FireworksApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title:  'Contrôle Feux d\'Artifice',
    theme:  ThemeData.dark().copyWith(
      scaffoldBackgroundColor: const Color(0xFF111827),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF3B82F6),
        surface: Color(0xFF1F2937),
      ),
    ),
    home:   const HomePage(),
    debugShowCheckedModeBanner: false,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
//  HomePage
// ─────────────────────────────────────────────────────────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // ── USB ───────────────────────────────────────────────────────────────────
  UsbPort?  _port;
  bool      _connected  = false;
  String    _recvBuffer = '';

  // ── App state ─────────────────────────────────────────────────────────────
  FireworkState?             _currentState;
  final TextEditingController _filenameCtrl = TextEditingController();
  final List<Head>            _heads        = [];
  final List<LogEntry>        _logs         = [];

  // ── File transfer state ───────────────────────────────────────────────────
  bool        _transferring      = false;
  double      _transferProgress  = 0;
  int         _transferChunks    = 0;
  int         _transferCurrent   = 0;
  Uint8List?  _pendingFileData;
  String      _pendingFileName   = '';
  List<String> _pendingTargets   = [];

  // ── Selected file for upload ──────────────────────────────────────────────
  Uint8List?  _selectedFileData;
  String      _selectedFileName  = '';
  String      _selectedFileError = '';

  @override
  void initState() {
    super.initState();
    final test = Uint8List.fromList(utf8.encode('123456789'));
    _addLog('CRC sanity: 0x${_crc16(test, 0, test.length).toRadixString(16).toUpperCase()}');
    _filenameCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _port?.close();
    _filenameCtrl.dispose();
    super.dispose();
  }

  // ── Logging ───────────────────────────────────────────────────────────────

  void _addLog(String message, {LogType type = LogType.log}) {
    final now  = DateTime.now();
    final time = '${now.hour.toString().padLeft(2,'0')}:'
                 '${now.minute.toString().padLeft(2,'0')}:'
                 '${now.second.toString().padLeft(2,'0')}';
    setState(() {
      _logs.insert(0, LogEntry(time: time, message: message, type: type));
      if (_logs.length > 100) _logs.removeLast();
    });
  }

  // ── USB ───────────────────────────────────────────────────────────────────

  Future<void> _connect() async {
    final devices = await UsbSerial.listDevices();
    if (devices.isEmpty) {
      _addLog('Aucun appareil USB détecté', type: LogType.error);
      return;
    }
    final port = await devices.first.create();
    if (port == null) { _addLog('Port invalide', type: LogType.error); return; }
    if (!await port.open()) { _addLog('Ouverture échouée', type: LogType.error); return; }

    await port.setDTR(true);
    await port.setRTS(true);
    await port.setPortParameters(115200, UsbPort.DATABITS_8,
                                 UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);

    port.inputStream?.listen((data) {
      _recvBuffer += utf8.decode(data, allowMalformed: true);
      final lines = _recvBuffer.split('\n');
      _recvBuffer = lines.last;
      for (final line in lines.sublist(0, lines.length - 1)) {
        final t = line.trim();
        if (t.isNotEmpty) _handleBridgeMessage(t);
      }
    });

    setState(() { _port = port; _connected = true; });
    _addLog('Connecté');
    _sendToBridge({'cmd': 'get_heads'});
  }

  Future<void> _disconnect() async {
    await _port?.close();
    setState(() { _port = null; _connected = false; });
    _addLog('Déconnecté');
  }

  void _sendToBridge(Map<String, dynamic> obj) {
    if (_port == null) return;
    _port!.write(Uint8List.fromList(utf8.encode('${jsonEncode(obj)}\n')));
  }

  // ── Bridge message handler ────────────────────────────────────────────────

  void _handleBridgeMessage(String line) {
    Map<String, dynamic> msg;
    try { msg = jsonDecode(line) as Map<String, dynamic>; }
    catch (_) { if (_isPrintable(line)) _addLog(line); return; }

    final type = msg['type'] as String? ?? '';

    switch (type) {
      case 'log':
        _addLog(msg['msg'] as String? ?? '');

      case 'error':
        _addLog('❌ ${msg['msg']}', type: LogType.error);

      case 'head_connected':
        _addLog('🔌 Tête: ${msg['name'] ?? msg['mac']}');
        _sendToBridge({'cmd': 'get_heads'});

      case 'head_list':
        final raw = msg['heads'] as List? ?? [];
        setState(() {
          // Update existing or add new
          for (final h in raw) {
            final mac = h['mac'] as String;
            final existing = _heads.indexWhere((x) => x.mac == mac);
            if (existing >= 0) {
              _heads[existing].name   = h['name']   as String? ?? mac;
              _heads[existing].active = h['active']  as bool?   ?? false;
              _heads[existing].state  = h['state']   as int?    ?? -1;
            } else {
              _heads.add(Head(
                mac:    mac,
                name:   h['name']   as String? ?? mac,
                active: h['active'] as bool?   ?? false,
                state:  h['state']  as int?    ?? -1,
              ));
            }
          }
        });

      case 'status':
        final mac = msg['mac'] as String;
        setState(() {
          final idx = _heads.indexWhere((h) => h.mac == mac);
          if (idx >= 0) {
            _heads[idx].state = msg['state'] as int? ?? -1;
            if (msg['lat'] != null) _heads[idx].lat = (msg['lat'] as num).toDouble();
            if (msg['lng'] != null) _heads[idx].lng = (msg['lng'] as num).toDouble();
          }
        });
        _addLog('📡 $mac: ${_stateLabel(msg['state'] as int? ?? -1)}',
                type: LogType.status);

      case 'file_list':
        final mac   = msg['mac'] as String;
        final files = (msg['files'] as List? ?? [])
            .map((f) => HeadFile(
                  name: f['name'] as String,
                  size: f['size'] as int? ?? 0,
                ))
            .toList();
        setState(() {
          final idx = _heads.indexWhere((h) => h.mac == mac);
          if (idx >= 0) {
            _heads[idx].files      = files;
            _heads[idx].freeBytes  = msg['free_bytes']  as int? ?? 0;
            _heads[idx].totalBytes = msg['total_bytes'] as int? ?? 0;
          }
        });

      case 'chunk_ack':
        final idx     = msg['idx']     as int?  ?? 0;
        final success = msg['success'] as bool? ?? false;
        if (success && _transferring) {
          setState(() {
            _transferCurrent = idx + 1;
            _transferProgress = _transferChunks > 0
                ? _transferCurrent / _transferChunks
                : 0;
          });
          // Send next chunk
          _sendNextChunk(idx + 1);
        }
      
      case 'file_start_ack':
        if (_transferring) {
          _sendNextChunk(0);
        }

      case 'transfer_complete':
        final failed = (msg['failed'] as List? ?? []).cast<String>();
        setState(() { _transferring = false; _transferProgress = 0; });
        if (failed.isEmpty) {
          _addLog('✅ Transfert de ${msg['name']} réussi');
        } else {
          _addLog('⚠ Transfert terminé — échec: ${failed.join(', ')}',
                  type: LogType.error);
        }
        // Refresh file lists
        for (final h in _heads) {
          _sendToBridge({'cmd': 'get_files', 'mac': h.mac});
        }
    }
  }

  // ── File transfer ─────────────────────────────────────────────────────────

  Future<void> _pickFile() async {
    setState(() { _selectedFileError = ''; });

    final result = await FilePicker.platform.pickFiles(
      type:           FileType.custom,
      allowedExtensions: ['json'],
      withData:       true,
    );

    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final data = file.bytes;
    if (data == null) { setState(() { _selectedFileError = 'Impossible de lire le fichier'; }); return; }

    // Validate JSON structure
    try {
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      if (!json.containsKey('name') ||
          !json.containsKey('tops') ||
          !json.containsKey('hash')) {
        setState(() {
          _selectedFileError = 'Format invalide — champs requis: name, tops, hash';
        });
        return;
      }
    } catch (_) {
      setState(() { _selectedFileError = 'JSON invalide'; });
      return;
    }

    setState(() {
      _selectedFileData  = data;
      _selectedFileName  = file.name;
      _selectedFileError = '';
    });
    _addLog('📂 Fichier chargé: ${file.name} (${data.length} octets)');
  }

  void _startTransfer(List<String> targets) {
    if (_selectedFileData == null || _selectedFileName.isEmpty) return;
    if (targets.isEmpty) return;

    final data     = _selectedFileData!;
    final name     = _selectedFileName;
    final chunks   = (data.length / kChunkSize).ceil();
    final totalCrc = _crc16(data, 0, data.length);

    setState(() {
      _transferring     = true;
      _transferProgress = 0;
      _transferChunks   = chunks;
      _transferCurrent  = 0;
      _pendingFileData  = data;
      _pendingFileName  = name;
      _pendingTargets   = targets;
    });

    _addLog('📤 Envoi de $name → ${targets.length} tête(s)');

    _sendToBridge({
      'cmd':     'file_start',
      'name':    name,
      'size':    data.length,
      'chunks':  chunks,
      'targets': targets,
    });

    // Wait for file_start ACKs then send first chunk
    // Bridge will respond with chunk_ack for idx=-1 style...
    // Actually we send first chunk after a short delay
    //Future.delayed(const Duration(milliseconds: 500), () => _sendNextChunk(0));
  }

  void _sendNextChunk(int idx) {
    if (!_transferring || _pendingFileData == null) return;

    final data = _pendingFileData!;

    if (idx >= _transferChunks) {
      // All chunks sent — send file_end
      final totalCrc = _crc16(data, 0, data.length);
      _sendToBridge({
        'cmd':       'file_end',
        'name':      _pendingFileName,
        'total_crc': totalCrc,
      });
      return;
    }

    final offset    = idx * kChunkSize;
    final end       = (offset + kChunkSize).clamp(0, data.length);
    final chunk     = data.sublist(offset, end);
    final b64       = base64Encode(chunk);
    final crc       = _crc16(chunk, 0, chunk.length);

    _sendToBridge({
      'cmd':  'file_chunk',
      'idx':  idx,
      'data': b64,
      'crc':  crc,
    });
  }

  Future<void> _deleteFile(String mac, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1F2937),
        title: const Text('Confirmer la suppression',
                          style: TextStyle(color: Colors.white)),
        content: Text('Supprimer $name de cette tête et ses modules ?',
                      style: const TextStyle(color: Color(0xFF9CA3AF))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer',
                              style: TextStyle(color: Color(0xFFEF4444))),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _sendToBridge({'cmd': 'file_delete', 'mac': mac, 'name': name});
    _addLog('🗑 Suppression de $name depuis $mac');
  }

  void _refreshFiles() {
    for (final h in _heads) {
      _sendToBridge({'cmd': 'get_files', 'mac': h.mac});
    }
  }

  // ── CRC-16 CCITT-False ────────────────────────────────────────────────────

  int _crc16(Uint8List data, int offset, int length) {
    int crc = 0xFFFF;
    for (int i = offset; i < offset + length; i++) {
        crc ^= (data[i] << 8) & 0xFFFF;  // ← mask added
        for (int j = 0; j < 8; j++) {
            crc = (crc & 0x8000) != 0
                  ? ((crc << 1) ^ 0x1021) & 0xFFFF
                  : (crc << 1) & 0xFFFF;
        }
    }
    return crc;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  bool _isPrintable(String s) {
    if (s.isEmpty) return false;
    for (final c in s.runes) { if (c < 32 || c > 126) return false; }
    return true;
  }

  String _stateLabel(int state) => switch (state) {
    0 => 'Préparation', 1 => 'Armement', 2 => 'Lecture',
    3 => 'Pause', 4 => 'Arrêt', 5 => 'Fin', _ => 'Inconnu',
  };

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(children: [
        _buildHeader(),
        Expanded(
          child: DefaultTabController(
            length: 2,
            child: Column(children: [
              const TabBar(
                tabs: [
                  Tab(text: 'Contrôle'),
                  Tab(text: 'Fichiers'),
                ],
                indicatorColor: Color(0xFF3B82F6),
                labelColor:     Colors.white,
              ),
              Expanded(
                child: TabBarView(children: [
                  _buildControlTab(),
                  _buildFilesTab(),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    ),
  );

  // ── Header ────────────────────────────────────────────────────────────────

  Widget _buildHeader() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: const BoxDecoration(
      color:  Color(0xFF1F2937),
      border: Border(bottom: BorderSide(color: Color(0xFF374151))),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text('🎆 Feux d\'Artifice',
                   style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
        GestureDetector(
          onTap: _connected ? _disconnect : _connect,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color:        _connected ? const Color(0xFF065F46) : const Color(0xFF374151),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_connected ? '🟢 Connecté' : '🔴 Connecter',
                        style: const TextStyle(fontSize: 13)),
          ),
        ),
      ],
    ),
  );

  // ── Control tab ───────────────────────────────────────────────────────────

  Widget _buildControlTab() => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_currentState != null) ...[
        _buildCurrentState(),
        const SizedBox(height: 16),
      ],
      _buildFilenameInput(),
      const SizedBox(height: 20),
      _buildStateButtons(),
      const SizedBox(height: 20),
      _buildHeadList(),
      const SizedBox(height: 20),
      _buildLog(),
    ]),
  );

  Widget _buildCurrentState() => Container(
    padding:    const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color:        const Color(0xFF1F2937),
      borderRadius: BorderRadius.circular(12),
      border:       Border.all(color: const Color(0xFF374151)),
    ),
    child: Column(children: [
      const Text('État actuel', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12)),
      const SizedBox(height: 4),
      Text(_currentState?.name ?? '',
           style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
    ]),
  );

  Widget _buildFilenameInput() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('FICHIER DE PLAN', style: TextStyle(
        color: Color(0xFF9CA3AF), fontSize: 12,
        fontWeight: FontWeight.w600, letterSpacing: 1)),
      const SizedBox(height: 8),
      TextField(
        controller: _filenameCtrl,
        style:      const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText:      'ex: plan1.json',
          hintStyle:     const TextStyle(color: Color(0xFF6B7280)),
          filled:        true,
          fillColor:     const Color(0xFF1F2937),
          border:        OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                           borderSide: const BorderSide(color: Color(0xFF374151))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                           borderSide: const BorderSide(color: Color(0xFF374151))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                           borderSide: const BorderSide(color: Color(0xFF3B82F6))),
        ),
        autocorrect: false, enableSuggestions: false,
      ),
    ],
  );

  Widget _buildStateButtons() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('COMMANDES', style: TextStyle(
        color: Color(0xFF9CA3AF), fontSize: 12,
        fontWeight: FontWeight.w600, letterSpacing: 1)),
      const SizedBox(height: 8),
      GridView.count(
        crossAxisCount: 2, shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: 2.8,
        children: FireworkState.values.map((state) {
          final isPlay     = state == FireworkState.play;
          final isDisabled = !_connected || (isPlay && _filenameCtrl.text.trim().isEmpty);
          final isActive   = _currentState == state;
          return GestureDetector(
            onTap: isDisabled ? null : () {
              final payload = <String, dynamic>{'cmd': 'set_state', 'state': state.value};
              if (isPlay) payload['filename'] = _filenameCtrl.text.trim();
              _sendToBridge(payload);
              setState(() => _currentState = state);
              _addLog('→ ${state.name}');
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: BoxDecoration(
                color:        isDisabled ? state.color.withOpacity(0.3) : state.color,
                borderRadius: BorderRadius.circular(10),
                border:       isActive ? Border.all(color: Colors.white, width: 2) : null,
              ),
              alignment: Alignment.center,
              child: Text(state.label,
                          style: TextStyle(
                            color: isDisabled ? Colors.white.withOpacity(0.5) : Colors.white,
                            fontSize: 14, fontWeight: FontWeight.bold)),
            ),
          );
        }).toList(),
      ),
    ],
  );

  Widget _buildHeadList() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('TÊTES (${_heads.length})', style: const TextStyle(
        color: Color(0xFF9CA3AF), fontSize: 12,
        fontWeight: FontWeight.w600, letterSpacing: 1)),
      const SizedBox(height: 8),
      if (_heads.isEmpty)
        const Text('Aucune tête', style: TextStyle(color: Color(0xFF6B7280), fontStyle: FontStyle.italic))
      else
        ..._heads.map((h) => Container(
          margin:     const EdgeInsets.only(bottom: 8),
          padding:    const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color:        const Color(0xFF1F2937),
            borderRadius: BorderRadius.circular(10),
            border:       Border.all(color: const Color(0xFF374151)),
          ),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(h.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              Text(h.mac, style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12)),
            ])),
            Container(
              padding:    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color:        h.active ? const Color(0xFF10B981) : const Color(0xFF6B7280),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(_stateLabel(h.state),
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ]),
        )),
    ],
  );

  Widget _buildLog() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('JOURNAL', style: TextStyle(
          color: Color(0xFF9CA3AF), fontSize: 12,
          fontWeight: FontWeight.w600, letterSpacing: 1)),
        GestureDetector(
          onTap: () => setState(() => _logs.clear()),
          child: const Text('Effacer', style: TextStyle(color: Color(0xFF6B7280), fontSize: 12)),
        ),
      ]),
      const SizedBox(height: 8),
      Container(
        height:     180,
        padding:    const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color:        const Color(0xFF1F2937),
          borderRadius: BorderRadius.circular(8),
          border:       Border.all(color: const Color(0xFF374151)),
        ),
        child: _logs.isEmpty
          ? const Center(child: Text('Aucun message',
              style: TextStyle(color: Color(0xFF6B7280), fontStyle: FontStyle.italic)))
          : ListView.builder(
              itemCount: _logs.length,
              itemBuilder: (_, i) => Text(
                '${_logs[i].time} ${_logs[i].message}',
                style: TextStyle(
                  color: switch (_logs[i].type) {
                    LogType.error  => const Color(0xFFFCA5A5),
                    LogType.status => const Color(0xFF6EE7B7),
                    LogType.log    => const Color(0xFFD1D5DB),
                  },
                  fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
      ),
    ],
  );

  // ── Files tab ─────────────────────────────────────────────────────────────

  Widget _buildFilesTab() => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

      // ── File picker ───────────────────────────────────────────────────────
      _buildSectionTitle('FICHIER À ENVOYER'),
      const SizedBox(height: 8),
      Container(
        padding:    const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color:        const Color(0xFF1F2937),
          borderRadius: BorderRadius.circular(10),
          border:       Border.all(color: const Color(0xFF374151)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            ElevatedButton.icon(
              onPressed: _connected ? _pickFile : null,
              icon:  const Icon(Icons.folder_open, size: 18),
              label: const Text('Choisir un fichier'),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF374151)),
            ),
            const SizedBox(width: 12),
            if (_selectedFileName.isNotEmpty)
              Expanded(child: Text(_selectedFileName,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                overflow: TextOverflow.ellipsis)),
          ]),
          if (_selectedFileError.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_selectedFileError, style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12)),
          ],
          if (_selectedFileData != null) ...[
            const SizedBox(height: 8),
            Text('${_formatBytes(_selectedFileData!.length)}  •  ${((_selectedFileData!.length / kChunkSize).ceil())} chunks',
                 style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12)),
          ],
        ]),
      ),

      // ── Transfer progress ─────────────────────────────────────────────────
      if (_transferring) ...[
        const SizedBox(height: 12),
        Container(
          padding:    const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color:        const Color(0xFF1F2937),
            borderRadius: BorderRadius.circular(10),
            border:       Border.all(color: const Color(0xFF374151)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Envoi de $_pendingFileName',
                   style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              Text('$_transferCurrent / $_transferChunks chunks',
                   style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12)),
            ]),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value:            _transferProgress,
              backgroundColor:  const Color(0xFF374151),
              valueColor:       const AlwaysStoppedAnimation(Color(0xFF3B82F6)),
            ),
          ]),
        ),
      ],

      const SizedBox(height: 20),

      // ── Head file lists ───────────────────────────────────────────────────
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        _buildSectionTitle('FICHIERS PAR TÊTE'),
        GestureDetector(
          onTap: _connected ? _refreshFiles : null,
          child: const Text('🔄 Rafraîchir',
                            style: TextStyle(color: Color(0xFF3B82F6), fontSize: 13)),
        ),
      ]),
      const SizedBox(height: 8),

      if (_heads.isEmpty)
        const Text('Aucune tête connectée',
                   style: TextStyle(color: Color(0xFF6B7280), fontStyle: FontStyle.italic))
      else
        ..._heads.map((head) => _buildHeadFileCard(head)),
    ]),
  );

  Widget _buildHeadFileCard(Head head) {
    final selectedHeads = <String>[];

    return Container(
      margin:     const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color:        const Color(0xFF1F2937),
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: const Color(0xFF374151)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Head header
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(head.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              Text(head.mac, style: const TextStyle(color: Color(0xFF6B7280), fontSize: 11)),
              if (head.totalBytes > 0) ...[
                const SizedBox(height: 4),
                // Storage bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value:           head.totalBytes > 0
                                     ? (head.totalBytes - head.freeBytes) / head.totalBytes
                                     : 0,
                    backgroundColor: const Color(0xFF374151),
                    valueColor:      const AlwaysStoppedAnimation(Color(0xFF3B82F6)),
                    minHeight:       6,
                  ),
                ),
                const SizedBox(height: 2),
                Text('${_formatBytes(head.freeBytes)} libre / ${_formatBytes(head.totalBytes)}',
                     style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 11)),
              ],
            ])),
            // Send to this head button
            if (_selectedFileData != null && !_transferring)
              TextButton(
                onPressed: () => _startTransfer([head.mac]),
                style: TextButton.styleFrom(foregroundColor: const Color(0xFF3B82F6)),
                child: const Text('Envoyer'),
              ),
          ]),
        ),

        const Divider(color: Color(0xFF374151), height: 1),

        // File list
        if (head.files.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child:   Text('Aucun fichier',
                          style: TextStyle(color: Color(0xFF6B7280), fontStyle: FontStyle.italic)),
          )
        else
          ...head.files.map((file) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child:   Row(children: [
              const Icon(Icons.description_outlined, size: 16, color: Color(0xFF6B7280)),
              const SizedBox(width: 8),
              Expanded(child: Text(file.name,
                                  style: const TextStyle(fontSize: 13))),
              Text(_formatBytes(file.size),
                   style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12)),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _deleteFile(head.mac, file.name),
                child: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFEF4444)),
              ),
            ]),
          )),

        // Send to all button (only shown if file selected)
        if (_selectedFileData != null && !_transferring && head == _heads.last) ...[
          const Divider(color: Color(0xFF374151), height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child:   SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _startTransfer(_heads.map((h) => h.mac).toList()),
                icon:  const Icon(Icons.send, size: 18),
                label: Text('Envoyer à toutes les têtes (${_heads.length})'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF3B82F6),
                  padding:         const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _buildSectionTitle(String title) => Text(title, style: const TextStyle(
    color: Color(0xFF9CA3AF), fontSize: 12,
    fontWeight: FontWeight.w600, letterSpacing: 1));
}