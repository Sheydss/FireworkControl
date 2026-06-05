# Fireworks Control App — CLAUDE.md

## Project overview

Flutter Android app for controlling a fireworks show system.
Communicates with Heltec head boards via a WROOM USB bridge connected
via USB-C OTG cable to the Samsung A52 5G (or any Android with OTG).

---

## Tech stack

| | |
|---|---|
| Framework | Flutter (Dart) |
| Target | Android only (Samsung A52 5G) |
| USB serial | `usb_serial` package |
| File picker | `file_picker` package |
| Storage | App internal storage (persists across restarts) |

### pubspec.yaml dependencies
```yaml
dependencies:
  flutter:
    sdk: flutter
  usb_serial: ^0.5.0
  file_picker: ^8.0.0
```

---

## File structure

```
lib/
└── main.dart        # Single file — entire app

android/
├── app/src/main/
│   ├── AndroidManifest.xml    # USB host feature + device filter
│   └── res/xml/
│       └── device_filter.xml  # CH340/FTDI/CP210x vendor IDs
```

---

## Architecture

```
Flutter app (main.dart)
    ↓ USB Serial (115200 baud, newline-delimited JSON)
WROOM Bridge
    ↓ ESP-NOW
Heltec Heads
    ↓ RS485
WROOM Modules
```

---

## Key classes / state

All state is in `_HomePageState` (single stateful widget).

### USB serial
- `_port` — active `UsbPort` instance (null when disconnected)
- `_connected` — bool
- `_recvBuffer` — accumulates partial JSON lines between reads
- Messages are split on `\n`, each line parsed as JSON

### App state
- `_heads` — `List<Head>` — connected heads with MAC, name, state, file list
- `_logs` — `List<LogEntry>` — last 100 log entries (newest first)
- `_currentState` — `FireworkState?` — last sent state

### File transfer state
- `_transferring` — bool
- `_transferProgress` — 0.0 to 1.0
- `_transferChunks` — total chunk count
- `_transferCurrent` — chunks sent so far
- `_pendingFileData` — `Uint8List?` — file being transferred
- `_pendingFileName` — String
- `_pendingTargets` — `List<String>` — target head MACs

---

## Serial protocol

### Sending to bridge
```dart
void _sendToBridge(Map<String, dynamic> obj) {
    _port!.write(Uint8List.fromList(utf8.encode('${jsonEncode(obj)}\n')));
}
```

### Receiving from bridge
Lines are accumulated in `_recvBuffer`, split on `\n`, parsed in
`_handleBridgeMessage()`. Non-JSON lines (ESP32 boot garbage) are filtered
by `_isPrintable()` — only lines with all chars in ASCII 32-126 are shown.

---

## File transfer protocol

### Chunk size
`kChunkSize = 128` raw bytes → 172 base64 chars → fits in 250-byte ESP-NOW packet.

### Flow
```
_startTransfer(targets)
    → _sendToBridge({cmd: file_start, ...})
    → wait for {type: file_start_ack} from bridge
    → _sendNextChunk(0)
    → wait for {type: chunk_ack, idx: 0}
    → _sendNextChunk(1) ... repeat ...
    → when idx >= _transferChunks: send {cmd: file_end, total_crc: ...}
    → {type: transfer_complete} received → done
```

**Critical**: first chunk is sent on `file_start_ack`, NOT on a timer.
Using `Future.delayed` caused double-sending of the last chunk.

### CRC-16 (Dart implementation)
```dart
int _crc16(Uint8List data, int offset, int length) {
    int crc = 0xFFFF;
    for (int i = offset; i < offset + length; i++) {
        crc ^= (data[i] << 8) & 0xFFFF;  // mask required for Dart 64-bit ints
        for (int j = 0; j < 8; j++) {
            crc = (crc & 0x8000) != 0
                  ? ((crc << 1) ^ 0x1021) & 0xFFFF
                  : (crc << 1) & 0xFFFF;
        }
    }
    return crc;
}
// Verification: _crc16(utf8.encode('123456789'), 0, 9) == 0x29B1
```

---

## UI structure

### Tabs
- **Contrôle** — state buttons, filename input, head list, log
- **Fichiers** — file library, upload to heads, per-head file management

### Control tab
- 6 state buttons in 2×2 grid: Préparation, Armement, Lancer, Pause, Stop, Fin
- Play (Lancer) disabled until filename is entered
- Active state has white border
- Head list shows MAC, name, current state badge

### Files tab
- **File library** — stored in app internal storage, max 10 files
- Pick from phone storage → validate JSON (must have: name, tops, hash,
  audioFilePath, audioTotalDuration) → add to library
- Duplicate name → confirmation dialog before overwrite
- Select files with checkboxes → delete or send to heads
- Dropdown in Control tab populated from library
- Per-head section: storage bar, file list with sizes, delete button
- "Send to this head" per head, "Send to all heads" global button
- Progress bar during transfer

### State buttons
```dart
enum FireworkState { preparation, armement, play, pause, stop, fin }
// values: 0, 1, 2, 3, 4, 5 — matches ESP32 State enum
```

---

## Plan file format

```json
{
  "name": "Show 1",
  "hash": "de395fd691447d87655d973695fe62282bfdf4989921c4ba438b95e1eb82c2f7",
  "audioFilePath": "/storage/emulated/0/Music/show1.mp3",
  "audioTotalDuration": 180,
  "tops": [
    {"id": 1, "timeInTenths": 50, "alert": false, "separatorBefore": false}
  ]
}
```

Validation in `_pickFile()`: must have `name`, `tops`, `hash`,
`audioFilePath`, `audioTotalDuration` — hash is NOT recomputed, just checked for presence.

---

## Android setup

### AndroidManifest.xml additions
```xml
<manifest>
    <uses-feature android:name="android.hardware.usb.host" />
    <application>
        <activity android:name=".MainActivity">
            <intent-filter>
                <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED" />
            </intent-filter>
            <meta-data
                android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
                android:resource="@xml/device_filter" />
        </activity>
    </application>
</manifest>
```

### device_filter.xml
```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <usb-device vendor-id="6790" />  <!-- CH340  -->
    <usb-device vendor-id="1027" />  <!-- FTDI   -->
    <usb-device vendor-id="4292" />  <!-- CP210x -->
</resources>
```

### Build versions (Java 21 compatible)
```
AGP: 8.6.0 (in settings.gradle plugins block)
Gradle: 8.7 (in gradle-wrapper.properties)
Kotlin: 2.1.0
compileOptions: JavaVersion.VERSION_17 (not 21 — Kotlin 2.1.0 supports 17)
```

---

## Key decisions & known issues

- Single `main.dart` file — all code in one place for prototype simplicity
- `usb_serial` package requires `expo run:android` style build (not Expo Go)
- ESP32 boot log produces garbage bytes on serial — filtered by `_isPrintable()`
- Dart integers are 64-bit — CRC must use `& 0xFFFF` masks on every step
- `file_picker` returns `file.bytes` as binary (`Uint8List`) — no CRLF issue
- File transfer first chunk triggered by `file_start_ack`, not `Future.delayed`
- USB OTG powers the bridge WROOM — acceptable battery drain for prototype
- `_filenameCtrl.addListener(() => setState(() {}))` needed in `initState()`
  to reactively enable/disable the Play button as filename is typed