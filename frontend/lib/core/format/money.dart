/// "$1.23", or "$0.0042" for small amounts.
String formatMicros(int micros) {
  final usd = micros / 1e6;
  if (usd == 0) return r'$0';
  if (usd.abs() < 0.01) return '\$${usd.toStringAsFixed(4)}';
  return '\$${usd.toStringAsFixed(2)}';
}
