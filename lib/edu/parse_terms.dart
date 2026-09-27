class ParsedTerm {
  const ParsedTerm({required this.xn, required this.xq, required this.label, required this.code});
  final String xn;
  final String xq;
  final String label;
  final String code;
}

List<ParsedTerm> parseTerms(List<Object?> list) {
  return list.map((item) {
    final map = (item as Map).cast<String, Object?>();
    final code = '${map['code'] ?? ''}';
    final parts = code.split('-');
    if (parts.length != 2 || !RegExp(r'^\d{4}$').hasMatch(parts[0]) || !RegExp(r'^\d$').hasMatch(parts[1])) {
      throw FormatException('无法解析学期代码 $code');
    }
    return ParsedTerm(xn: parts[0], xq: parts[1], label: '${map['name'] ?? ''}', code: code);
  }).toList();
}

({String xn, String xq})? parsePublicCurrent(String html) {
  final xn = RegExp(r'id="xn"[^>]*value="(\d{4})"').firstMatch(html)?.group(1) ?? '';
  final xq = RegExp(r'id="xq_m"[^>]*value="(\d)"').firstMatch(html)?.group(1) ?? '';
  if (xn.isEmpty || xq.isEmpty) return null;
  return (xn: xn, xq: xq);
}
