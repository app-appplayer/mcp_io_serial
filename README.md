# mcp_io_serial

Serial port adapter for [`mcp_io`](https://pub.dev/packages/mcp_io) —
UART / RS-232 / RS-485 / USB-CDC integration through a single
4-Primitive surface.

The web-safe core ships the abstract `SerialTransport` + an
in-memory implementation. Production deployments opt in to the
`dart:ffi` libserialport binding via the separate `lib/native.dart`
entry point.

## Capability matrix

| Area | Support |
|---|---|
| Config | Baud (110..3M), data 5/6/7/8, stop 1/2, parity (None/Even/Odd/Mark/Space), flow (None/RtsCts/XonXoff) |
| Line control | DTR / RTS set/clear, BREAK signal (configurable duration) |
| Modes | Raw byte, line-delimited (terminator), length-prefixed (uint8 / uint16 LE/BE / uint32 LE/BE, optional `includesHeader`) |
| Subscribe | `bytes` stream, `lines` stream (terminator-buffered, UTF-8 decoded) |
| Capabilities | `serial.write_bytes` / `write_line` / `read_until` / `set_dtr` / `set_rts` / `send_break` |
| Transports | `InMemorySerialTransport` (web-safe, tests) · `LibserialportSerialTransport` (production, VM / Flutter desktop / mobile via `lib/native.dart`) |

## Web-safe quick start (any target)

```dart
import 'package:mcp_io_serial/mcp_io_serial.dart';

final transport = InMemorySerialTransport();
final adapter = SerialIoAdapter(
  deviceId: 'uart-1',
  portName: '/dev/ttyUSB0',
  config: const SerialConfig(baudRate: 115200, dataBits: 8),
  transport: transport,
);
await adapter.connect();

final stream = adapter.subscribe(const TopicSpec(uri: 'lines'));
stream.listen((env) => print(env.payload.value));
```

## Production (libserialport via FFI)

Available on VM, Flutter desktop (Linux / macOS / Windows), and
Flutter mobile. The host system must have libserialport installed
(`apt install libserialport0`, `brew install libserialport`, or a
prebuilt `libserialport.dll` for Windows).

```dart
import 'package:mcp_io_serial/mcp_io_serial.dart';
import 'package:mcp_io_serial/native.dart';

final transport = LibserialportSerialTransport();
final adapter = SerialIoAdapter(
  deviceId: 'uart-1',
  portName: '/dev/ttyUSB0',         // 'COM3' on Windows
  config: const SerialConfig(baudRate: 9600, parity: SerialParity.even),
  transport: transport,
);
await adapter.connect();

await adapter.execute(const Command(
  action: 'serial.write_line',
  target: '',
  args: {'line': 'AT+VERSION'},
));
```

The capability set covers control-line ops (`serial.set_dtr`,
`serial.set_rts`, `serial.send_break`) — the production transport
forwards these to the corresponding `libserialport` calls.

## License

MIT — see [LICENSE](LICENSE).
