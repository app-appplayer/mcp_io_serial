# MCP IO Serial

Serial port adapter for [`mcp_io`](https://pub.dev/packages/mcp_io) — UART / RS-232 / USB-Serial. Byte and line-delimited modes.

```dart
import 'package:mcp_io_serial/mcp_io_serial.dart';

final adapter = SerialIoAdapter(SerialTransport(SerialConfig(...)));
registry.register('uart-0', adapter);
```

## License

MIT — see [LICENSE](LICENSE).
