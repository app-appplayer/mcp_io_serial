/// `dart:io` + `dart:ffi`-only additions for `mcp_io_serial`.
///
/// Importing the main `mcp_io_serial` library keeps the package web-safe
/// (the abstract `SerialTransport` + `InMemorySerialTransport`). Importing
/// this `native` library opts in to the libserialport-backed
/// implementation and is only available on VM / Flutter desktop / Flutter
/// mobile (anywhere `dart:ffi` works).
///
/// Runtime requirement: the `libserialport` shared library must be on
/// the system search path, or supply `libraryPath:` to the constructor.
///
/// ```dart
/// import 'package:mcp_io_serial/mcp_io_serial.dart';
/// import 'package:mcp_io_serial/native.dart';
///
/// final transport = LibserialportSerialTransport();
/// final adapter = SerialIoAdapter(
///   deviceId: 'uart-1',
///   portName: '/dev/ttyUSB0',
///   config: const SerialConfig(baudRate: 115200),
///   transport: transport,
/// );
/// await adapter.connect();
/// ```
library;

export 'src/native/libserialport_bindings.dart';
export 'src/native/libserialport_transport.dart';
