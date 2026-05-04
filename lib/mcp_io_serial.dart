/// Serial port adapter for mcp_io (abstract + InMemory).
library;

export 'src/serial_config.dart';
export 'src/serial_transport.dart';
export 'src/serial_adapter.dart';

// Stream modes.
export 'src/mode/length_prefixed_mode.dart';
export 'src/mode/line_mode.dart';
export 'src/mode/raw_mode.dart';

// Error mapping.
export 'src/mapping/serial_to_ioerror.dart';
