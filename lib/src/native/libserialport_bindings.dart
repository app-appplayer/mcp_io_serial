/// Minimal `dart:ffi` bindings for libserialport (sigrok project).
///
/// Covers the surface used by [LibserialportSerialTransport]:
///   - port discovery / open / close / free
///   - configuration (baudrate, data bits, parity, stop bits, flow control)
///   - non-blocking byte read / write
///   - DTR / RTS / BREAK control
///
/// The native library is loaded at runtime via [openLibserialport] —
/// callers may supply an explicit path (handy for Flutter desktop where
/// the library ships next to the app bundle); otherwise the OS-default
/// search rules apply (`libserialport.so.0` / `libserialport.dylib` /
/// `libserialport.dll`).
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Default per-platform soname / filename for libserialport.
String defaultLibserialportFilename() {
  if (Platform.isLinux) return 'libserialport.so.0';
  if (Platform.isMacOS) return 'libserialport.dylib';
  if (Platform.isWindows) return 'libserialport.dll';
  return 'libserialport';
}

/// Opens libserialport from [path] (or the default soname when null).
/// Throws if the library is not present on the system.
DynamicLibrary openLibserialport({String? path}) {
  final p = path ?? defaultLibserialportFilename();
  return DynamicLibrary.open(p);
}

// === Native enums (mirror libserialport.h) ===

/// `sp_return` — libserialport error / success codes.
class SpReturn {
  static const int ok = 0;
  static const int errArg = -1;
  static const int errFail = -2;
  static const int errMem = -3;
  static const int errSupp = -4;
}

/// `sp_mode` — open mode flags.
class SpMode {
  static const int read = 1;
  static const int write = 2;
  static const int readWrite = 3;
}

/// `sp_parity`.
class SpParity {
  static const int invalid = -1;
  static const int none = 0;
  static const int odd = 1;
  static const int even = 2;
  static const int mark = 3;
  static const int space = 4;
}

/// `sp_flowcontrol`.
class SpFlowControl {
  static const int none = 0;
  static const int xonXoff = 1;
  static const int rtsCts = 2;
  static const int dtrDsr = 3;
}

/// `sp_signal` — for [LibserialportBindings.spSetDtr] / `spSetRts`.
class SpSignal {
  static const int low = 0;
  static const int high = 1;
}

/// `sp_signal` bitmask returned by `sp_get_signals` (libserialport.h).
class SpSignalMask {
  /// Clear To Send.
  static const int cts = 1;

  /// Data Set Ready.
  static const int dsr = 2;

  /// Data Carrier Detect (a.k.a. RLSD).
  static const int dcd = 4;

  /// Ring Indicator.
  static const int ri = 8;
}

// === FFI signatures ===

typedef SpGetPortByNameNative = Int32 Function(
    Pointer<Utf8> portName, Pointer<Pointer<Void>> portPtr);
typedef SpGetPortByNameDart = int Function(
    Pointer<Utf8> portName, Pointer<Pointer<Void>> portPtr);

typedef SpVoidIntNative = Int32 Function(Pointer<Void> port);
typedef SpVoidIntDart = int Function(Pointer<Void> port);

typedef SpVoidIntFlagNative = Int32 Function(Pointer<Void> port, Int32 flag);
typedef SpVoidIntFlagDart = int Function(Pointer<Void> port, int flag);

typedef SpFreePortNative = Void Function(Pointer<Void> port);
typedef SpFreePortDart = void Function(Pointer<Void> port);

typedef SpReadWriteNative = IntPtr Function(
    Pointer<Void> port, Pointer<Uint8> buf, IntPtr count);
typedef SpReadWriteDart = int Function(
    Pointer<Void> port, Pointer<Uint8> buf, int count);

typedef SpGetSignalsNative = Int32 Function(
    Pointer<Void> port, Pointer<Int32> signals);
typedef SpGetSignalsDart = int Function(
    Pointer<Void> port, Pointer<Int32> signals);

class LibserialportBindings {
  LibserialportBindings(DynamicLibrary lib)
      : spGetPortByName = lib.lookupFunction<SpGetPortByNameNative,
            SpGetPortByNameDart>('sp_get_port_by_name'),
        spOpen = lib.lookupFunction<SpVoidIntFlagNative, SpVoidIntFlagDart>(
            'sp_open'),
        spClose = lib.lookupFunction<SpVoidIntNative, SpVoidIntDart>(
            'sp_close'),
        spFreePort = lib.lookupFunction<SpFreePortNative, SpFreePortDart>(
            'sp_free_port'),
        spSetBaudrate =
            lib.lookupFunction<SpVoidIntFlagNative, SpVoidIntFlagDart>(
                'sp_set_baudrate'),
        spSetBits = lib
            .lookupFunction<SpVoidIntFlagNative, SpVoidIntFlagDart>(
                'sp_set_bits'),
        spSetParity =
            lib.lookupFunction<SpVoidIntFlagNative, SpVoidIntFlagDart>(
                'sp_set_parity'),
        spSetStopBits =
            lib.lookupFunction<SpVoidIntFlagNative, SpVoidIntFlagDart>(
                'sp_set_stopbits'),
        spSetFlowControl =
            lib.lookupFunction<SpVoidIntFlagNative, SpVoidIntFlagDart>(
                'sp_set_flowcontrol'),
        spNonblockingWrite =
            lib.lookupFunction<SpReadWriteNative, SpReadWriteDart>(
                'sp_nonblocking_write'),
        spNonblockingRead =
            lib.lookupFunction<SpReadWriteNative, SpReadWriteDart>(
                'sp_nonblocking_read'),
        spSetDtr = lib
            .lookupFunction<SpVoidIntFlagNative, SpVoidIntFlagDart>(
                'sp_set_dtr'),
        spSetRts = lib
            .lookupFunction<SpVoidIntFlagNative, SpVoidIntFlagDart>(
                'sp_set_rts'),
        spStartBreak = lib.lookupFunction<SpVoidIntNative, SpVoidIntDart>(
            'sp_start_break'),
        spEndBreak = lib.lookupFunction<SpVoidIntNative, SpVoidIntDart>(
            'sp_end_break'),
        spGetSignals =
            lib.lookupFunction<SpGetSignalsNative, SpGetSignalsDart>(
                'sp_get_signals');

  final SpGetPortByNameDart spGetPortByName;
  final SpVoidIntFlagDart spOpen;
  final SpVoidIntDart spClose;
  final SpFreePortDart spFreePort;
  final SpVoidIntFlagDart spSetBaudrate;
  final SpVoidIntFlagDart spSetBits;
  final SpVoidIntFlagDart spSetParity;
  final SpVoidIntFlagDart spSetStopBits;
  final SpVoidIntFlagDart spSetFlowControl;
  final SpReadWriteDart spNonblockingWrite;
  final SpReadWriteDart spNonblockingRead;
  final SpVoidIntFlagDart spSetDtr;
  final SpVoidIntFlagDart spSetRts;
  final SpVoidIntDart spStartBreak;
  final SpVoidIntDart spEndBreak;
  final SpGetSignalsDart spGetSignals;
}
