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
    adapterVersion: '0.1.0',
    contractVersionRange: '>=0.1.0 <1.0.0',
    displayName: 'Serial Port Adapter',
    description: 'UART / RS-232 / USB-Serial adapter (byte + line modes).',
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
        case 'send_bytes':
          final data = (command.args['data'] as List?)?.cast<int>() ?? const [];
          if (data.isEmpty) {
            return CommandResult(
              status: CommandStatus.rejected,
              error: IoError(
                code: 'exec.invalid_args',
                message: 'send_bytes requires non-empty args["data"]',
                timestamp: DateTime.now(),
              ),
            );
          }
          await _transport.write(data);
          return CommandResult(
            status: CommandStatus.completed,
            result: {'bytes': data.length},
          );
        case 'send_line':
          final line = command.args['line'] as String?;
          if (line == null) {
            return CommandResult(
              status: CommandStatus.rejected,
              error: IoError(
                code: 'exec.invalid_args',
                message: 'send_line requires args["line"]',
                timestamp: DateTime.now(),
              ),
            );
          }
          final terminator = (command.args['terminator'] as String?) ??
              defaultLineTerminator;
          await _transport.write(utf8.encode('$line$terminator'));
          return CommandResult(
            status: CommandStatus.completed,
            result: {'bytes': line.length + terminator.length},
          );
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
