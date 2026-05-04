/// Tests for `ModemStatus` and `readModemStatus()` — `FR-SER-005`.
@TestOn('vm')
library;

import 'package:mcp_io_serial/mcp_io_serial.dart';
import 'package:test/test.dart';

void main() {
  group('ModemStatus value class', () {
    test('TC-MS-001 equality + hashCode based on the four flags', () {
      const a = ModemStatus(cts: true, dsr: false, ri: false, cd: true);
      const b = ModemStatus(cts: true, dsr: false, ri: false, cd: true);
      const c = ModemStatus(cts: false, dsr: false, ri: false, cd: true);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('TC-MS-002 toString includes all four flag names', () {
      const s = ModemStatus(cts: true, dsr: false, ri: true, cd: false);
      expect(s.toString(), contains('cts: true'));
      expect(s.toString(), contains('dsr: false'));
      expect(s.toString(), contains('ri: true'));
      expect(s.toString(), contains('cd: false'));
    });
  });

  group('InMemorySerialTransport.readModemStatus', () {
    test('TC-MS-003 default returns all-deasserted', () async {
      final t = InMemorySerialTransport();
      final s = await t.readModemStatus();
      expect(s.cts, isFalse);
      expect(s.dsr, isFalse);
      expect(s.ri, isFalse);
      expect(s.cd, isFalse);
    });

    test('TC-MS-004 simulatedModemStatus override is honoured', () async {
      final t = InMemorySerialTransport()
        ..simulatedModemStatus =
            const ModemStatus(cts: true, dsr: true, ri: false, cd: true);
      final s = await t.readModemStatus();
      expect(s.cts, isTrue);
      expect(s.dsr, isTrue);
      expect(s.ri, isFalse);
      expect(s.cd, isTrue);
    });

    test('TC-MS-005 closed transport throws StateError', () async {
      final t = InMemorySerialTransport();
      await t.close();
      expect(t.readModemStatus(), throwsStateError);
    });
  });
}
