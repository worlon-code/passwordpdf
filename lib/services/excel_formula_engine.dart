import 'dart:math' as math;
import '../models/excel_workbook_model.dart';

/// AST Node base class
abstract class _AstNode {
  dynamic evaluate(_FormulaContext context);
}

class _NumberNode extends _AstNode {
  final double value;
  _NumberNode(this.value);
  @override
  dynamic evaluate(_FormulaContext context) => value;
}

class _StringNode extends _AstNode {
  final String value;
  _StringNode(this.value);
  @override
  dynamic evaluate(_FormulaContext context) => value;
}

class _BooleanNode extends _AstNode {
  final bool value;
  _BooleanNode(this.value);
  @override
  dynamic evaluate(_FormulaContext context) => value;
}

class _CellRefNode extends _AstNode {
  final String? sheetName;
  final int row;
  final int col;

  _CellRefNode({this.sheetName, required this.row, required this.col});

  @override
  dynamic evaluate(_FormulaContext context) {
    return context.getCellValue(sheetName, row, col);
  }
}

class _RangeRefNode extends _AstNode {
  final String? sheetName;
  final int startRow;
  final int startCol;
  final int endRow;
  final int endCol;

  _RangeRefNode({
    this.sheetName,
    required this.startRow,
    required this.startCol,
    required this.endRow,
    required this.endCol,
  });

  @override
  dynamic evaluate(_FormulaContext context) {
    return context.getRangeValues(sheetName, startRow, startCol, endRow, endCol);
  }
}

class _UnaryOpNode extends _AstNode {
  final String op;
  final _AstNode expr;
  _UnaryOpNode(this.op, this.expr);

  @override
  dynamic evaluate(_FormulaContext context) {
    final val = expr.evaluate(context);
    if (val is String && val.startsWith('#')) return val;
    final num = _toDouble(val);
    if (num == null) return '#VALUE!';
    if (op == '-') return -num;
    if (op == '+') return num;
    if (op == '%') return num / 100.0;
    return '#VALUE!';
  }
}

class _BinaryOpNode extends _AstNode {
  final String op;
  final _AstNode left;
  final _AstNode right;

  _BinaryOpNode(this.op, this.left, this.right);

  @override
  dynamic evaluate(_FormulaContext context) {
    final lVal = left.evaluate(context);
    if (lVal is String && lVal.startsWith('#')) return lVal;
    final rVal = right.evaluate(context);
    if (rVal is String && rVal.startsWith('#')) return rVal;

    // String concatenation
    if (op == '&') {
      return '${_toDisplayString(lVal)}${_toDisplayString(rVal)}';
    }

    // Comparison operators
    if (op == '=' || op == '<>' || op == '<' || op == '>' || op == '<=' || op == '>=') {
      return _compare(op, lVal, rVal);
    }

    // Arithmetic operators
    final lNum = _toDouble(lVal);
    final rNum = _toDouble(rVal);
    if (lNum == null || rNum == null) return '#VALUE!';

    switch (op) {
      case '+':
        return lNum + rNum;
      case '-':
        return lNum - rNum;
      case '*':
        return lNum * rNum;
      case '/':
        if (rNum == 0) return '#DIV/0!';
        return lNum / rNum;
      case '^':
        return math.pow(lNum, rNum).toDouble();
      default:
        return '#VALUE!';
    }
  }

  bool _compare(String op, dynamic a, dynamic b) {
    final aNum = _toDouble(a);
    final bNum = _toDouble(b);
    if (aNum != null && bNum != null) {
      switch (op) {
        case '=':
          return aNum == bNum;
        case '<>':
          return aNum != bNum;
        case '<':
          return aNum < bNum;
        case '>':
          return aNum > bNum;
        case '<=':
          return aNum <= bNum;
        case '>=':
          return aNum >= bNum;
      }
    }
    final aStr = a.toString().toLowerCase();
    final bStr = b.toString().toLowerCase();
    final cmp = aStr.compareTo(bStr);
    switch (op) {
      case '=':
        return cmp == 0;
      case '<>':
        return cmp != 0;
      case '<':
        return cmp < 0;
      case '>':
        return cmp > 0;
      case '<=':
        return cmp <= 0;
      case '>=':
        return cmp >= 0;
      default:
        return false;
    }
  }
}

class _FunctionCallNode extends _AstNode {
  final String name;
  final List<_AstNode> args;

  _FunctionCallNode(this.name, this.args);

  @override
  dynamic evaluate(_FormulaContext context) {
    return _evaluateFunction(name.toUpperCase(), args, context);
  }
}

// -----------------------------------------------------------------------------
// Formula Context
// -----------------------------------------------------------------------------

class _FormulaContext {
  final ExcelSheetModel sheet;
  final ExcelWorkbookModel? workbook;
  final Set<String> visiting;

  _FormulaContext({
    required this.sheet,
    this.workbook,
    Set<String>? visiting,
  }) : visiting = visiting ?? {};

  dynamic getCellValue(String? sheetName, int row, int col) {
    final targetSheet = sheetName != null && workbook != null
        ? (workbook!.getSheetByName(sheetName) ?? sheet)
        : sheet;

    final key = '${targetSheet.name}!$row:$col';
    if (visiting.contains(key)) {
      return '#CYCLE!';
    }

    final cell = targetSheet.getCell(row, col);
    if (cell == null || cell.rawValue.isEmpty) return 0.0;

    if (cell.hasFormula) {
      visiting.add(key);
      try {
        final engine = ExcelFormulaEngine();
        final res = engine.evaluate(
          formula: cell.formula!,
          sheet: targetSheet,
          workbook: workbook,
          visiting: visiting,
        );
        return res;
      } finally {
        visiting.remove(key);
      }
    }

    final num = _toDouble(cell.rawValue);
    if (num != null) return num;
    if (cell.rawValue.toLowerCase() == 'true') return true;
    if (cell.rawValue.toLowerCase() == 'false') return false;
    return cell.rawValue;
  }

  List<dynamic> getRangeValues(
      String? sheetName, int startRow, int startCol, int endRow, int endCol) {
    final targetSheet = sheetName != null && workbook != null
        ? (workbook!.getSheetByName(sheetName) ?? sheet)
        : sheet;

    final minR = math.min(startRow, endRow);
    final maxR = math.max(startRow, endRow);
    final minC = math.min(startCol, endCol);
    final maxC = math.max(startCol, endCol);

    final values = <dynamic>[];
    for (int r = minR; r <= maxR; r++) {
      for (int c = minC; c <= maxC; c++) {
        values.add(getCellValue(targetSheet.name, r, c));
      }
    }
    return values;
  }
}

// -----------------------------------------------------------------------------
// Formula Evaluator Functions
// -----------------------------------------------------------------------------

dynamic _evaluateFunction(
    String fn, List<_AstNode> argNodes, _FormulaContext context) {
  switch (fn) {
    // ---------------- Math & Stats ----------------
    case 'SUM': {
      final nums = _flattenNumbers(argNodes, context);
      if (nums.any((n) => n is String && n.startsWith('#'))) {
        return nums.firstWhere((n) => n is String && n.startsWith('#'));
      }
      return nums.fold<double>(0.0, (acc, n) => acc + (n as double));
    }
    case 'PRODUCT': {
      final nums = _flattenNumbers(argNodes, context);
      if (nums.isEmpty) return 0.0;
      if (nums.any((n) => n is String && n.startsWith('#'))) {
        return nums.firstWhere((n) => n is String && n.startsWith('#'));
      }
      return nums.fold<double>(1.0, (acc, n) => acc * (n as double));
    }
    case 'AVERAGE': {
      final nums = _flattenNumbers(argNodes, context);
      if (nums.isEmpty) return '#DIV/0!';
      if (nums.any((n) => n is String && n.startsWith('#'))) {
        return nums.firstWhere((n) => n is String && n.startsWith('#'));
      }
      final sum = nums.fold<double>(0.0, (acc, n) => acc + (n as double));
      return sum / nums.length;
    }
    case 'COUNT': {
      final nums = _flattenNumbers(argNodes, context);
      return nums.length.toDouble();
    }
    case 'COUNTA': {
      final items = _flattenAll(argNodes, context);
      return items.where((i) => i != null && i.toString().trim().isNotEmpty).length.toDouble();
    }
    case 'MIN': {
      final nums = _flattenNumbers(argNodes, context);
      if (nums.isEmpty) return 0.0;
      double min = double.infinity;
      for (final n in nums) {
        if (n is double && n < min) min = n;
      }
      return min.isInfinite ? 0.0 : min;
    }
    case 'MAX': {
      final nums = _flattenNumbers(argNodes, context);
      if (nums.isEmpty) return 0.0;
      double max = -double.infinity;
      for (final n in nums) {
        if (n is double && n > max) max = n;
      }
      return max.isInfinite ? 0.0 : max;
    }
    case 'MEDIAN': {
      final nums = _flattenNumbers(argNodes, context).whereType<double>().toList();
      if (nums.isEmpty) return '#NUM!';
      nums.sort();
      final mid = nums.length ~/ 2;
      if (nums.length % 2 == 1) return nums[mid];
      return (nums[mid - 1] + nums[mid]) / 2.0;
    }
    case 'ABS': {
      if (argNodes.isEmpty) return '#VALUE!';
      final val = _toDouble(argNodes[0].evaluate(context));
      if (val == null) return '#VALUE!';
      return val.abs();
    }
    case 'SQRT': {
      if (argNodes.isEmpty) return '#VALUE!';
      final val = _toDouble(argNodes[0].evaluate(context));
      if (val == null || val < 0) return '#NUM!';
      return math.sqrt(val);
    }
    case 'POW':
    case 'POWER': {
      if (argNodes.length < 2) return '#VALUE!';
      final b = _toDouble(argNodes[0].evaluate(context));
      final p = _toDouble(argNodes[1].evaluate(context));
      if (b == null || p == null) return '#VALUE!';
      return math.pow(b, p).toDouble();
    }
    case 'ROUND': {
      if (argNodes.isEmpty) return '#VALUE!';
      final val = _toDouble(argNodes[0].evaluate(context));
      if (val == null) return '#VALUE!';
      final digits = argNodes.length > 1 ? (_toDouble(argNodes[1].evaluate(context))?.toInt() ?? 0) : 0;
      final factor = math.pow(10, digits);
      return (val * factor).round() / factor;
    }
    case 'ROUNDUP': {
      if (argNodes.isEmpty) return '#VALUE!';
      final val = _toDouble(argNodes[0].evaluate(context));
      if (val == null) return '#VALUE!';
      final digits = argNodes.length > 1 ? (_toDouble(argNodes[1].evaluate(context))?.toInt() ?? 0) : 0;
      final factor = math.pow(10, digits);
      return (val * factor).ceil() / factor;
    }
    case 'ROUNDDOWN': {
      if (argNodes.isEmpty) return '#VALUE!';
      final val = _toDouble(argNodes[0].evaluate(context));
      if (val == null) return '#VALUE!';
      final digits = argNodes.length > 1 ? (_toDouble(argNodes[1].evaluate(context))?.toInt() ?? 0) : 0;
      final factor = math.pow(10, digits);
      return (val * factor).floor() / factor;
    }

    // ---------------- Logical ----------------
    case 'IF': {
      if (argNodes.isEmpty) return '#VALUE!';
      final cond = argNodes[0].evaluate(context);
      final isTrue = _toBool(cond);
      if (isTrue) {
        return argNodes.length > 1 ? argNodes[1].evaluate(context) : true;
      } else {
        return argNodes.length > 2 ? argNodes[2].evaluate(context) : false;
      }
    }
    case 'IFERROR': {
      if (argNodes.isEmpty) return '#VALUE!';
      final val = argNodes[0].evaluate(context);
      if (val is String && val.startsWith('#')) {
        return argNodes.length > 1 ? argNodes[1].evaluate(context) : '';
      }
      return val;
    }
    case 'AND': {
      if (argNodes.isEmpty) return '#VALUE!';
      final items = _flattenAll(argNodes, context);
      for (final item in items) {
        if (!_toBool(item)) return false;
      }
      return true;
    }
    case 'OR': {
      if (argNodes.isEmpty) return '#VALUE!';
      final items = _flattenAll(argNodes, context);
      for (final item in items) {
        if (_toBool(item)) return true;
      }
      return false;
    }
    case 'NOT': {
      if (argNodes.isEmpty) return '#VALUE!';
      return !_toBool(argNodes[0].evaluate(context));
    }

    // ---------------- Text ----------------
    case 'LEN': {
      if (argNodes.isEmpty) return 0.0;
      final val = _toDisplayString(argNodes[0].evaluate(context));
      return val.length.toDouble();
    }
    case 'UPPER': {
      if (argNodes.isEmpty) return '';
      return _toDisplayString(argNodes[0].evaluate(context)).toUpperCase();
    }
    case 'LOWER': {
      if (argNodes.isEmpty) return '';
      return _toDisplayString(argNodes[0].evaluate(context)).toLowerCase();
    }
    case 'TRIM': {
      if (argNodes.isEmpty) return '';
      return _toDisplayString(argNodes[0].evaluate(context)).trim();
    }
    case 'CONCAT':
    case 'CONCATENATE': {
      final items = _flattenAll(argNodes, context);
      return items.map((i) => _toDisplayString(i)).join();
    }
    case 'LEFT': {
      if (argNodes.isEmpty) return '';
      final str = _toDisplayString(argNodes[0].evaluate(context));
      final count = argNodes.length > 1 ? (_toDouble(argNodes[1].evaluate(context))?.toInt() ?? 1) : 1;
      if (count <= 0) return '';
      if (count >= str.length) return str;
      return str.substring(0, count);
    }
    case 'RIGHT': {
      if (argNodes.isEmpty) return '';
      final str = _toDisplayString(argNodes[0].evaluate(context));
      final count = argNodes.length > 1 ? (_toDouble(argNodes[1].evaluate(context))?.toInt() ?? 1) : 1;
      if (count <= 0) return '';
      if (count >= str.length) return str;
      return str.substring(str.length - count);
    }
    case 'MID': {
      if (argNodes.length < 3) return '#VALUE!';
      final str = _toDisplayString(argNodes[0].evaluate(context));
      final start = (_toDouble(argNodes[1].evaluate(context))?.toInt() ?? 1) - 1;
      final length = _toDouble(argNodes[2].evaluate(context))?.toInt() ?? 0;
      if (start < 0 || start >= str.length || length <= 0) return '';
      final end = math.min(start + length, str.length);
      return str.substring(start, end);
    }

    // ---------------- Lookup ----------------
    case 'VLOOKUP': {
      if (argNodes.length < 3) return '#N/A';
      final lookupVal = argNodes[0].evaluate(context);
      final rangeNode = argNodes[1];
      if (rangeNode is! _RangeRefNode) return '#VALUE!';
      final colIdx = (_toDouble(argNodes[2].evaluate(context))?.toInt() ?? 1) - 1;
      final exactMatch = argNodes.length > 3 ? !_toBool(argNodes[3].evaluate(context)) : true;

      final minR = math.min(rangeNode.startRow, rangeNode.endRow);
      final maxR = math.max(rangeNode.startRow, rangeNode.endRow);
      final minC = math.min(rangeNode.startCol, rangeNode.endCol);
      final maxC = math.max(rangeNode.startCol, rangeNode.endCol);

      if (colIdx < 0 || (minC + colIdx) > maxC) return '#REF!';

      final targetSheet = rangeNode.sheetName != null && context.workbook != null
          ? (context.workbook!.getSheetByName(rangeNode.sheetName!) ?? context.sheet)
          : context.sheet;

      final lookupStr = _toDisplayString(lookupVal).toLowerCase();

      for (int r = minR; r <= maxR; r++) {
        final firstCell = targetSheet.getCell(r, minC);
        final firstVal = firstCell?.evaluatedValue.toLowerCase() ?? '';
        if (exactMatch) {
          if (firstVal == lookupStr) {
            final targetCell = targetSheet.getCell(r, minC + colIdx);
            return targetCell?.evaluatedValue ?? '';
          }
        } else {
          if (firstVal.startsWith(lookupStr)) {
            final targetCell = targetSheet.getCell(r, minC + colIdx);
            return targetCell?.evaluatedValue ?? '';
          }
        }
      }
      return '#N/A';
    }

    // ---------------- Date ----------------
    case 'TODAY': {
      final now = DateTime.now();
      return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    }
    case 'NOW': {
      final now = DateTime.now();
      return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    }

    default:
      return '#NAME?';
  }
}

List<dynamic> _flattenAll(List<_AstNode> nodes, _FormulaContext context) {
  final list = <dynamic>[];
  for (final node in nodes) {
    final val = node.evaluate(context);
    if (val is List) {
      list.addAll(val);
    } else {
      list.add(val);
    }
  }
  return list;
}

List<dynamic> _flattenNumbers(List<_AstNode> nodes, _FormulaContext context) {
  final list = <dynamic>[];
  for (final node in nodes) {
    final val = node.evaluate(context);
    if (val is List) {
      for (final item in val) {
        if (item is String && item.startsWith('#')) {
          list.add(item);
        } else {
          final n = _toDouble(item);
          if (n != null) list.add(n);
        }
      }
    } else if (val is String && val.startsWith('#')) {
      list.add(val);
    } else {
      final n = _toDouble(val);
      if (n != null) list.add(n);
    }
  }
  return list;
}

double? _toDouble(dynamic val) {
  if (val == null) return null;
  if (val is num) return val.toDouble();
  if (val is bool) return val ? 1.0 : 0.0;
  final str = val.toString().replaceAll(',', '').replaceAll(RegExp(r'[$,₹%]'), '').trim();
  return double.tryParse(str);
}

bool _toBool(dynamic val) {
  if (val == null) return false;
  if (val is bool) return val;
  if (val is num) return val != 0;
  final str = val.toString().trim().toLowerCase();
  return str == 'true' || str == '1';
}

String _toDisplayString(dynamic val) {
  if (val == null) return '';
  if (val is double) {
    if (val == val.roundToDouble()) return val.toInt().toString();
    return val.toString();
  }
  return val.toString();
}

// -----------------------------------------------------------------------------
// Tokenizer & Parser
// -----------------------------------------------------------------------------

enum _TokenType {
  number,
  string,
  boolean,
  ident,
  cellRef,
  rangeRef,
  op,
  lparen,
  rparen,
  comma,
  eof,
}

class _Token {
  final _TokenType type;
  final String text;
  final dynamic value;

  _Token(this.type, this.text, [this.value]);
}

class _Parser {
  final List<_Token> tokens;
  int pos = 0;

  _Parser(this.tokens);

  _Token get current => pos < tokens.length ? tokens[pos] : _Token(_TokenType.eof, '');

  _Token consume() {
    final t = current;
    if (pos < tokens.length) pos++;
    return t;
  }

  bool match(_TokenType type, [String? text]) {
    if (current.type == type) {
      if (text == null || current.text == text) {
        consume();
        return true;
      }
    }
    return false;
  }

  _AstNode parse() {
    final node = parseExpression();
    return node;
  }

  _AstNode parseExpression() => parseComparison();

  _AstNode parseComparison() {
    var node = parseConcat();
    while (current.type == _TokenType.op &&
        (current.text == '=' ||
            current.text == '<>' ||
            current.text == '<' ||
            current.text == '>' ||
            current.text == '<=' ||
            current.text == '>=')) {
      final op = consume().text;
      final right = parseConcat();
      node = _BinaryOpNode(op, node, right);
    }
    return node;
  }

  _AstNode parseConcat() {
    var node = parseAdditive();
    while (current.type == _TokenType.op && current.text == '&') {
      final op = consume().text;
      final right = parseAdditive();
      node = _BinaryOpNode(op, node, right);
    }
    return node;
  }

  _AstNode parseAdditive() {
    var node = parseMultiplicative();
    while (current.type == _TokenType.op && (current.text == '+' || current.text == '-')) {
      final op = consume().text;
      final right = parseMultiplicative();
      node = _BinaryOpNode(op, node, right);
    }
    return node;
  }

  _AstNode parseMultiplicative() {
    var node = parseExponential();
    while (current.type == _TokenType.op && (current.text == '*' || current.text == '/')) {
      final op = consume().text;
      final right = parseExponential();
      node = _BinaryOpNode(op, node, right);
    }
    return node;
  }

  _AstNode parseExponential() {
    var node = parseUnary();
    while (current.type == _TokenType.op && current.text == '^') {
      final op = consume().text;
      final right = parseUnary();
      node = _BinaryOpNode(op, node, right);
    }
    return node;
  }

  _AstNode parseUnary() {
    if (current.type == _TokenType.op && (current.text == '+' || current.text == '-')) {
      final op = consume().text;
      final expr = parsePrimary();
      return _UnaryOpNode(op, expr);
    }
    var node = parsePrimary();
    if (current.type == _TokenType.op && current.text == '%') {
      consume();
      node = _UnaryOpNode('%', node);
    }
    return node;
  }

  _AstNode parsePrimary() {
    final t = current;
    if (t.type == _TokenType.number) {
      consume();
      return _NumberNode(t.value as double);
    }
    if (t.type == _TokenType.string) {
      consume();
      return _StringNode(t.value as String);
    }
    if (t.type == _TokenType.boolean) {
      consume();
      return _BooleanNode(t.value as bool);
    }
    if (t.type == _TokenType.rangeRef) {
      consume();
      return t.value as _RangeRefNode;
    }
    if (t.type == _TokenType.cellRef) {
      final firstRef = consume().value as _CellRefNode;
      if (current.type == _TokenType.op && current.text == ':') {
        consume(); // consume ':'
        if (current.type == _TokenType.cellRef) {
          final secondRef = consume().value as _CellRefNode;
          return _RangeRefNode(
            sheetName: firstRef.sheetName ?? secondRef.sheetName,
            startRow: firstRef.row,
            startCol: firstRef.col,
            endRow: secondRef.row,
            endCol: secondRef.col,
          );
        }
      }
      return firstRef;
    }
    if (t.type == _TokenType.ident) {
      final name = consume().text;
      if (match(_TokenType.lparen)) {
        final args = <_AstNode>[];
        if (!match(_TokenType.rparen)) {
          args.add(parseExpression());
          while (match(_TokenType.comma)) {
            args.add(parseExpression());
          }
          match(_TokenType.rparen);
        }
        return _FunctionCallNode(name, args);
      }
      return _StringNode(name);
    }
    if (match(_TokenType.lparen)) {
      final expr = parseExpression();
      match(_TokenType.rparen);
      return expr;
    }

    consume();
    return _StringNode('');
  }
}

List<_Token> _tokenize(String text) {
  final tokens = <_Token>[];
  var src = text.trim();
  if (src.startsWith('=')) src = src.substring(1).trim();

  int i = 0;
  while (i < src.length) {
    final ch = src[i];

    if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
      i++;
      continue;
    }

    if (ch == '(') {
      tokens.add(_Token(_TokenType.lparen, '('));
      i++;
      continue;
    }
    if (ch == ')') {
      tokens.add(_Token(_TokenType.rparen, ')'));
      i++;
      continue;
    }
    if (ch == ',') {
      tokens.add(_Token(_TokenType.comma, ','));
      i++;
      continue;
    }

    // String literals "..."
    if (ch == '"') {
      final buf = StringBuffer();
      i++;
      while (i < src.length) {
        if (src[i] == '"') {
          if (i + 1 < src.length && src[i + 1] == '"') {
            buf.write('"');
            i += 2;
          } else {
            i++;
            break;
          }
        } else {
          buf.write(src[i]);
          i++;
        }
      }
      tokens.add(_Token(_TokenType.string, buf.toString(), buf.toString()));
      continue;
    }

    // Numbers
    if (RegExp(r'\d').hasMatch(ch) || (ch == '.' && i + 1 < src.length && RegExp(r'\d').hasMatch(src[i + 1]))) {
      final start = i;
      while (i < src.length && RegExp(r'[\d.]').hasMatch(src[i])) {
        i++;
      }
      final numStr = src.substring(start, i);
      tokens.add(_Token(_TokenType.number, numStr, double.tryParse(numStr) ?? 0.0));
      continue;
    }

    // Operators
    if (ch == '<') {
      if (i + 1 < src.length && src[i + 1] == '>') {
        tokens.add(_Token(_TokenType.op, '<>'));
        i += 2;
      } else if (i + 1 < src.length && src[i + 1] == '=') {
        tokens.add(_Token(_TokenType.op, '<='));
        i += 2;
      } else {
        tokens.add(_Token(_TokenType.op, '<'));
        i++;
      }
      continue;
    }
    if (ch == '>') {
      if (i + 1 < src.length && src[i + 1] == '=') {
        tokens.add(_Token(_TokenType.op, '>='));
        i += 2;
      } else {
        tokens.add(_Token(_TokenType.op, '>'));
        i++;
      }
      continue;
    }
    if (ch == '=') {
      tokens.add(_Token(_TokenType.op, '='));
      i++;
      continue;
    }
    if (ch == '+' || ch == '-' || ch == '*' || ch == '/' || ch == '^' || ch == '%' || ch == '&' || ch == ':') {
      tokens.add(_Token(_TokenType.op, ch));
      i++;
      continue;
    }

    // Identifiers, Sheet refs, Range refs, or Cell refs
    if (RegExp(r'[A-Za-z_]').hasMatch(ch) || ch == r'$') {
      final start = i;
      while (i < src.length && RegExp(r'[A-Za-z0-9_!$:]').hasMatch(src[i])) {
        i++;
      }
      final raw = src.substring(start, i);

      // Check if it's a range ref like A1:B10 or Sheet1!A1:B10
      if (raw.contains(':')) {
        final parts = raw.split(':');
        if (parts.length == 2) {
          String? sheetName;
          String first = parts[0];
          if (first.contains('!')) {
            final sp = first.split('!');
            sheetName = sp[0];
            first = sp[1];
          }
          final rc1 = cellCoordinateToRowCol(first);
          final rc2 = cellCoordinateToRowCol(parts[1]);
          if (rc1 != null && rc2 != null) {
            tokens.add(_Token(
              _TokenType.rangeRef,
              raw,
              _RangeRefNode(
                sheetName: sheetName,
                startRow: rc1.$1,
                startCol: rc1.$2,
                endRow: rc2.$1,
                endCol: rc2.$2,
              ),
            ));
            continue;
          }
        }
      }

      // Check if it's a single cell ref like A1, $A$1, or Sheet1!A1
      String? sheetName;
      String coord = raw;
      if (raw.contains('!')) {
        final sp = raw.split('!');
        sheetName = sp[0];
        coord = sp[1];
      }
      final rc = cellCoordinateToRowCol(coord);
      if (rc != null) {
        tokens.add(_Token(
          _TokenType.cellRef,
          raw,
          _CellRefNode(sheetName: sheetName, row: rc.$1, col: rc.$2),
        ));
        continue;
      }

      if (raw.toUpperCase() == 'TRUE') {
        tokens.add(_Token(_TokenType.boolean, raw, true));
        continue;
      }
      if (raw.toUpperCase() == 'FALSE') {
        tokens.add(_Token(_TokenType.boolean, raw, false));
        continue;
      }

      tokens.add(_Token(_TokenType.ident, raw));
      continue;
    }

    i++;
  }

  tokens.add(_Token(_TokenType.eof, ''));
  return tokens;
}

/// The top-level Excel Formula Engine
class ExcelFormulaEngine {
  static final ExcelFormulaEngine _instance = ExcelFormulaEngine._internal();
  factory ExcelFormulaEngine() => _instance;
  ExcelFormulaEngine._internal();

  /// Evaluates an Excel formula string
  dynamic evaluate({
    required String formula,
    required ExcelSheetModel sheet,
    ExcelWorkbookModel? workbook,
    Set<String>? visiting,
  }) {
    if (!formula.startsWith('=')) {
      final num = double.tryParse(formula.trim());
      if (num != null) return num;
      return formula;
    }

    try {
      final tokens = _tokenize(formula);
      final parser = _Parser(tokens);
      final ast = parser.parse();
      final context = _FormulaContext(
        sheet: sheet,
        workbook: workbook,
        visiting: visiting,
      );
      return ast.evaluate(context);
    } catch (_) {
      return '#VALUE!';
    }
  }

  /// Recalculates all cells with formulas in a worksheet
  void recalculateSheet(ExcelSheetModel sheet, [ExcelWorkbookModel? workbook]) {
    for (final entry in sheet.cells.entries) {
      final cell = entry.value;
      if (cell.hasFormula) {
        final res = evaluate(
          formula: cell.formula!,
          sheet: sheet,
          workbook: workbook,
        );
        cell.evaluatedValue = _toDisplayString(res);
      } else {
        cell.evaluatedValue = cell.rawValue;
      }
    }
  }
}
