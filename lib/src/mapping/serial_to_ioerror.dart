import 'package:mcp_bundle/mcp_bundle.dart';

import '../mode/line_mode.dart';

/// Convert serial-layer errors to canonical [IoError] codes.
class SerialToIoError {
  SerialToIoError._();

  static IoError fromAny(Object error, {DateTime? timestamp}) {
    final ts = timestamp ?? DateTime.now();
    if (error is SerialLineBufferOverflow) {
      return IoError(
        code: 'protocol.message_too_big',
        message: '$error',
        timestamp: ts,
      );
    }
    if (error is FormatException) {
      return IoError(
        code: 'parse.format_error',
        message: error.message,
        timestamp: ts,
      );
    }
    if (error is StateError) {
      return IoError(
        code: 'transport.closed',
        message: error.message,
        timestamp: ts,
      );
    }
    return IoError(
      code: 'exec.failed',
      message: '$error',
      timestamp: ts,
    );
  }
}
