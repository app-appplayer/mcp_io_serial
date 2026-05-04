import 'dart:async';
import 'dart:typed_data';

import '../serial_transport.dart';

/// Length prefix size in bytes.
enum LengthPrefixSize { uint8, uint16, uint32 }

/// Endianness of the length prefix.
enum LengthEndian { little, big }

/// Length-prefixed framer.
///
/// Frame layout: `[length: 1/2/4 bytes] [payload of <length> bytes]`.
///
/// When [includesHeader] is true the declared length covers the
/// prefix bytes themselves; this is rare but seen on some legacy
/// devices.
///
class LengthPrefixedMode {
  LengthPrefixedMode({
    this.size = LengthPrefixSize.uint16,
    this.endian = LengthEndian.little,
    this.includesHeader = false,
    this.maxFrameBytes = 1024 * 1024,
  });

  final LengthPrefixSize size;
  final LengthEndian endian;
  final bool includesHeader;
  final int maxFrameBytes;

  int get _prefixBytes => switch (size) {
        LengthPrefixSize.uint8 => 1,
        LengthPrefixSize.uint16 => 2,
        LengthPrefixSize.uint32 => 4,
      };

  Stream<Uint8List> stream(SerialTransport transport) {
    final buf = BytesBuilder();
    StreamSubscription<Uint8List>? sub;
    late StreamController<Uint8List> ctrl;
    ctrl = StreamController<Uint8List>(
      onListen: () {
        sub = transport.incoming.listen(
          (chunk) {
            buf.add(chunk);
            while (true) {
              final bytes = buf.toBytes();
              if (bytes.length < _prefixBytes) break;
              final declared = _readLength(bytes);
              final payloadLen =
                  includesHeader ? declared - _prefixBytes : declared;
              if (payloadLen < 0 || payloadLen > maxFrameBytes) {
                buf.clear();
                if (!ctrl.isClosed) {
                  ctrl.addError(FormatException(
                      'length-prefixed frame exceeds limit: $payloadLen B'));
                }
                break;
              }
              final total = _prefixBytes + payloadLen;
              if (bytes.length < total) break;
              final frame = bytes.sublist(_prefixBytes, total);
              final remainder = bytes.sublist(total);
              buf
                ..clear()
                ..add(remainder);
              if (!ctrl.isClosed) ctrl.add(Uint8List.fromList(frame));
            }
          },
          onError: (Object e, StackTrace st) {
            if (!ctrl.isClosed) ctrl.addError(e, st);
          },
          onDone: () async {
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

  int _readLength(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    switch (size) {
      case LengthPrefixSize.uint8:
        return view.getUint8(0);
      case LengthPrefixSize.uint16:
        return view.getUint16(0,
            endian == LengthEndian.little ? Endian.little : Endian.big);
      case LengthPrefixSize.uint32:
        return view.getUint32(0,
            endian == LengthEndian.little ? Endian.little : Endian.big);
    }
  }

  /// Encode a payload with the configured length prefix. Useful for
  /// outbound writes paired with [stream].
  Uint8List frame(List<int> payload) {
    final declared = includesHeader ? payload.length + _prefixBytes : payload.length;
    final out = BytesBuilder();
    final bd = ByteData(_prefixBytes);
    final endianness =
        endian == LengthEndian.little ? Endian.little : Endian.big;
    switch (size) {
      case LengthPrefixSize.uint8:
        bd.setUint8(0, declared & 0xFF);
      case LengthPrefixSize.uint16:
        bd.setUint16(0, declared & 0xFFFF, endianness);
      case LengthPrefixSize.uint32:
        bd.setUint32(0, declared & 0xFFFFFFFF, endianness);
    }
    out.add(bd.buffer.asUint8List());
    out.add(payload);
    return out.takeBytes();
  }
}
