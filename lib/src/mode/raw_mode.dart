import 'dart:async';
import 'dart:typed_data';

import '../serial_transport.dart';

/// Pass-through byte stream — emits each chunk as the OS read buffer
/// hands it back, no re-chunking.
///
class RawMode {
  RawMode._();

  static Stream<Uint8List> stream(SerialTransport transport) {
    return transport.incoming;
  }
}
