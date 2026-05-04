import 'dart:typed_data';

import 'package:mcp_io_serial/mcp_io_serial.dart';
import 'package:test/test.dart';

void main() {
  group('LineMode', () {
    test('TC-LINE-001 simple \\n terminator', () async {
      final t = InMemorySerialTransport();
      await t.open('p', const SerialConfig());

      final mode = LineMode();
      final lines = <String>[];
      final sub = mode.stream(t).listen(lines.add);

      t.inject(Uint8List.fromList('hello\nworld\n'.codeUnits));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await t.close();

      expect(lines, ['hello', 'world']);
    });

    test('TC-LINE-002 \\r\\n terminator', () async {
      final t = InMemorySerialTransport();
      await t.open('p', const SerialConfig());

      final mode = LineMode(terminator: '\r\n');
      final lines = <String>[];
      final sub = mode.stream(t).listen(lines.add);

      t.inject(Uint8List.fromList('a\r\nb\r\n'.codeUnits));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await t.close();

      expect(lines, ['a', 'b']);
    });

    test('TC-LINE-003 chunked across reads', () async {
      final t = InMemorySerialTransport();
      await t.open('p', const SerialConfig());

      final lines = <String>[];
      final sub = LineMode().stream(t).listen(lines.add);

      t.inject(Uint8List.fromList('he'.codeUnits));
      t.inject(Uint8List.fromList('llo\nworld'.codeUnits));
      t.inject(Uint8List.fromList('\n'.codeUnits));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await t.close();

      expect(lines, ['hello', 'world']);
    });

    test('TC-LINE-004 buffer overflow throws', () async {
      final t = InMemorySerialTransport();
      await t.open('p', const SerialConfig());

      final mode = LineMode(maxBufferBytes: 8);
      Object? caught;
      final sub = mode.stream(t).listen(
        (_) {},
        onError: (Object e) => caught = e,
      );

      t.inject(Uint8List.fromList('aaaaaaaaaaaa'.codeUnits)); // 12B no terminator
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await t.close();

      expect(caught, isA<SerialLineBufferOverflow>());
    });
  });

  group('LengthPrefixedMode', () {
    test('TC-LP-001 uint8 LE single frame', () async {
      final t = InMemorySerialTransport();
      await t.open('p', const SerialConfig());

      final mode = LengthPrefixedMode(size: LengthPrefixSize.uint8);
      final frames = <Uint8List>[];
      final sub = mode.stream(t).listen(frames.add);

      t.inject(Uint8List.fromList([3, 1, 2, 3]));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await t.close();

      expect(frames, hasLength(1));
      expect(frames.first, equals([1, 2, 3]));
    });

    test('TC-LP-002 uint16 LE chunked', () async {
      final t = InMemorySerialTransport();
      await t.open('p', const SerialConfig());

      final mode = LengthPrefixedMode(size: LengthPrefixSize.uint16);
      final frames = <Uint8List>[];
      final sub = mode.stream(t).listen(frames.add);

      // length=4 (LE) + 4 bytes
      t.inject(Uint8List.fromList([0x04, 0x00]));
      t.inject(Uint8List.fromList([0xA, 0xB]));
      t.inject(Uint8List.fromList([0xC, 0xD]));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await t.close();

      expect(frames.first, equals([0xA, 0xB, 0xC, 0xD]));
    });

    test('TC-LP-003 uint16 BE', () async {
      final t = InMemorySerialTransport();
      await t.open('p', const SerialConfig());

      final mode = LengthPrefixedMode(
        size: LengthPrefixSize.uint16,
        endian: LengthEndian.big,
      );
      final frames = <Uint8List>[];
      final sub = mode.stream(t).listen(frames.add);

      // length=2 BE + 2 bytes
      t.inject(Uint8List.fromList([0x00, 0x02, 0xAA, 0xBB]));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await t.close();

      expect(frames.first, equals([0xAA, 0xBB]));
    });

    test('TC-LP-004 includesHeader subtracts prefix', () async {
      final t = InMemorySerialTransport();
      await t.open('p', const SerialConfig());

      final mode = LengthPrefixedMode(
        size: LengthPrefixSize.uint8,
        includesHeader: true,
      );
      final frames = <Uint8List>[];
      final sub = mode.stream(t).listen(frames.add);

      // declared length=4 includes prefix → payload = 3 bytes
      t.inject(Uint8List.fromList([4, 0xA, 0xB, 0xC]));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await t.close();

      expect(frames.first, equals([0xA, 0xB, 0xC]));
    });

    test('TC-LP-005 frame too large throws', () async {
      final t = InMemorySerialTransport();
      await t.open('p', const SerialConfig());

      final mode = LengthPrefixedMode(
        size: LengthPrefixSize.uint16,
        maxFrameBytes: 10,
      );
      Object? caught;
      final sub = mode.stream(t).listen(
        (_) {},
        onError: (Object e) => caught = e,
      );

      // declared length=100 > maxFrameBytes
      t.inject(Uint8List.fromList([0x64, 0x00]));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await t.close();

      expect(caught, isA<FormatException>());
    });

    test('TC-LP-006 frame round-trip via frame()', () {
      final mode = LengthPrefixedMode(size: LengthPrefixSize.uint16);
      final framed = mode.frame([0x10, 0x20, 0x30]);
      expect(framed, equals([0x03, 0x00, 0x10, 0x20, 0x30]));
    });
  });

  group('SerialToIoError', () {
    test('TC-STE-001 SerialLineBufferOverflow → message_too_big', () {
      final err = SerialToIoError.fromAny(
          const SerialLineBufferOverflow(8));
      expect(err.code, 'protocol.message_too_big');
    });

    test('TC-STE-002 FormatException → parse.format_error', () {
      final err = SerialToIoError.fromAny(const FormatException('bad'));
      expect(err.code, 'parse.format_error');
    });

    test('TC-STE-003 StateError → transport.closed', () {
      final err = SerialToIoError.fromAny(StateError('closed'));
      expect(err.code, 'transport.closed');
    });

    test('TC-STE-004 fallback', () {
      final err = SerialToIoError.fromAny('???');
      expect(err.code, 'exec.failed');
    });
  });
}
