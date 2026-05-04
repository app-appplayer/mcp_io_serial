/// Production [SerialTransport] backed by libserialport via direct
/// `dart:ffi` bindings.
///
/// The transport polls the port at [pollInterval] and emits any pending
/// bytes onto [incoming]. Polling pacing trades latency vs. CPU — the
/// default 5 ms is a reasonable compromise for industrial UART.
///
/// libserialport must be installed on the host system. On Linux the
/// `libserialport0` package; on macOS `brew install libserialport`; on
/// Windows the prebuilt DLL must sit on the search path or be supplied
/// via the `libraryPath` constructor argument.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../serial_config.dart';
import '../serial_transport.dart';
import 'libserialport_bindings.dart';

class LibserialportSerialTransport implements SerialTransport {
  final LibserialportBindings _bindings;
  final Duration pollInterval;
  final int readBufferSize;

  Pointer<Void>? _port;
  Timer? _pollTimer;
  bool _isOpen = false;
  bool _isClosed = false;
  Pointer<Uint8>? _readBuf;

  // ignore: close_sinks
  final StreamController<Uint8List> _rxCtrl =
      StreamController<Uint8List>.broadcast();

  LibserialportSerialTransport({
    DynamicLibrary? library,
    String? libraryPath,
    this.pollInterval = const Duration(milliseconds: 5),
    this.readBufferSize = 1024,
  }) : _bindings =
            LibserialportBindings(library ?? openLibserialport(path: libraryPath));

  /// Construct from an already-instantiated bindings instance — useful
  /// for tests that mock the FFI surface.
  LibserialportSerialTransport.withBindings(
    this._bindings, {
    this.pollInterval = const Duration(milliseconds: 5),
    this.readBufferSize = 1024,
  });

  bool get isOpen => _isOpen && !_isClosed;

  @override
  Future<void> open(String portName, SerialConfig config) async {
    if (_isClosed) {
      throw StateError('LibserialportSerialTransport already closed');
    }
    if (_isOpen) return;

    final namePtr = portName.toNativeUtf8();
    final portHandle = calloc<Pointer<Void>>();
    try {
      _check(_bindings.spGetPortByName(namePtr, portHandle),
          'sp_get_port_by_name($portName)');
      _port = portHandle.value;
      _check(_bindings.spOpen(_port!, SpMode.readWrite), 'sp_open');
      _check(_bindings.spSetBaudrate(_port!, config.baudRate),
          'sp_set_baudrate(${config.baudRate})');
      _check(_bindings.spSetBits(_port!, config.dataBits),
          'sp_set_bits(${config.dataBits})');
      _check(_bindings.spSetParity(_port!, _parityToNative(config.parity)),
          'sp_set_parity');
      _check(_bindings.spSetStopBits(_port!, config.stopBits),
          'sp_set_stopbits(${config.stopBits})');
      _check(
        _bindings.spSetFlowControl(
          _port!, _flowControlToNative(config.flowControl),
        ),
        'sp_set_flowcontrol',
      );
      _readBuf = malloc<Uint8>(readBufferSize);
      _isOpen = true;
      _pollTimer = Timer.periodic(pollInterval, (_) => _drainOne());
    } finally {
      malloc.free(namePtr);
      calloc.free(portHandle);
    }
  }

  @override
  Future<void> write(List<int> bytes) async {
    if (!isOpen) {
      throw StateError('LibserialportSerialTransport not open');
    }
    final buf = malloc<Uint8>(bytes.length);
    try {
      for (var i = 0; i < bytes.length; i++) {
        buf[i] = bytes[i] & 0xFF;
      }
      var remaining = bytes.length;
      var offset = 0;
      while (remaining > 0) {
        final written = _bindings.spNonblockingWrite(
          _port!, buf + offset, remaining,
        );
        if (written < 0) {
          throw StateError('sp_nonblocking_write failed: rc=$written');
        }
        if (written == 0) {
          // Yield so the caller can retry; libserialport's non-blocking
          // path returns 0 when the OS buffer is full.
          await Future<void>.delayed(const Duration(milliseconds: 1));
          continue;
        }
        remaining -= written;
        offset += written;
      }
    } finally {
      malloc.free(buf);
    }
  }

  @override
  Stream<Uint8List> get incoming => _rxCtrl.stream;

  void _drainOne() {
    final port = _port;
    final buf = _readBuf;
    if (port == null || buf == null) return;
    final n = _bindings.spNonblockingRead(port, buf, readBufferSize);
    if (n <= 0) return;
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = buf[i];
    }
    if (!_rxCtrl.isClosed) {
      _rxCtrl.add(out);
    }
  }

  // === SerialTransport control-line extensions ===

  @override
  Future<void> setDtr(bool active) async {
    if (!isOpen) throw StateError('LibserialportSerialTransport not open');
    _check(
      _bindings.spSetDtr(_port!, active ? SpSignal.high : SpSignal.low),
      'sp_set_dtr',
    );
  }

  @override
  Future<void> setRts(bool active) async {
    if (!isOpen) throw StateError('LibserialportSerialTransport not open');
    _check(
      _bindings.spSetRts(_port!, active ? SpSignal.high : SpSignal.low),
      'sp_set_rts',
    );
  }

  @override
  Future<void> sendBreak({
    Duration duration = const Duration(milliseconds: 250),
  }) async {
    if (!isOpen) throw StateError('LibserialportSerialTransport not open');
    _check(_bindings.spStartBreak(_port!), 'sp_start_break');
    await Future<void>.delayed(duration);
    _check(_bindings.spEndBreak(_port!), 'sp_end_break');
  }

  @override
  Future<ModemStatus> readModemStatus() async {
    if (!isOpen) throw StateError('LibserialportSerialTransport not open');
    final bitsPtr = malloc<Int32>();
    try {
      _check(
        _bindings.spGetSignals(_port!, bitsPtr),
        'sp_get_signals',
      );
      final bits = bitsPtr.value;
      return ModemStatus(
        cts: (bits & SpSignalMask.cts) != 0,
        dsr: (bits & SpSignalMask.dsr) != 0,
        ri: (bits & SpSignalMask.ri) != 0,
        cd: (bits & SpSignalMask.dcd) != 0,
      );
    } finally {
      malloc.free(bitsPtr);
    }
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    final port = _port;
    if (port != null) {
      _bindings.spClose(port);
      _bindings.spFreePort(port);
      _port = null;
    }
    final buf = _readBuf;
    if (buf != null) {
      malloc.free(buf);
      _readBuf = null;
    }
    if (!_rxCtrl.isClosed) {
      await _rxCtrl.close();
    }
  }

  static void _check(int rc, String op) {
    if (rc < 0) {
      throw StateError('libserialport: $op failed with rc=$rc');
    }
  }

  static int _parityToNative(SerialParity parity) {
    switch (parity) {
      case SerialParity.none:
        return SpParity.none;
      case SerialParity.odd:
        return SpParity.odd;
      case SerialParity.even:
        return SpParity.even;
      case SerialParity.mark:
        return SpParity.mark;
      case SerialParity.space:
        return SpParity.space;
    }
  }

  static int _flowControlToNative(SerialFlowControl fc) {
    switch (fc) {
      case SerialFlowControl.none:
        return SpFlowControl.none;
      case SerialFlowControl.xonXoff:
        return SpFlowControl.xonXoff;
      case SerialFlowControl.rtsCts:
        return SpFlowControl.rtsCts;
    }
  }
}
