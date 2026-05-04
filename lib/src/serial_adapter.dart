/// SerialIoAdapter — `AdapterBase` implementation for UART / RS-232 /
/// USB-Serial devices.
///
/// Subscribe modes (selected by `TopicSpec.uri`):
///   - `bytes` — emit each raw byte chunk as a blob payload.
///   - `lines` — buffer incoming bytes until the terminator is seen, then
///     emit the accumulated line (UTF-8 decoded) as a scalar payload.
///     The terminator is configurable via `TopicOptions.ttlSeconds`? No —
///     use a custom metadata channel: callers pass the terminator through
///     the [LineSubscribeOptions] helper when constructing the TopicSpec.
///     To keep the API surface minimal, the adapter accepts an optional
///     `defaultLineTerminator` at construction (default `\n`).
///
/// Command actions:
///   - `send_bytes` (args={data: `List<int>`}) — raw transmit.
///   - `send_line`  (args={line: String, terminator?: String}) — text
///     transmit; terminator is appended automatically (default `\n`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:mcp_io/mcp_io.dart';

import 'serial_config.dart';
import 'serial_transport.dart';

class SerialIoAdapter extends AdapterBase {
  final String deviceId;
  final String portName;
  final SerialConfig config;
  final SerialTransport _transport;
  final String defaultLineTerminator;

  IoConnectionState _state = IoConnectionState.disconnected;

  SerialIoAdapter({
    required this.deviceId,
    required this.portName,
    required this.config,
    required SerialTransport transport,
    this.defaultLineTerminator = '\n',
    AdapterManifest? manifest,
  })  : _transport = transport,
        super(manifest: manifest ?? _defaultManifest);

  static final AdapterManifest _defaultManifest = AdapterManifest(
    adapterId: 'mcp_io_serial',
    adapterVersion: '0.2.0',
    contractVersionRange: '>=0.1.0 <1.0.0',
    displayName: 'Serial Port Adapter',
    description:
        'UART / RS-232 / RS-485 / USB-CDC adapter — raw / line / length-prefixed '
        'modes, full SerialConfig (baud / data / stop / parity / flow), '
        'DTR/RTS line control + modem status. Production transport (libserialport '
        'FFI etc.) injected into SerialTransport; abstract layer ships InMemory.',
    capabilities: const [
      CapabilityDescriptor(action: 'serial.write_bytes', safetyClass: SafetyClass.guarded),
      CapabilityDescriptor(action: 'serial.write_line', safetyClass: SafetyClass.guarded),
      CapabilityDescriptor(action: 'serial.read_until', safetyClass: SafetyClass.safe),
      CapabilityDescriptor(action: 'serial.set_dtr', safetyClass: SafetyClass.guarded),
      CapabilityDescriptor(action: 'serial.set_rts', safetyClass: SafetyClass.guarded),
      CapabilityDescriptor(action: 'serial.send_break', safetyClass: SafetyClass.guarded),
    ],
  );

  // === Lifecycle ===

  @override
  Future<void> connect() async {
    await _transport.open(portName, config);
    _state = IoConnectionState.connected;
  }

  @override
  Future<void> disconnect() async {
    await _transport.close();
    _state = IoConnectionState.disconnected;
  }

  @override
  Future<List<DeviceDescriptor>> probe(dynamic transport) async => const [];

  // === 4-Primitive Contract ===

  @override
  Future<DeviceDescriptor> describe() async {
    return DeviceDescriptor(
      deviceId: deviceId,
      manufacturer: 'Serial',
      model: portName,
      transport: 'serial',
      connectionState: _state,
      version: config.short,
    );
  }

  @override
  Future<ReadResult> read(ReadSpec spec) async {
    final now = DateTime.now();
    return ReadResult(
      items: [
        for (final t in spec.targets)
          ReadResultItem(
            uri: t,
            error: IoError(
              code: 'device.unsupported',
              message: 'Serial read is async; use subscribe()',
              timestamp: now,
            ),
          ),
      ],
    );
  }

  @override
  Future<CommandResult> execute(Command command) async {
    try {
      switch (command.action) {
        // === Legacy actions (BC pre-0.2.0) ===
        case 'send_bytes':
        case 'serial.write_bytes':
          return await _doWriteBytes(command);
        case 'send_line':
        case 'serial.write_line':
          return await _doWriteLine(command);

        // === 0.2.0 capability IDs ===
        case 'serial.read_until':
          return await _doReadUntil(command);
        case 'serial.set_dtr':
          return await _doSetDtr(command);
        case 'serial.set_rts':
          return await _doSetRts(command);
        case 'serial.send_break':
          return await _doSendBreak(command);

        default:
          return CommandResult(
            status: CommandStatus.rejected,
            error: IoError(
              code: 'exec.unknown_action',
              message: 'Unknown action: ${command.action}',
              timestamp: DateTime.now(),
            ),
          );
      }
    } catch (e) {
      return CommandResult(
        status: CommandStatus.failed,
        error: AdapterBase.mapException(e),
      );
    }
  }

  // === Capability dispatch helpers ===

  Future<CommandResult> _doWriteBytes(Command command) async {
    final data = (command.args['data'] as List?)?.cast<int>() ?? const [];
    if (data.isEmpty) {
      return _argError('write_bytes requires non-empty args["data"]');
    }
    await _transport.write(data);
    return CommandResult(
      status: CommandStatus.completed,
      result: {'bytes': data.length},
    );
  }

  Future<CommandResult> _doWriteLine(Command command) async {
    final line = command.args['line'] as String?;
    if (line == null) {
      return _argError('write_line requires args["line"]');
    }
    final terminator = (command.args['terminator'] as String?) ??
        defaultLineTerminator;
    await _transport.write(utf8.encode('$line$terminator'));
    return CommandResult(
      status: CommandStatus.completed,
      result: {'bytes': line.length + terminator.length},
    );
  }

  /// `serial.read_until` accumulates incoming bytes until the supplied
  /// terminator pattern is observed, or the timeout elapses.
  /// Args:
  ///   - `terminator` (String, optional): UTF-8 terminator. Default `\n`.
  ///   - `timeoutMs` (int, optional): hard deadline. Default 1000ms.
  /// Returns: `{bytes: List<int>, text: String, matched: bool}`.
  /// Bytes include the terminator; text is UTF-8 decoded best-effort.
  Future<CommandResult> _doReadUntil(Command command) async {
    final terminator = (command.args['terminator'] as String?) ??
        defaultLineTerminator;
    final timeoutMs = (command.args['timeoutMs'] as int?) ?? 1000;
    final termBytes = utf8.encode(terminator);
    final buffer = <int>[];
    final completer = Completer<({List<int> bytes, bool matched})>();
    StreamSubscription<Uint8List>? sub;
    final timer = Timer(Duration(milliseconds: timeoutMs), () {
      if (!completer.isCompleted) {
        completer.complete((bytes: List<int>.from(buffer), matched: false));
      }
    });
    sub = _transport.incoming.listen((chunk) {
      buffer.addAll(chunk);
      final idx = _indexOfSubsequence(buffer, termBytes);
      if (idx >= 0 && !completer.isCompleted) {
        final upTo = idx + termBytes.length;
        completer.complete((bytes: buffer.sublist(0, upTo), matched: true));
      }
    });
    final r = await completer.future;
    timer.cancel();
    await sub.cancel();
    return CommandResult(
      status: CommandStatus.completed,
      result: {
        'bytes': r.bytes,
        'text': utf8.decode(r.bytes, allowMalformed: true),
        'matched': r.matched,
      },
    );
  }

  Future<CommandResult> _doSetDtr(Command command) async {
    final active = command.args['active'];
    if (active is! bool) {
      return _argError('serial.set_dtr requires bool args["active"]');
    }
    await _transport.setDtr(active);
    return CommandResult(
      status: CommandStatus.completed,
      result: {'dtr': active},
    );
  }

  Future<CommandResult> _doSetRts(Command command) async {
    final active = command.args['active'];
    if (active is! bool) {
      return _argError('serial.set_rts requires bool args["active"]');
    }
    await _transport.setRts(active);
    return CommandResult(
      status: CommandStatus.completed,
      result: {'rts': active},
    );
  }

  Future<CommandResult> _doSendBreak(Command command) async {
    final ms = (command.args['durationMs'] as int?) ?? 250;
    final duration = Duration(milliseconds: ms);
    await _transport.sendBreak(duration: duration);
    return CommandResult(
      status: CommandStatus.completed,
      result: {'durationMs': ms},
    );
  }

  CommandResult _argError(String reason) => CommandResult(
        status: CommandStatus.rejected,
        error: IoError(
          code: 'exec.invalid_args',
          message: reason,
          timestamp: DateTime.now(),
        ),
      );

  @override
  Stream<PayloadEnvelope> subscribe(TopicSpec spec) {
    switch (spec.uri) {
      case 'bytes':
        return _transport.incoming.map(_toByteEnvelope);
      case 'lines':
        return _lineStream(spec);
      default:
        throw ArgumentError(
          'Serial subscribe uri must be "bytes" or "lines" (got "${spec.uri}")',
        );
    }
  }

  @override
  Future<EmergencyStopResult> emergencyStop(EmergencyStopRequest request) async {
    await disconnect();
    return EmergencyStopResult(success: true, stoppedDevices: [deviceId]);
  }

  // === Internal helpers ===

  PayloadEnvelope _toByteEnvelope(Uint8List chunk) {
    return PayloadEnvelope(
      uri: 'bytes',
      kind: PayloadKind.read,
      payload: TypedPayload(
        type: PayloadType.blob,
        value: List<int>.unmodifiable(chunk),
        timestamp: DateTime.now(),
      ),
      meta: EnvelopeMeta(
        capturedAt: DateTime.now(),
        sourceAddress: portName,
      ),
    );
  }

  Stream<PayloadEnvelope> _lineStream(TopicSpec spec) {
    final terminator = defaultLineTerminator;
    final termBytes = utf8.encode(terminator);
    final buffer = <int>[];
    final controller = StreamController<PayloadEnvelope>.broadcast();
    StreamSubscription<Uint8List>? sub;
    controller.onListen = () {
      sub = _transport.incoming.listen((chunk) {
        buffer.addAll(chunk);
        while (true) {
          final idx = _indexOfSubsequence(buffer, termBytes);
          if (idx < 0) break;
          final line = utf8.decode(buffer.sublist(0, idx));
          buffer.removeRange(0, idx + termBytes.length);
          if (controller.isClosed) return;
          controller.add(PayloadEnvelope(
            uri: 'lines',
            kind: PayloadKind.read,
            payload: TypedPayload(
              type: PayloadType.scalar,
              value: line,
              timestamp: DateTime.now(),
            ),
            meta: EnvelopeMeta(
              capturedAt: DateTime.now(),
              sourceAddress: portName,
            ),
          ));
        }
      }, onError: controller.addError);
    };
    controller.onCancel = () async {
      await sub?.cancel();
      sub = null;
    };
    return controller.stream;
  }

  int _indexOfSubsequence(List<int> haystack, List<int> needle) {
    if (needle.isEmpty) return -1;
    outer:
    for (var i = 0; i <= haystack.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}
