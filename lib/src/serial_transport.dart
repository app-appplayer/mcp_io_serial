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

/// Snapshot of the four readable serial-line modem-status pins.
/// Active=true means the line is asserted.
///
/// Reference: RS-232 §3 (DCE→DTE control lines), libserialport
/// `sp_get_signals` bitmap.
class ModemStatus {
  /// Clear To Send — DCE signals it can accept data from DTE.
  final bool cts;

  /// Data Set Ready — DCE is ready / powered on.
  final bool dsr;

  /// Ring Indicator — incoming call (modem usage).
  final bool ri;

  /// Carrier Detect (a.k.a. DCD / RLSD) — peer signal present.
  final bool cd;

  const ModemStatus({
    required this.cts,
    required this.dsr,
    required this.ri,
    required this.cd,
  });

  @override
  String toString() =>
      'ModemStatus(cts: $cts, dsr: $dsr, ri: $ri, cd: $cd)';

  @override
  bool operator ==(Object other) =>
      other is ModemStatus &&
      other.cts == cts &&
      other.dsr == dsr &&
      other.ri == ri &&
      other.cd == cd;

  @override
  int get hashCode => Object.hash(cts, dsr, ri, cd);
}

abstract class SerialTransport {
  /// Opens the underlying port using [config]. Idempotent.
  Future<void> open(String portName, SerialConfig config);

  /// Transmit a raw byte sequence.
  Future<void> write(List<int> bytes);

  /// Stream of incoming byte chunks. Each event is a chunk exactly as
  /// received from the OS read buffer (no re-chunking).
  Stream<Uint8List> get incoming;

  /// Drive the DTR (Data Terminal Ready) modem control line.
  /// Default implementation throws — production transports override.
  Future<void> setDtr(bool active) =>
      throw UnsupportedError('setDtr not implemented for this transport');

  /// Drive the RTS (Request To Send) modem control line.
  Future<void> setRts(bool active) =>
      throw UnsupportedError('setRts not implemented for this transport');

  /// Send a BREAK condition for [duration].
  Future<void> sendBreak({Duration duration = const Duration(milliseconds: 250)}) =>
      throw UnsupportedError('sendBreak not implemented for this transport');

  /// Read the current state of the four DCE→DTE modem-status lines.
  /// Production transports query the underlying driver
  /// (`sp_get_signals` for libserialport, `GetCommModemStatus` for
  /// Windows). The default throws so existing custom transports
  /// keep compiling; override to expose this capability.
  Future<ModemStatus> readModemStatus() => throw UnsupportedError(
      'readModemStatus not implemented for this transport');

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

  /// Recorded control-line / break operations (one entry per call).
  /// Format: `{op: 'dtr'|'rts'|'break', value: bool|Duration}`.
  final List<Map<String, Object>> controlOps = [];

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
  Future<void> setDtr(bool active) async {
    controlOps.add({'op': 'dtr', 'value': active});
  }

  @override
  Future<void> setRts(bool active) async {
    controlOps.add({'op': 'rts', 'value': active});
  }

  @override
  Future<void> sendBreak({
    Duration duration = const Duration(milliseconds: 250),
  }) async {
    controlOps.add({'op': 'break', 'value': duration});
  }

  /// Synthetic modem-status the [readModemStatus] call returns. Tests
  /// can override this directly; defaults to all-deasserted.
  ModemStatus simulatedModemStatus = const ModemStatus(
    cts: false,
    dsr: false,
    ri: false,
    cd: false,
  );

  @override
  Future<ModemStatus> readModemStatus() async {
    if (isClosed) throw StateError('serial transport closed');
    return simulatedModemStatus;
  }

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
