import 'package:material_ui/material_ui.dart';

/// The PTY grid that fits the output viewport at the rendered monospace size.
/// Reserved height covers the floating header and input controls.
({int cols, int rows}) fitTerminalViewport({
  required double width,
  required double height,
  required double cellWidth,
  required double lineHeight,
  required double reservedHeight,
}) {
  if (!width.isFinite ||
      !height.isFinite ||
      !cellWidth.isFinite ||
      !lineHeight.isFinite ||
      !reservedHeight.isFinite ||
      cellWidth <= 0 ||
      lineHeight <= 0 ||
      reservedHeight < 0) {
    throw ArgumentError('Invalid terminal viewport');
  }
  return (
    cols: ((width - 40) / cellWidth).floor().clamp(2, 500),
    rows: ((height - reservedHeight) / lineHeight).floor().clamp(1, 200),
  );
}

/// A bounded, already-interpreted xterm buffer received from the Android Host.
/// No ANSI control sequence is interpreted or displayed by this widget.
class TerminalScreenData {
  const TerminalScreenData({
    required this.cols,
    required this.rows,
    required this.start,
    required this.cursorCol,
    required this.cursorRow,
    required this.cursorVisible,
    required this.cursorStyle,
    required this.cursorBlink,
    required this.palette,
    this.foreground,
    this.background,
    this.cursorColor,
    required this.stylesTruncated,
    required this.lines,
  });

  final int cols, rows, start, cursorCol, cursorRow;
  final bool cursorVisible, cursorBlink;
  final String cursorStyle;
  final Map<int, Color> palette;
  final Color? foreground, background, cursorColor;
  final bool stylesTruncated;
  final List<TerminalScreenLineData> lines;

  static TerminalScreenData parse(Object? value) {
    if (value is! Map) throw const FormatException('Invalid terminal view');
    final cols = value['cols'];
    final rows = value['rows'];
    final start = value['start'];
    final cursor = value['cursor'];
    final source = value['lines'];
    final stylesTruncated = value['stylesTruncated'] ?? false;
    final cursorVisible = value['cursorVisible'] ?? true;
    final cursorStyle = value['cursorStyle'] ?? 'block';
    final cursorBlink = value['cursorBlink'] ?? true;
    final palette = value['palette'] ?? const <String, Object>{};
    if (cols is! int ||
        cols < 2 ||
        cols > 500 ||
        rows is! int ||
        rows < 1 ||
        rows > 200 ||
        start is! int ||
        start < 0 ||
        cursor is! Map ||
        source is! List ||
        source.length > 500 ||
        stylesTruncated is! bool ||
        cursorVisible is! bool ||
        cursorBlink is! bool ||
        !const ['block', 'underline', 'bar'].contains(cursorStyle) ||
        palette is! Map) {
      throw const FormatException('Invalid terminal view');
    }
    final indexed = palette['indexed'] ?? const <String, Object>{};
    if (indexed is! Map || indexed.length > 256) {
      throw const FormatException('Invalid terminal palette');
    }
    final colors = <int, Color>{};
    for (final entry in indexed.entries) {
      final key = int.tryParse(entry.key.toString());
      if (key == null ||
          key < 0 ||
          key > 255 ||
          key.toString() != entry.key ||
          entry.value is! String) {
        throw const FormatException('Invalid terminal palette');
      }
      colors[key] = _hexColor(entry.value);
    }
    Color? specialColor(String name) {
      final source = palette[name];
      if (source == null) return null;
      if (source is! String) {
        throw const FormatException('Invalid terminal palette');
      }
      return _hexColor(source);
    }

    final cursorCol = cursor['col'];
    final cursorRow = cursor['row'];
    if (cursorCol is! int ||
        cursorCol < 0 ||
        cursorCol > cols ||
        cursorRow is! int ||
        cursorRow < 0 ||
        cursorRow >= source.length) {
      throw const FormatException('Invalid terminal cursor');
    }
    var projectedCells = 0;
    final lines = <TerminalScreenLineData>[];
    for (final row in source) {
      if (row is! Map || row['wrapped'] is! bool || row['runs'] is! List) {
        throw const FormatException('Invalid terminal line');
      }
      final runs = <TerminalScreenRun>[];
      for (final item in row['runs'] as List) {
        if (item is! Map ||
            item['text'] is! String ||
            (item['text'] as String).isEmpty ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(item['text'] as String)) {
          throw const FormatException('Invalid terminal cell run');
        }
        projectedCells += (item['text'] as String).length;
        if (projectedCells > 200000 || runs.length >= cols) {
          throw const FormatException('Terminal view exceeds its bounds');
        }
        runs.add(TerminalScreenRun.parse(item));
      }
      lines.add(TerminalScreenLineData(runs: runs));
    }
    return TerminalScreenData(
      cols: cols,
      rows: rows,
      start: start,
      cursorCol: cursorCol,
      cursorRow: cursorRow,
      cursorVisible: cursorVisible,
      cursorStyle: cursorStyle as String,
      cursorBlink: cursorBlink,
      palette: colors,
      foreground: specialColor('foreground'),
      background: specialColor('background'),
      cursorColor: specialColor('cursor'),
      stylesTruncated: stylesTruncated,
      lines: lines,
    );
  }
}

Color _hexColor(String source) {
  if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(source)) {
    throw const FormatException('Invalid terminal palette color');
  }
  return Color(0xff000000 | int.parse(source.substring(1), radix: 16));
}

class TerminalScreenLineData {
  const TerminalScreenLineData({required this.runs});
  final List<TerminalScreenRun> runs;
}

class TerminalScreenRun {
  const TerminalScreenRun({
    required this.text,
    this.fg,
    this.bg,
    this.bold = false,
    this.dim = false,
    this.inverse = false,
    this.underline = false,
    this.invisible = false,
    this.cursor = false,
  });

  final String text;
  final Object? fg, bg;
  final bool bold, dim, inverse, underline, invisible, cursor;

  static TerminalScreenRun parse(Map value) {
    bool flag(String name) {
      final source = value[name];
      if (source is! bool) {
        throw const FormatException('Invalid terminal style');
      }
      return source;
    }

    Object? color(String name) {
      final source = value[name];
      if (source == null) return null;
      if (source is int && source >= 0 && source <= 255) return source;
      if (source is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(source)) {
        return source;
      }
      throw const FormatException('Invalid terminal color');
    }

    return TerminalScreenRun(
      text: value['text'] as String,
      fg: color('fg'),
      bg: color('bg'),
      bold: flag('bold'),
      dim: flag('dim'),
      inverse: flag('inverse'),
      underline: flag('underline'),
      invisible: flag('invisible'),
      cursor: flag('cursor'),
    );
  }
}

/// xterm's default 16-color palette; extended colors follow its 6x6x6 cube.
Color? terminalColor(Object? source, {Map<int, Color> palette = const {}}) {
  if (source == null) return null;
  if (source is String) {
    return Color(0xff000000 | int.parse(source.substring(1), radix: 16));
  }
  final index = source as int;
  if (palette.containsKey(index)) return palette[index];
  const basic = <int>[
    0x2e3436,
    0xcc0000,
    0x4e9a06,
    0xc4a000,
    0x3465a4,
    0x75507b,
    0x06989a,
    0xd3d7cf,
    0x555753,
    0xef2929,
    0x8ae234,
    0xfce94f,
    0x729fcf,
    0xad7fa8,
    0x34e2e2,
    0xeeeeec,
  ];
  if (index < 16) return Color(0xff000000 | basic[index]);
  if (index < 232) {
    final cube = index - 16;
    int channel(int value) => value == 0 ? 0 : 55 + value * 40;
    final red = channel(cube ~/ 36);
    final green = channel((cube ~/ 6) % 6);
    final blue = channel(cube % 6);
    return Color(0xff000000 | red << 16 | green << 8 | blue);
  }
  final gray = 8 + (index - 232) * 10;
  return Color(0xff000000 | gray << 16 | gray << 8 | gray);
}

/// One fixed-height terminal row. Runs preserve VT attributes and cursor cell.
class TerminalScreenLine extends StatelessWidget {
  static const _cellTextStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 13,
    height: 1.35,
  );

  const TerminalScreenLine({
    super.key,
    required this.line,
    required this.running,
    this.palette = const {},
    this.foreground,
    this.background,
    this.cursorColor,
    this.cursorStyle = 'block',
  });

  final TerminalScreenLineData line;
  final bool running;
  final Map<int, Color> palette;
  final Color? foreground, background, cursorColor;
  final String cursorStyle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final normalFg = foreground ?? scheme.onSurface;
    final normalBg = background ?? scheme.surface;
    final cursorBg = cursorColor ?? normalFg;
    final cursorFg = normalBg;
    return RichText(
      maxLines: 1,
      softWrap: false,
      textScaler: MediaQuery.textScalerOf(context),
      text: TextSpan(
        style: _cellTextStyle.copyWith(color: normalFg),
        children: [
          if (line.runs.isEmpty) const TextSpan(text: ' '),
          for (final run in line.runs)
            if (run.cursor && running && cursorStyle == 'bar')
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: CustomPaint(
                  foregroundPainter: _TerminalBarCursorPainter(cursorBg),
                  child: RichText(
                    textScaler: MediaQuery.textScalerOf(context),
                    maxLines: 1,
                    softWrap: false,
                    text: TextSpan(
                      text: run.text,
                      style: _cellTextStyle.merge(
                        _style(
                          run,
                          normalFg,
                          normalBg,
                          cursorBg,
                          cursorFg,
                          running,
                          palette,
                          cursorStyle,
                        ),
                      ),
                    ),
                  ),
                ),
              )
            else
              TextSpan(
                text: run.text,
                style: _style(
                  run,
                  normalFg,
                  normalBg,
                  cursorBg,
                  cursorFg,
                  running,
                  palette,
                  cursorStyle,
                ),
              ),
        ],
      ),
    );
  }

  static TextStyle _style(
    TerminalScreenRun run,
    Color normalFg,
    Color normalBg,
    Color cursorBg,
    Color cursorFg,
    bool running,
    Map<int, Color> palette,
    String cursorStyle,
  ) {
    var fg = terminalColor(run.fg, palette: palette) ?? normalFg;
    var bg = terminalColor(run.bg, palette: palette) ?? normalBg;
    if (run.inverse) (fg, bg) = (bg, fg);
    if (run.cursor && running && cursorStyle == 'block') {
      (fg, bg) = (cursorFg, cursorBg);
    }
    if (run.invisible) fg = bg;
    if (run.dim) fg = fg.withValues(alpha: 0.6);
    return TextStyle(
      color: fg,
      backgroundColor: bg,
      fontWeight: run.bold ? FontWeight.w700 : FontWeight.w400,
      decoration:
          run.underline || (run.cursor && running && cursorStyle == 'underline')
          ? TextDecoration.underline
          : null,
      decorationColor: run.cursor && running && cursorStyle == 'underline'
          ? cursorBg
          : null,
      decorationThickness: run.cursor && running && cursorStyle == 'underline'
          ? 2
          : null,
    );
  }
}

/// Paint inside the existing cell box so a bar cursor cannot shift columns.
class _TerminalBarCursorPainter extends CustomPainter {
  const _TerminalBarCursorPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2;
    canvas.drawLine(Offset(1, 0), Offset(1, size.height), paint);
  }

  @override
  bool shouldRepaint(_TerminalBarCursorPainter oldDelegate) =>
      oldDelegate.color != color;
}
