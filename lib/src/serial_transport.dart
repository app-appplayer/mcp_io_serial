/// Serial transport abstraction for `mcp_io_serial`.
///
/// Implementations move raw bytes between the adapter and a platform-specific
/// serial port. The production wire-up is left to integrators (typically a
/// thin subclass over `package:libserialport`); this package ships only the
/// abstraction and a purely in-memory test transport.
library;

import 'dart:async';
import 'dart:typed_data';

import 'serial_config.dart';

abstract class SerialTransport {
  /// Opens the underlying port using [config]. Idempotent.
  Future<void> open(String portName, SerialConfig config);

  /// Transmit a raw byte sequence.
  Future<void> write(List<int> bytes);

  /// Stream of incoming byte chunks. Each event is a chunk exactly as
  /// received from the OS read buffer (no re-chunking).
  Stream<Uint8List> get incoming;

  /// Close the port.
  Future<void> close();
}

/// In-memory serial transport for tests. [inject] simulates bytes arriving
/// at the port; [sent] records transmitted data for assertion.
class InMemorySerialTransport implements SerialTransport {
  final StreamController<Uint8List> _rxCtrl =
      StreamController<Uint8List>.broadcast();
  final List<Uint8List> sent = [];
  String? openedPortName;
  SerialConfig? openedConfig;
  bool isClosed = false;

  @override
  Future<void> open(String portName, SerialConfig config) async {
    openedPortName = portName;
    openedConfig = config;
  }

  @override
  Future<void> write(List<int> bytes) async {
    if (isClosed) throw StateError('serial transport closed');
    sent.add(Uint8List.fromList(bytes));
  }

  @override
  Stream<Uint8List> get incoming => _rxCtrl.stream;

  @override
  Future<void> close() async {
    isClosed = true;
    if (!_rxCtrl.isClosed) {
      await _rxCtrl.close();
    }
  }

  /// Simulate bytes arriving from the device.
  void inject(List<int> bytes) {
    if (_rxCtrl.isClosed) return;
    _rxCtrl.add(Uint8List.fromList(bytes));
  }

  /// Flatten all transmitted chunks into a single byte list.
  List<int> sentFlat() => [
        for (final chunk in sent) ...chunk,
      ];
}
