import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../serial_transport.dart';

/// Buffer overflow when accumulated bytes exceed the configured limit
/// without a terminator. Default cap = 1 MB.
class SerialLineBufferOverflow implements Exception {
  const SerialLineBufferOverflow(this.limitBytes);
  final int limitBytes;
  @override
  String toString() =>
      'SerialLineBufferOverflow: line buffer exceeded ${limitBytes}B without terminator';
}

/// Line-delimited reader.
///
/// Bytes are accumulated until the configured terminator is found.
/// The terminator is stripped; the line is decoded with the
/// configured [encoding] and emitted.
///
class LineMode {
  LineMode({
    this.terminator = '\n',
    this.encoding = utf8,
    this.maxBufferBytes = 1024 * 1024,
  });

  /// Line terminator. Common values: `\n`, `\r\n`, `\r`. May be any
  /// non-empty string.
  final String terminator;

  /// Decoding for the line bytes. UTF-8 default; callers may pass
  /// `latin1` / `ascii` for legacy devices.
  final Encoding encoding;

  /// Buffer ceiling. When exceeded the caller's stream sees a
  /// [SerialLineBufferOverflow] error and the buffer is reset.
  final int maxBufferBytes;

  Stream<String> stream(SerialTransport transport) {
    final terminatorBytes = ascii.encode(terminator);
    final buf = BytesBuilder();
    StreamSubscription<Uint8List>? sub;
    late StreamController<String> ctrl;
    ctrl = StreamController<String>(
      onListen: () {
        sub = transport.incoming.listen(
          (chunk) {
            buf.add(chunk);
            while (true) {
              final bytes = buf.toBytes();
              final idx = _indexOf(bytes, terminatorBytes);
              if (idx < 0) break;
              final line = bytes.sublist(0, idx);
              final remainder = bytes.sublist(idx + terminatorBytes.length);
              buf
                ..clear()
                ..add(remainder);
              if (!ctrl.isClosed) ctrl.add(encoding.decode(line));
            }
            if (buf.length > maxBufferBytes) {
              buf.clear();
              if (!ctrl.isClosed) {
                ctrl.addError(SerialLineBufferOverflow(maxBufferBytes));
              }
            }
          },
          onError: (Object e, StackTrace st) {
            if (!ctrl.isClosed) ctrl.addError(e, st);
          },
          onDone: () async {
            if (buf.length > 0 && !ctrl.isClosed) {
              ctrl.add(encoding.decode(buf.toBytes()));
            }
            if (!ctrl.isClosed) await ctrl.close();
          },
          cancelOnError: false,
        );
      },
      onCancel: () async {
        await sub?.cancel();
      },
    );
    return ctrl.stream;
  }

  static int _indexOf(Uint8List haystack, Uint8List needle) {
    if (needle.isEmpty || haystack.length < needle.length) return -1;
    final last = haystack.length - needle.length;
    outer:
    for (var i = 0; i <= last; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}
