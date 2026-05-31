// import 'package:flutter/material.dart';

// void main() {
//   runApp(const MainApp());
// }

// class MainApp extends StatelessWidget {
//   const MainApp({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return const MaterialApp(
//       home: Scaffold(
//         body: Center(
//           child: Text('Hello World!'),
//         ),
//       ),
//     );
//   }
// }


import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:usb_serial/usb_serial.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Models
// ─────────────────────────────────────────────────────────────────────────────

enum FireworkState {
  preparation,
  armement,
  play,
  pause,
  stop,
  fin;

  int get value => index;

  String get label => switch (this) {
        FireworkState.preparation => '🔧 Préparation',
        FireworkState.armement   => '⚡ Armement',
        FireworkState.play       => '▶ Lancer',
        FireworkState.pause      => '⏸ Pause',
        FireworkState.stop       => '⏹ Stop',
        FireworkState.fin        => '✅ Fin',
      };

  Color get color => switch (this) {
        FireworkState.preparation => const Color(0xFF3B82F6),
        FireworkState.armement   => const Color(0xFFF59E0B),
        FireworkState.play       => const Color(0xFF10B981),
        FireworkState.pause      => const Color(0xFF8B5CF6),
        FireworkState.stop       => const Color(0xFFEF4444),
        FireworkState.fin        => const Color(0xFF6B7280),
      };
}

class Head {
  final String mac;
  final String name;
  final bool   active;
  final int    state;
  final double? lat;
  final double? lng;

  const Head({
    required this.mac,
    required this.name,
    required this.active,
    required this.state,
    this.lat,
    this.lng,
  });

  Head copyWith({
    String?  name,
    bool?    active,
    int?     state,
    double?  lat,
    double?  lng,
  }) => Head(
        mac:    mac,
        name:   name    ?? this.name,
        active: active  ?? this.active,
        state:  state   ?? this.state,
        lat:    lat     ?? this.lat,
        lng:    lng     ?? this.lng,
      );

  static String stateLabel(int state) => switch (state) {
        0 => 'Préparation',
        1 => 'Armement',
        2 => 'Lecture',
        3 => 'Pause',
        4 => 'Arrêt',
        5 => 'Fin',
        _ => 'Inconnu',
      };
}

class LogEntry {
  final String    time;
  final String    message;
  final LogType   type;

  const LogEntry({
    required this.time,
    required this.message,
    required this.type,
  });
}

enum LogType { log, error, status }

// ─────────────────────────────────────────────────────────────────────────────
//  Main
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  runApp(const FireworksApp());
}

class FireworksApp extends StatelessWidget {
  const FireworksApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title:  'Contrôle Feux d\'Artifice',
      theme:  ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF111827),
        colorScheme: ColorScheme.dark(
          primary:   const Color(0xFF3B82F6),
          surface:   const Color(0xFF1F2937),
        ),
      ),
      home:   const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
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
  // ── USB serial state ───────────────────────────────────────────────────────
  UsbPort?             _port;
  bool                 _connected   = false;
  String               _recvBuffer  = '';

  // ── App state ──────────────────────────────────────────────────────────────
  FireworkState?       _currentState;
  final TextEditingController _filenameCtrl = TextEditingController();
  final List<Head>     _heads  = [];
  final List<LogEntry> _logs   = [];

  // ── Scroll controller for log ──────────────────────────────────────────────
  final ScrollController _logScroll = ScrollController();

  @override
  void dispose() {
    _port?.close();
    _filenameCtrl.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  // ── Logging ────────────────────────────────────────────────────────────────

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

  // ── USB connection ─────────────────────────────────────────────────────────

  Future<void> _connect() async {
    final devices = await UsbSerial.listDevices();
    if (devices.isEmpty) {
      _addLog('Aucun appareil USB détecté', type: LogType.error);
      return;
    }

    final device = devices.first;
    final port   = await device.create();
    if (port == null) {
      _addLog('Impossible de créer le port', type: LogType.error);
      return;
    }

    final opened = await port.open();
    if (!opened) {
      _addLog('Impossible d\'ouvrir le port', type: LogType.error);
      return;
    }

    await port.setDTR(true);
    await port.setRTS(true);
    await port.setPortParameters(
      115200,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );

    // Listen for incoming data
    port.inputStream?.listen((data) {
      _recvBuffer += utf8.decode(data, allowMalformed: true);
      final lines = _recvBuffer.split('\n');
      _recvBuffer = lines.last;
      for (final line in lines.sublist(0, lines.length - 1)) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) _handleBridgeMessage(trimmed);
      }
    });

    setState(() {
      _port      = port;
      _connected = true;
    });

    _addLog('Connecté à ${device.productName ?? 'USB Device'}');

    // Request head list
    _sendToBridge({'cmd': 'get_heads'});
  }

  Future<void> _disconnect() async {
    await _port?.close();
    setState(() {
      _port      = null;
      _connected = false;
    });
    _addLog('Déconnecté');
  }

  // ── Send to bridge ─────────────────────────────────────────────────────────

  void _sendToBridge(Map<String, dynamic> obj) {
    if (_port == null) {
      _addLog('Non connecté', type: LogType.error);
      return;
    }
    final json = '${jsonEncode(obj)}\n';
    _port!.write(Uint8List.fromList(utf8.encode(json)));
  }

  // ── Handle messages from bridge ────────────────────────────────────────────

  void _handleBridgeMessage(String line) {
    try {
      final msg = jsonDecode(line) as Map<String, dynamic>;
      final type = msg['type'] as String? ?? '';

      switch (type) {
        case 'log':
          _addLog(msg['msg'] as String? ?? '');

        case 'error':
          _addLog('❌ ${msg['msg']}', type: LogType.error);

        case 'head_connected':
          _addLog('🔌 Tête connectée: ${msg['name'] ?? msg['mac']}');
          _sendToBridge({'cmd': 'get_heads'});

        case 'head_list':
          final rawHeads = msg['heads'] as List<dynamic>? ?? [];
          setState(() {
            _heads
              ..clear()
              ..addAll(rawHeads.map((h) => Head(
                    mac:    h['mac']    as String,
                    name:   h['name']   as String? ?? h['mac'] as String,
                    active: h['active'] as bool?   ?? false,
                    state:  h['state']  as int?    ?? 0,
                  )));
          });

        case 'status':
          final mac      = msg['mac'] as String;
          final newState = msg['state'] as int? ?? 0;
          setState(() {
            final idx = _heads.indexWhere((h) => h.mac == mac);
            if (idx >= 0) {
              _heads[idx] = _heads[idx].copyWith(
                state: newState,
                lat:   (msg['lat'] as num?)?.toDouble(),
                lng:   (msg['lng'] as num?)?.toDouble(),
              );
            }
          });
          _addLog(
            '📡 ${msg['mac']}: ${Head.stateLabel(newState)}',
            type: LogType.status,
          );

        case 'send_status':
          if (!(msg['success'] as bool? ?? true)) {
            _addLog('⚠ Envoi échoué vers ${msg['mac']}',
                    type: LogType.error);
          }

        default:
          // Non-JSON debug line from bridge
          _addLog(line);
      }
    } catch (_) {
      if (_isPrintable(line)) _addLog(line);
    }
  }

  bool _isPrintable(String s) {
    if (s.isEmpty) return false;
    for (final char in s.runes) {
      // Allow standard printable ASCII (32-126) only
      if (char < 32 || char > 126) return false;
    }
    return true;
  }

  // ── Send state ─────────────────────────────────────────────────────────────

  void _sendState(FireworkState state) {
    final payload = <String, dynamic>{
      'cmd':   'set_state',
      'state': state.value,
    };

    if (state == FireworkState.play) {
      final filename = _filenameCtrl.text.trim();
      if (filename.isEmpty) {
        _addLog('Veuillez entrer un nom de fichier', type: LogType.error);
        return;
      }
      payload['filename'] = filename;
    }

    _sendToBridge(payload);
    setState(() => _currentState = state);
    _addLog('→ État: ${state.name}');
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_currentState != null) _buildCurrentState(),
                    const SizedBox(height: 16),
                    _buildFilenameInput(),
                    const SizedBox(height: 20),
                    _buildStateButtons(),
                    const SizedBox(height: 20),
                    _buildHeadList(),
                    const SizedBox(height: 20),
                    _buildLog(),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF1F2937),
        border: Border(bottom: BorderSide(color: Color(0xFF374151))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            '🎆 Contrôle Feux d\'Artifice',
            style: TextStyle(
              fontSize:   17,
              fontWeight: FontWeight.bold,
              color:      Colors.white,
            ),
          ),
          GestureDetector(
            onTap: _connected ? _disconnect : _connect,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color:        _connected
                              ? const Color(0xFF065F46)
                              : const Color(0xFF374151),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _connected ? '🟢 Connecté' : '🔴 Connecter',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Current state indicator ────────────────────────────────────────────────

  Widget _buildCurrentState() {
    return Container(
      padding:     const EdgeInsets.all(16),
      decoration:  BoxDecoration(
        color:        const Color(0xFF1F2937),
        borderRadius: BorderRadius.circular(12),
        border:       Border.all(color: const Color(0xFF374151)),
      ),
      child: Column(
        children: [
          const Text(
            'État actuel',
            style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            _currentState?.name ?? '',
            style: const TextStyle(
              color:      Colors.white,
              fontSize:   24,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // ── Filename input ─────────────────────────────────────────────────────────

  Widget _buildFilenameInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'FICHIER DE PLAN',
          style: TextStyle(
            color:         Color(0xFF9CA3AF),
            fontSize:      12,
            fontWeight:    FontWeight.w600,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller:    _filenameCtrl,
          style:         const TextStyle(color: Colors.white),
          decoration:    InputDecoration(
            hintText:        'ex: plan1.json',
            hintStyle:       const TextStyle(color: Color(0xFF6B7280)),
            filled:          true,
            fillColor:       const Color(0xFF1F2937),
            border:          OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:   const BorderSide(color: Color(0xFF374151)),
            ),
            enabledBorder:   OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:   const BorderSide(color: Color(0xFF374151)),
            ),
            focusedBorder:   OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:   const BorderSide(color: Color(0xFF3B82F6)),
            ),
          ),
          autocorrect:   false,
          enableSuggestions: false,
        ),
      ],
    );
  }

  // ── State buttons ──────────────────────────────────────────────────────────

  Widget _buildStateButtons() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'COMMANDES',
          style: TextStyle(
            color:         Color(0xFF9CA3AF),
            fontSize:      12,
            fontWeight:    FontWeight.w600,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount:   2,
          shrinkWrap:       true,
          physics:          const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 8,
          mainAxisSpacing:  8,
          childAspectRatio: 2.8,
          children: FireworkState.values.map((state) {
            final isPlay     = state == FireworkState.play;
            final isDisabled = !_connected ||
                               (isPlay && _filenameCtrl.text.trim().isEmpty);
            final isActive   = _currentState == state;

            return GestureDetector(
              onTap: isDisabled ? null : () => _sendState(state),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                decoration: BoxDecoration(
                  color:        isDisabled
                                ? state.color.withOpacity(0.3)
                                : state.color,
                  borderRadius: BorderRadius.circular(10),
                  border:       isActive
                                ? Border.all(color: Colors.white, width: 2)
                                : null,
                ),
                alignment: Alignment.center,
                child: Text(
                  state.label,
                  style: TextStyle(
                    color:      isDisabled
                                ? Colors.white.withOpacity(0.5)
                                : Colors.white,
                    fontSize:   14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  // ── Head list ──────────────────────────────────────────────────────────────

  Widget _buildHeadList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'TÊTES CONNECTÉES (${_heads.length})',
          style: const TextStyle(
            color:         Color(0xFF9CA3AF),
            fontSize:      12,
            fontWeight:    FontWeight.w600,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 8),
        if (_heads.isEmpty)
          const Text(
            'Aucune tête détectée',
            style: TextStyle(
              color:     Color(0xFF6B7280),
              fontStyle: FontStyle.italic,
            ),
          )
        else
          ...(_heads.map((head) => _buildHeadCard(head))),
      ],
    );
  }

  Widget _buildHeadCard(Head head) {
    return Container(
      margin:     const EdgeInsets.only(bottom: 8),
      padding:    const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        const Color(0xFF1F2937),
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: const Color(0xFF374151)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  head.name.isNotEmpty ? head.name : head.mac,
                  style: const TextStyle(
                    color:      Colors.white,
                    fontSize:   15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  head.mac,
                  style: const TextStyle(
                    color:   Color(0xFF6B7280),
                    fontSize: 12,
                  ),
                ),
                if (head.lat != null)
                  Text(
                    '📍 ${head.lat!.toStringAsFixed(6)}, '
                    '${head.lng!.toStringAsFixed(6)}',
                    style: const TextStyle(
                      color:   Color(0xFF6B7280),
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical:    5,
            ),
            decoration: BoxDecoration(
              color:        head.active
                            ? const Color(0xFF10B981)
                            : const Color(0xFF6B7280),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              Head.stateLabel(head.state),
              style: const TextStyle(
                color:      Colors.white,
                fontSize:   12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Log ────────────────────────────────────────────────────────────────────

  Widget _buildLog() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'JOURNAL',
              style: TextStyle(
                color:         Color(0xFF9CA3AF),
                fontSize:      12,
                fontWeight:    FontWeight.w600,
                letterSpacing: 1,
              ),
            ),
            GestureDetector(
              onTap: () => setState(() => _logs.clear()),
              child: const Text(
                'Effacer',
                style: TextStyle(
                  color:   Color(0xFF6B7280),
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height:     200,
          padding:    const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color:        const Color(0xFF1F2937),
            borderRadius: BorderRadius.circular(8),
            border:       Border.all(color: const Color(0xFF374151)),
          ),
          child: _logs.isEmpty
              ? const Center(
                  child: Text(
                    'Aucun message',
                    style: TextStyle(
                      color:     Color(0xFF6B7280),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                )
              : ListView.builder(
                  controller:  _logScroll,
                  itemCount:   _logs.length,
                  itemBuilder: (_, i) {
                    final entry = _logs[i];
                    return Text(
                      '${entry.time} ${entry.message}',
                      style: TextStyle(
                        color: switch (entry.type) {
                          LogType.error  => const Color(0xFFFCA5A5),
                          LogType.status => const Color(0xFF6EE7B7),
                          LogType.log    => const Color(0xFFD1D5DB),
                        },
                        fontSize:   11,
                        fontFamily: 'monospace',
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}