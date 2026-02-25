import 'dart:convert';

List<Map<String, dynamic>> parseJsonTableData(String jsonStr) {
  try {
    final decoded = jsonDecode(jsonStr);
    if (decoded is List) {
      return List<Map<String, dynamic>>.from(decoded.map((e) => Map<String, dynamic>.from(e)));
    } else if (decoded is Map) {
      return [Map<String, dynamic>.from(decoded)];
    }
    return [];
  } catch (e) {
    return [{'error': 'Failed to parse JSON: $e'}];
  }
}
