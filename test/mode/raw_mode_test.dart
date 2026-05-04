/// Coverage for `RawMode` — pass-through stream wrapper.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:mcp_io_serial/mcp_io_serial.dart';
import 'package:test/test.dart';

void main() {
  test('TC-RAW-001 stream forwards every transport chunk verbatim', () async {
    final t = InMemorySerialTransport();
    await t.open('mock', const SerialConfig());

    final received = <Uint8List>[];
    final sub = RawMode.stream(t).listen(received.add);

    t.inject([1, 2, 3]);
    t.inject([4, 5]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();

    expect(received.length, 2);
    expect(received[0], [1, 2, 3]);
    expect(received[1], [4, 5]);
    await t.close();
  });
}
