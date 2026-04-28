/// Serial port UART configuration model.
library;

enum SerialParity { none, even, odd, mark, space }

enum SerialFlowControl { none, rtsCts, xonXoff }

class SerialConfig {
  /// Bits per second. Common values: 9600, 19200, 38400, 57600, 115200.
  final int baudRate;

  /// Data bits per character (typically 7 or 8).
  final int dataBits;

  /// Stop bits (1 or 2; some devices use 1.5 which is modeled as 2 here).
  final int stopBits;

  final SerialParity parity;

  final SerialFlowControl flowControl;

  const SerialConfig({
    this.baudRate = 9600,
    this.dataBits = 8,
    this.stopBits = 1,
    this.parity = SerialParity.none,
    this.flowControl = SerialFlowControl.none,
  });

  /// Short descriptor in the classic "115200 8N1" form.
  String get short =>
      '$baudRate $dataBits${_parityCode(parity)}$stopBits';

  static String _parityCode(SerialParity p) {
    switch (p) {
      case SerialParity.none:
        return 'N';
      case SerialParity.even:
        return 'E';
      case SerialParity.odd:
        return 'O';
      case SerialParity.mark:
        return 'M';
      case SerialParity.space:
        return 'S';
    }
  }
}
