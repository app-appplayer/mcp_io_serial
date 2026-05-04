import 'dart:convert';
import 'dart:typed_data';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io_serial/mcp_io_serial.dart';
import 'package:test/test.dart';

SerialIoAdapter _adapter(
  InMemorySerialTransport transport, {
  String terminator = '\n',
}) =>
    SerialIoAdapter(
      deviceId: 'uart',
      portName: '/dev/ttyUSB0',
      config: const SerialConfig(baudRate: 9600),
      transport: transport,
      defaultLineTerminator: terminator,
    );

void main() {
  group('SerialConfig', () {
    test('short descriptor matches classic "baud bits parity stop" form', () {
      const c = SerialConfig(baudRate: 115200, dataBits: 8);
      expect(c.short, '115200 8N1');
    });

    test('even parity 7E1 descriptor', () {
      const c = SerialConfig(
        baudRate: 9600, dataBits: 7, parity: SerialParity.even,
      );
      expect(c.short, '9600 7E1');
    });
  });

  group('connect + describe + lifecycle', () {
    test('connect opens transport with port + config', () async {
      final transport = InMemorySerialTransport();
      final adapter = _adapter(transport);
      await adapter.connect();
      expect(transport.openedPortName, '/dev/ttyUSB0');
      expect(transport.openedConfig?.baudRate, 9600);
      expect((await adapter.describe()).connectionState,
        IoConnectionState.connected);
    });

    test('disconnect closes the transport', () async {
      final transport = InMemorySerialTransport();
      final adapter = _adapter(transport);
      await adapter.connect();
      await adapter.disconnect();
      expect(transport.isClosed, isTrue);
    });

    test('describe includes config.short as version', () async {
      final transport = InMemorySerialTransport();
      final adapter = SerialIoAdapter(
        deviceId: 'a', portName: 'COM3',
        config: const SerialConfig(baudRate: 19200),
        transport: transport,
      );
      final d = await adapter.describe();
      expect(d.version, '19200 8N1');
      expect(d.model, 'COM3');
    });
  });

  group('execute — send_bytes / send_line', () {
    test('send_bytes writes raw data', () async {
      final transport = InMemorySerialTransport();
      final adapter = _adapter(transport);
      await adapter.connect();
      final res = await adapter.execute(const Command(
        action: 'send_bytes', target: '/',
        args: {'data': [0x01, 0x02, 0x03]},
      ));
      expect(res.status, CommandStatus.completed);
      expect(transport.sent.single, [0x01, 0x02, 0x03]);
    });

    test('send_line appends default terminator', () async {
      final transport = InMemorySerialTransport();
      final adapter = _adapter(transport);
      await adapter.connect();
      await adapter.execute(const Command(
        action: 'send_line', target: '/',
        args: {'line': 'STATUS?'},
      ));
      expect(utf8.decode(transport.sentFlat()), 'STATUS?\n');
    });

    test('send_line accepts per-command terminator', () async {
      final transport = InMemorySerialTransport();
      final adapter = _adapter(transport);
      await adapter.connect();
      await adapter.execute(const Command(
        action: 'send_line', target: '/',
        args: {'line': 'STATUS?', 'terminator': '\r\n'},
      ));
      expect(utf8.decode(transport.sentFlat()), 'STATUS?\r\n');
    });

    test('adapter-level defaultLineTerminator override', () async {
      final transport = InMemorySerialTransport();
      final adapter = _adapter(transport, terminator: '\r\n');
      await adapter.connect();
      await adapter.execute(const Command(
        action: 'send_line', target: '/',
        args: {'line': 'HELLO'},
      ));
      expect(utf8.decode(transport.sentFlat()), 'HELLO\r\n');
    });

    test('send_bytes empty data → rejected', () async {
      final transport = InMemorySerialTransport();
      final adapter = _adapter(transport);
      await adapter.connect();
      final res = await adapter.execute(const Command(
        action: 'send_bytes', target: '/',
        args: {'data': []},
      ));
      expect(res.status, CommandStatus.rejected);
      expect(res.error?.code, 'exec.invalid_args');
    });

    test('send_line missing line → rejected', () async {
      final transport = InMemorySerialTransport();
      final adapter = _adapter(transport);
      await adapter.connect();
      final res = await adapter.execute(const Command(
        action: 'send_line', target: '/',
      ));
      expect(res.status, CommandStatus.rejected);
    });

    test('unknown action → rejected', () async {
      final transport = InMemorySerialTransport();
      final adapter = _adapter(transport);
      await adapter.connect();
      final res = await adapter.execute(const Command(
        action: 'bogus', target: '/',
      ));
      expect(res.status, CommandStatus.rejected);
    });

    test('transport closed before send → failed', () async {
      final transport = InMemorySerialTransport();
      final adapter = _adapter(transport);
      await adapter.connect();
      await transport.close();
      final res = await adapter.execute(const Command(
        action: 'send_bytes', target: '/', args: {'data': [1]},
      ));
      expect(res.status, CommandStatus.failed);
    });
  });

  group('subscribe — bytes mode', () {
    test('emits each injected chunk as a blob envelope', () async {
      final transport = InMemorySerialTransport();
      final adapter = _adapter(transport);
      await adapter.connect();
      final seen = <List<int>>[];
      final sub = adapter.subscribe(const TopicSpec(
        uri: 'bytes', mode: TopicMode.onChange,
      )).listen((env) => seen.add(env.payload.value as List<int>));
      transport.inject([0x10, 0x20]);
      transport.inject([0x30]);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [[0x10, 0x20], [0x30]]);
      await sub.cancel();
    });
  });

  group('subscribe — lines mode', () {
    test('joins multi-chunk input until terminator then emits line', () async {
      final transport = InMemorySerialTransport();
      final adapter = _adapter(transport);
      await adapter.connect();
      final seen = <String>[];
      final sub = adapter.subscribe(const TopicSpec(
        uri: 'lines', mode: TopicMode.onChange,
      )).listen((env) => seen.add(env.payload.value as String));
      transport.inject(utf8.encode('SCAN12'));
      transport.inject(utf8.encode('345\n'));
      transport.inject(utf8.encode('ANOTHER\n'));
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['SCAN12345', 'ANOTHER']);
      await sub.cancel();
    });

    test('splits multiple lines delivered in a single chunk', () async {
      final transport = InMemorySerialTransport();
      final adapter = _adapter(transport);
      await adapter.connect();
      final seen = <String>[];
      final sub = adapter.subscribe(const TopicSpec(
        uri: 'lines', mode: TopicMode.onChange,
      )).listen((env) => seen.add(env.payload.value as String));
      transport.inject(utf8.encode('A\nB\nC\n'));
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['A', 'B', 'C']);
      await sub.cancel();
    });

    test('honors CRLF terminator override', () async {
      final transport = InMemorySerialTransport();
      final adapter = _adapter(transport, terminator: '\r\n');
      await adapter.connect();
      final seen = <String>[];
      final sub = adapter.subscribe(const TopicSpec(
        uri: 'lines', mode: TopicMode.onChange,
      )).listen((env) => seen.add(env.payload.value as String));
      transport.inject(utf8.encode('FIRST\r\nSECOND\r\n'));
      transport.inject(utf8.encode('PARTIAL'));
      transport.inject(utf8.encode('\r\n'));
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['FIRST', 'SECOND', 'PARTIAL']);
      await sub.cancel();
    });

    test('unknown subscribe uri → throws ArgumentError', () async {
      final adapter = _adapter(InMemorySerialTransport());
      expect(
        () => adapter.subscribe(const TopicSpec(
          uri: 'other', mode: TopicMode.onChange,
        )),
        throwsArgumentError,
      );
    });
  });

  group('read + emergency + probe', () {
    test('read unsupported per target', () async {
      final adapter = _adapter(InMemorySerialTransport());
      final res = await adapter.read(
        const ReadSpec(targets: ['/a', '/b']),
      );
      expect(res.items, hasLength(2));
      for (final item in res.items) {
        expect(item.error?.code, 'device.unsupported');
      }
    });

    test('emergencyStop disconnects + success', () async {
      final transport = InMemorySerialTransport();
      final adapter = _adapter(transport);
      await adapter.connect();
      final r = await adapter.emergencyStop(const EmergencyStopRequest(
        reason: 't', actorId: 'u',
      ));
      expect(r.success, isTrue);
      expect(transport.isClosed, isTrue);
    });

    test('probe returns empty', () async {
      final adapter = _adapter(InMemorySerialTransport());
      expect(await adapter.probe(null), isEmpty);
    });
  });

  group('InMemorySerialTransport helpers', () {
    test('sentFlat concatenates multiple write chunks', () async {
      final t = InMemorySerialTransport();
      await t.open('p', const SerialConfig());
      await t.write([1, 2]);
      await t.write(Uint8List.fromList([3, 4]));
      expect(t.sentFlat(), [1, 2, 3, 4]);
    });
  });

  group('execute — capability dispatch (0.2.0)', () {
    test('serial.write_bytes routes to write path', () async {
      final t = InMemorySerialTransport();
      final a = _adapter(t);
      await a.connect();
      final r = await a.execute(const Command(
        action: 'serial.write_bytes',
        target: '',
        args: {'data': [0x41, 0x42]},
      ));
      expect(r.status, CommandStatus.completed);
      expect(t.sentFlat(), [0x41, 0x42]);
    });

    test('serial.write_line appends terminator', () async {
      final t = InMemorySerialTransport();
      final a = _adapter(t);
      await a.connect();
      final r = await a.execute(const Command(
        action: 'serial.write_line',
        target: '',
        args: {'line': 'AT'},
      ));
      expect(r.status, CommandStatus.completed);
      expect(utf8.decode(t.sentFlat()), 'AT\n');
    });

    test('serial.read_until returns bytes when terminator arrives', () async {
      final t = InMemorySerialTransport();
      final a = _adapter(t);
      await a.connect();
      final fut = a.execute(const Command(
        action: 'serial.read_until',
        target: '',
        args: {'terminator': '\r\n', 'timeoutMs': 500},
      ));
      await Future<void>.delayed(Duration.zero);
      t.inject(utf8.encode('OK\r\n'));
      final r = await fut;
      expect(r.status, CommandStatus.completed);
      expect(r.result?['matched'], isTrue);
      expect(r.result?['text'], 'OK\r\n');
    });

    test('serial.read_until reports matched=false on timeout', () async {
      final t = InMemorySerialTransport();
      final a = _adapter(t);
      await a.connect();
      final r = await a.execute(const Command(
        action: 'serial.read_until',
        target: '',
        args: {'timeoutMs': 30},
      ));
      expect(r.status, CommandStatus.completed);
      expect(r.result?['matched'], isFalse);
    });

    test('serial.set_dtr / set_rts record control ops', () async {
      final t = InMemorySerialTransport();
      final a = _adapter(t);
      await a.connect();
      await a.execute(const Command(
        action: 'serial.set_dtr', target: '', args: {'active': true},
      ));
      await a.execute(const Command(
        action: 'serial.set_rts', target: '', args: {'active': false},
      ));
      expect(t.controlOps, [
        {'op': 'dtr', 'value': true},
        {'op': 'rts', 'value': false},
      ]);
    });

    test('serial.set_dtr rejects non-bool', () async {
      final t = InMemorySerialTransport();
      final a = _adapter(t);
      await a.connect();
      final r = await a.execute(const Command(
        action: 'serial.set_dtr', target: '', args: {'active': 1},
      ));
      expect(r.status, CommandStatus.rejected);
      expect(r.error?.code, 'exec.invalid_args');
    });

    test('serial.send_break records break duration', () async {
      final t = InMemorySerialTransport();
      final a = _adapter(t);
      await a.connect();
      await a.execute(const Command(
        action: 'serial.send_break',
        target: '',
        args: {'durationMs': 100},
      ));
      expect(t.controlOps, hasLength(1));
      expect(t.controlOps.first['op'], 'break');
      expect(t.controlOps.first['value'], const Duration(milliseconds: 100));
    });
  });
}
