## [0.2.1] - 2026-05-23 - mcp_bundle 0.4.0 cascade

### Changed (cascade)
- `mcp_bundle` caret bumped from `^0.3.0` to `^0.4.0`.
- `mcp_io` caret bumped from `^0.2.0` to `^0.2.1`.

mcp_io_serial does not touch `UiSection.pages` directly — caret-only cascade. Consumers should bump to `^0.2.1`.

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
