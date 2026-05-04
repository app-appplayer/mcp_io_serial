## [0.2.0] - 2026-05-04

- Stream modes (raw / line-delimited / length-prefixed).
- Production native transport — `libserialport` FFI bindings (Linux /
  macOS / Windows).
- Modem-status read (`cts` / `dsr` / `ri` / `cd`) + `IoError` mapping.

## [0.1.0] - 2026-04-28 - Initial Release

### Added
- Serial port (UART / RS-232 / USB-Serial) transport and adapter for mcp_io.
- Byte mode and line-delimited mode.
- Configurable baud / parity / stop bits / flow control.
