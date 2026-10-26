import 'dart:async';

import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_terminal.dart';
import 'package:dsh_android/terminal_screen.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

Json terminalView() => {
  'cols': 8,
  'rows': 2,
  'start': 0,
  'cursor': {'col': 3, 'row': 0},
  'lines': [
    {
      'wrapped': false,
      'runs': [
        {
          'text': 'red',
          'fg': 1,
          'bg': null,
          'bold': true,
          'dim': false,
          'inverse': false,
          'underline': false,
          'invisible': false,
          'cursor': false,
        },
        {
          'text': ' ',
          'fg': null,
          'bg': null,
          'bold': false,
          'dim': false,
          'inverse': false,
          'underline': false,
          'invisible': false,
          'cursor': true,
        },
      ],
    },
    {'wrapped': false, 'runs': <Json>[]},
  ],
};

class _TerminalRuntime extends RuntimeController {
  final writes = <String>[];
  final resizes = <({int cols, int rows})>[];
  final renames = <String>[];
  final createdShellIds = <String>[];
  List<Json> shellOptions = [
    {'id': 'system-sh', 'label': '系统 Shell'},
    {'id': 'system-mksh', 'label': 'mksh'},
  ];
  bool failShellDiscovery = false;
  String terminalName = '终端';
  int cols = 8, rows = 2, revision = 1;
  bool failWrites = false;
  bool failHeldWrite = false;
  bool failReadAfterWrite = false;
  bool advanceRevisionOnRead = false;
  bool appCursorKeys = false;
  bool bracketedPaste = false;
  String mouseTracking = 'off';
  bool sgrMouse = false;
  Completer<void>? holdFirstWrite;
  int testConnection = 0;

  @override
  int get connectionGeneration => testConnection;

  void reconnect() {
    testConnection++;
    notifyListeners();
  }

  _TerminalRuntime() {
    phase = 'ready';
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'terminal.shells') {
      if (failShellDiscovery) throw StateError('Shell discovery failed');
      return shellOptions;
    }
    if (method == 'terminal.create') {
      createdShellIds.add(params['shellId'] as String);
      return {'state': 'running'};
    }
    if (method == 'terminal.list') {
      return [
        {
          'id': 'terminal-1',
          'name': terminalName,
          'cwd': '/workspace',
          'state': 'running',
        },
      ];
    }
    if (method == 'terminal.rename') {
      terminalName = params['name'] as String;
      renames.add(terminalName);
      revision++;
      return {'name': terminalName};
    }
    if (method == 'terminal.read') {
      if (failReadAfterWrite && writes.isNotEmpty) {
        throw StateError('Read unavailable');
      }
      if (advanceRevisionOnRead) revision++;
      final view = terminalView();
      view['cols'] = cols;
      view['rows'] = rows;
      view['applicationCursorKeys'] = appCursorKeys;
      view['bracketedPaste'] = bracketedPaste;
      view['mouseTracking'] = mouseTracking;
      view['sgrMouse'] = sgrMouse;
      return {
        'name': terminalName,
        'state': 'running',
        'revision': revision,
        'display': '\u001b[31mred\u001b[0m',
        'view': view,
      };
    }
    if (method == 'terminal.write') {
      if (failWrites) throw StateError('Acknowledgement unavailable');
      writes.add(params['data'] as String);
      final hold = holdFirstWrite;
      holdFirstWrite = null;
      if (hold != null) await hold.future;
      if (hold != null && failHeldWrite) {
        throw StateError('Acknowledgement unavailable');
      }
      return {'accepted': true};
    }
    if (method == 'terminal.resize') {
      cols = params['cols'] as int;
      rows = params['rows'] as int;
      resizes.add((cols: cols, rows: rows));
      revision++;
      return {'cols': cols, 'rows': rows};
    }
    if (method == 'terminal.close') return {'closed': true};
    throw StateError('Unexpected $method');
  }
}

void main() {
  testWidgets(
    'shell picker discovers without spawning and persists the selected installed shell',
    (tester) async {
      final runtime = _TerminalRuntime();
      final saved = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async {
          if (call.method == 'terminal.shell.load') return 'system-sh';
          if (call.method == 'terminal.shell.save') {
            saved.add(call.arguments as String);
            return null;
          }
          throw StateError('Unexpected ${call.method}');
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTerminalsPage(runtime: runtime, sessionId: 'session-A'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('选择 Shell'));
      await tester.pumpAndSettle();
      expect(find.text('mksh'), findsOneWidget);
      expect(runtime.createdShellIds, isEmpty);
      await tester.tap(find.text('mksh'));
      await tester.pumpAndSettle();
      expect(saved, ['system-mksh']);
      expect(runtime.createdShellIds, ['system-mksh']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed or malformed shell discovery can retry without allocating a PTY',
    (tester) async {
      final runtime = _TerminalRuntime()..failShellDiscovery = true;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        RuntimeController.channel,
        (call) async => 'system-sh',
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          RuntimeController.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTerminalsPage(runtime: runtime, sessionId: 'session-A'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('选择 Shell'));
      await tester.pumpAndSettle();
      expect(find.text('无法读取已安装的 Shell。'), findsOneWidget);
      expect(runtime.createdShellIds, isEmpty);
      runtime
        ..failShellDiscovery = false
        ..shellOptions = [
          {'id': '/data/local/tmp/bash', 'label': 'Bash'},
        ];
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('无法读取已安装的 Shell。'), findsOneWidget);
      runtime.shellOptions = [
        {'id': 'system-sh', 'label': '系统 Shell'},
      ];
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('系统 Shell'), findsOneWidget);
      expect(runtime.createdShellIds, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'terminal name is edited on a separate page and refreshes the list',
    (tester) async {
      final runtime = _TerminalRuntime();
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTerminalsPage(runtime: runtime, sessionId: 'session-A'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('终端'), findsWidgets);
      await tester.tap(find.byTooltip('重命名终端'));
      await tester.pumpAndSettle();
      expect(find.text('终端名称'), findsWidgets);
      await tester.enterText(find.byType(TextField).first, '   ');
      await tester.tap(find.byTooltip('保存名称'));
      await tester.pumpAndSettle();
      expect(find.text('请输入不超过 64 个字符的名称。'), findsOneWidget);
      expect(runtime.renames, isEmpty);
      await tester.enterText(find.byType(TextField).first, '构建任务');
      await tester.tap(find.byTooltip('保存名称'));
      await tester.pumpAndSettle();
      expect(runtime.renames, ['构建任务']);
      expect(find.text('构建任务'), findsOneWidget);
      await tester.tap(find.byTooltip('重命名终端'));
      await tester.pumpAndSettle();
      final family = '👨‍👩‍👧‍👦' * 64;
      await tester.enterText(find.byType(TextField).first, family);
      await tester.tap(find.byTooltip('保存名称'));
      await tester.pumpAndSettle();
      expect(runtime.renames.last, family);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'terminal fit uses the actual viewport and stays within host limits',
    () {
      expect(
        fitTerminalViewport(
          width: 320,
          height: 640,
          cellWidth: 8,
          lineHeight: 18,
          reservedHeight: 250,
        ),
        (cols: 35, rows: 21),
      );
      expect(
        fitTerminalViewport(
          width: 1,
          height: 1,
          cellWidth: 8,
          lineHeight: 18,
          reservedHeight: 250,
        ),
        (cols: 2, rows: 1),
      );
      expect(
        () => fitTerminalViewport(
          width: double.infinity,
          height: 640,
          cellWidth: 8,
          lineHeight: 18,
          reservedHeight: 250,
        ),
        throwsArgumentError,
      );
    },
  );

  test('view decoder rejects malformed color and unbounded content', () {
    final malformed = terminalView();
    ((malformed['lines'] as List).first['runs'] as List).first['fg'] =
        '#zzzzzz';
    expect(() => TerminalScreenData.parse(malformed), throwsFormatException);
    final oversized = terminalView();
    ((oversized['lines'] as List).first['runs'] as List).first['text'] =
        'x' * 200001;
    expect(() => TerminalScreenData.parse(oversized), throwsFormatException);
  });

  test('view decoder keeps bounded OSC palette and cursor state', () {
    final source = terminalView();
    source['palette'] = {
      'indexed': {'1': '#123456'},
      'foreground': '#eeeeee',
      'background': '#101010',
      'cursor': '#abcdef',
    };
    source['cursorVisible'] = false;
    source['cursorStyle'] = 'underline';
    source['cursorBlink'] = false;
    final view = TerminalScreenData.parse(source);
    expect(view.palette[1], const Color(0xff123456));
    expect(view.foreground, const Color(0xffeeeeee));
    expect(view.background, const Color(0xff101010));
    expect(view.cursorColor, const Color(0xffabcdef));
    expect(view.cursorVisible, false);
    expect(view.cursorStyle, 'underline');
    expect(view.cursorBlink, false);
    expect(terminalColor(1, palette: view.palette), const Color(0xff123456));
    source['cursorStyle'] = 'circle';
    expect(() => TerminalScreenData.parse(source), throwsFormatException);
    source['cursorStyle'] = 'bar';
    source['applicationCursorKeys'] = 'yes';
    expect(() => TerminalScreenData.parse(source), throwsFormatException);
    source['applicationCursorKeys'] = true;
    expect(TerminalScreenData.parse(source).applicationCursorKeys, true);
    source['bracketedPaste'] = 'yes';
    expect(() => TerminalScreenData.parse(source), throwsFormatException);
    source['bracketedPaste'] = true;
    expect(TerminalScreenData.parse(source).bracketedPaste, true);
    source['mouseTracking'] = 'drag';
    source['sgrMouse'] = true;
    expect(TerminalScreenData.parse(source).mouseTracking, 'drag');
    expect(TerminalScreenData.parse(source).sgrMouse, true);
    source['mouseTracking'] = 'legacy';
    expect(() => TerminalScreenData.parse(source), throwsFormatException);
    source['mouseTracking'] = 'drag';
    source['sgrMouse'] = 'yes';
    expect(() => TerminalScreenData.parse(source), throwsFormatException);
    source['sgrMouse'] = true;
    (source['palette'] as Map)['indexed'] = {'256': '#123456'};
    expect(() => TerminalScreenData.parse(source), throwsFormatException);
  });

  test('SGR mouse reports require tracked mode and valid grid coordinates', () {
    String? encode(String action, {String tracking = 'drag', bool sgr = true,
      int button = 0, int col = 4, int row = 2}) => terminalSgrMouseInput(
        tracking: tracking, sgrMouse: sgr, action: action, button: button,
        col: col, row: row, cols: 8, rows: 3);
    expect(encode('down'), '\u001b[<0;4;2M');
    expect(encode('up'), '\u001b[<0;4;2m');
    expect(encode('move'), '\u001b[<32;4;2M');
    expect(encode('move', tracking: 'any', button: 3), '\u001b[<35;4;2M');
    expect(encode('wheelUp'), '\u001b[<64;4;2M');
    expect(encode('wheelDown'), '\u001b[<65;4;2M');
    expect(encode('move', tracking: 'click'), isNull);
    expect(encode('down', sgr: false), isNull);
    expect(encode('down', tracking: 'off'), isNull);
    expect(encode('down', col: 9), isNull);
    expect(encode('down', row: 0), isNull);
  });

  testWidgets('styled cell and cursor use independent colors', (tester) async {
    final view = TerminalScreenData.parse(terminalView());
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: Scaffold(
          body: TerminalScreenLine(
            key: const ValueKey('terminal-row'),
            line: view.lines.first,
            running: true,
          ),
        ),
      ),
    );
    final rich = tester.widget<RichText>(
      find
          .descendant(
            of: find.byKey(const ValueKey('terminal-row')),
            matching: find.byType(RichText),
          )
          .first,
    );
    final spans = (rich.text as TextSpan).children!.cast<TextSpan>();
    expect(spans.first.text, 'red');
    expect(spans.first.style!.color, terminalColor(1));
    expect(spans.first.style!.fontWeight, FontWeight.w700);
    expect(
      spans.last.style!.backgroundColor,
      Theme.of(tester.element(find.byType(TerminalScreenLine)))
          .colorScheme
          .onSurface,
    );
  });

  testWidgets('underline and bar cursor preserve program colors', (
    tester,
  ) async {
    final view = TerminalScreenData.parse(terminalView());
    Future<void> render(String style) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: Scaffold(
            body: TerminalScreenLine(
              key: const ValueKey('terminal-row'),
              line: view.lines.first,
              running: true,
              palette: const {1: Color(0xff123456)},
              cursorColor: const Color(0xffabcdef),
              cursorStyle: style,
            ),
          ),
        ),
      );
    }

    await render('underline');
    var rich = tester.widget<RichText>(
      find
          .descendant(
            of: find.byKey(const ValueKey('terminal-row')),
            matching: find.byType(RichText),
          )
          .first,
    );
    var spans = (rich.text as TextSpan).children!.cast<TextSpan>();
    expect(spans.first.style!.color, const Color(0xff123456));
    expect(spans.last.style!.decoration, TextDecoration.underline);
    expect(spans.last.style!.decorationColor, const Color(0xffabcdef));
    await render('bar');
    rich = tester.widget<RichText>(
      find
          .descendant(
            of: find.byKey(const ValueKey('terminal-row')),
            matching: find.byType(RichText),
          )
          .first,
    );
    expect((rich.text as TextSpan).children!.last, isA<WidgetSpan>());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'bar cursor overlays the same monospace cell without changing row metrics',
    (tester) async {
      final line = TerminalScreenData.parse(terminalView()).lines.first;
      Future<Size> render(String style) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: pocketTheme(Brightness.dark),
            home: Scaffold(
              body: UnconstrainedBox(
                alignment: Alignment.topLeft,
                child: TerminalScreenLine(
                  key: const ValueKey('terminal-row'),
                  line: line,
                  running: true,
                  cursorStyle: style,
                ),
              ),
            ),
          ),
        );
        return tester.getSize(find.byKey(const ValueKey('terminal-row')));
      }

      final block = await render('block');
      final bar = await render('bar');
      expect(bar.width, closeTo(block.width, 0.01));
      expect(bar.height, closeTo(block.height, 0.01));
      final label = tester.widget<RichText>(
        find
            .descendant(
              of: find.byKey(const ValueKey('terminal-row')),
              matching: find.byType(RichText),
            )
            .last,
      );
      final style = (label.text as TextSpan).style!;
      expect(style.fontFamily, 'monospace');
      expect(style.fontSize, 13);
      expect(style.height, 1.35);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('continuous output does not restart the cursor blink phase', (
    tester,
  ) async {
    final runtime = _TerminalRuntime()..advanceRevisionOnRead = true;
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: SessionTerminalView(
          runtime: runtime,
          sessionId: 'session',
          id: 'pty',
        ),
      ),
    );
    await tester.pump();
    bool cursorPainted() => tester
        .widget<TerminalScreenLine>(find.byType(TerminalScreenLine).first)
        .running;
    expect(cursorPainted(), true);
    await tester.pump(const Duration(milliseconds: 530));
    expect(cursorPainted(), false);
    await tester.pump(const Duration(milliseconds: 400));
    expect(runtime.revision, greaterThan(2));
    expect(cursorPainted(), false);
    await tester.pump(const Duration(milliseconds: 130));
    expect(cursorPainted(), true);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'terminal page renders interpreted cells instead of raw escapes',
    (tester) async {
      Object? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') copied = call.arguments;
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      final runtime = _TerminalRuntime();
      addTearDown(runtime.dispose);
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTerminalView(
            runtime: runtime,
            sessionId: 'session',
            id: 'pty',
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(TerminalScreenLine), findsWidgets);
      final rendered = tester.widget<RichText>(
        find.descendant(
          of: find.byType(TerminalScreenLine).first,
          matching: find.byType(RichText),
        ),
      );
      expect(rendered.text.toPlainText(), 'red ');
      expect(find.textContaining('\u001b'), findsNothing);
      await tester.tap(find.byTooltip('复制终端内容'));
      expect(copied, {'text': 'red \n'});
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'terminal sends raw control keys and keeps drafts on uncertain write',
    (tester) async {
      final runtime = _TerminalRuntime();
      addTearDown(runtime.dispose);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTerminalView(
            runtime: runtime,
            sessionId: 'session',
            id: 'pty',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(runtime.resizes, isNotEmpty);
      expect(runtime.resizes.last.cols, inInclusiveRange(2, 40));
      expect(tester.takeException(), isNull);
      final narrowColumns = runtime.resizes.last.cols;
      tester.view.physicalSize = const Size(480, 640);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(runtime.resizes.last.cols, greaterThan(narrowColumns));

      await tester.tap(find.text('实时输入'));
      await tester.pump();
      expect(find.text('草稿输入'), findsOneWidget);
      await tester.tap(find.text('Esc'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(runtime.writes.last, '\u001b');
      await tester.enterText(find.byType(TextField), 'printf hello');
      await tester.pump();
      await tester.tap(find.byTooltip('仅发送输入，不按回车'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(runtime.writes.last, 'printf hello');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );

      await tester.enterText(find.byType(TextField), 'whoami');
      runtime.failWrites = true;
      await tester.tap(find.byTooltip('发送命令'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'whoami',
      );
      expect(find.textContaining('输入送达状态未知'), findsOneWidget);
      runtime.failWrites = false;
      await tester.tap(find.byTooltip('发送命令'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(runtime.writes.last, 'whoami\r');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
      final sentCount = runtime.writes.length;
      await tester.enterText(find.byType(TextField), '界' * 21846);
      await tester.tap(find.byTooltip('发送命令'));
      await tester.pump();
      expect(runtime.writes.length, sentCount);
      expect(find.textContaining('不能超过 64 KiB'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'PTY control keys keep order and input focus during a pending write',
    (tester) async {
      final runtime = _TerminalRuntime();
      addTearDown(runtime.dispose);
      final hold = Completer<void>();
      runtime.holdFirstWrite = hold;
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTerminalView(
            runtime: runtime,
            sessionId: 'session',
            id: 'pty',
          ),
        ),
      );
      await tester.pump();
      final field = find.byType(TextField);
      await tester.tap(field);
      await tester.pump();
      final focus = tester.widget<TextField>(field).focusNode!;
      expect(focus.hasFocus, true);
      await tester.tap(find.text('↑'));
      await tester.tap(find.text('↓'));
      await tester.tap(find.text('←'));
      await tester.pump();
      expect(runtime.writes, ['\u001b[A']);
      expect(tester.widget<TextField>(field).enabled, true);
      expect(focus.hasFocus, true);
      hold.complete();
      await tester.pump();
      await tester.pump();
      expect(runtime.writes, ['\u001b[A', '\u001b[B', '\u001b[D']);
      expect(focus.hasFocus, true);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'live IME commits only completed text and sends return after pending text',
    (tester) async {
      final runtime = _TerminalRuntime();
      addTearDown(runtime.dispose);
      final held = Completer<void>();
      runtime.holdFirstWrite = held;
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTerminalView(
            runtime: runtime,
            sessionId: 'session',
            id: 'pty',
          ),
        ),
      );
      await tester.pump();
      final field = find.byType(TextField);
      final controller = tester.widget<TextField>(field).controller!;
      expect(find.text('实时输入'), findsOneWidget);
      controller.value = const TextEditingValue(
        text: '中',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      );
      await tester.pump();
      expect(runtime.writes, isEmpty);
      controller.value = const TextEditingValue(
        text: '中文',
        selection: TextSelection.collapsed(offset: 2),
      );
      await tester.pump();
      expect(runtime.writes, ['中文']);
      await tester.enterText(field, '中文后续');
      await tester.tap(find.byTooltip('发送回车'));
      await tester.pump();
      expect(runtime.writes, ['中文']);
      await tester.ensureVisible(find.text('Ctrl-C'));
      await tester.pump();
      await tester.tap(find.text('Ctrl-C'));
      await tester.pump();
      expect(runtime.writes, ['中文']);
      expect(find.textContaining('请等当前输入送达'), findsOneWidget);
      held.complete();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(runtime.writes, ['中文', '后续', '\r']);
      expect(controller.text, '');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('uncertain live input stays visible without automatic replay', (
    tester,
  ) async {
    final runtime = _TerminalRuntime()..failWrites = true;
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: SessionTerminalView(
          runtime: runtime,
          sessionId: 'session',
          id: 'pty',
        ),
      ),
    );
    await tester.pump();
    final field = find.byType(TextField);
    await tester.enterText(field, 'x');
    await tester.pump();
    expect(runtime.writes, isEmpty);
    expect(find.textContaining('输入送达状态未知'), findsOneWidget);
    runtime.failWrites = false;
    await tester.enterText(field, 'xy');
    await tester.pump();
    expect(runtime.writes, isEmpty);
    expect(tester.widget<TextField>(field).controller!.text, 'xy');
    await tester.tap(find.byTooltip('发送回车'));
    await tester.pump();
    expect(runtime.writes, ['xy\r']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('hardware arrows use the active application cursor mode', (
    tester,
  ) async {
    final runtime = _TerminalRuntime()..appCursorKeys = true;
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: SessionTerminalView(
          runtime: runtime,
          sessionId: 'session',
          id: 'pty',
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(runtime.writes.last, '\u001bOA');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('on-screen arrows follow application cursor mode', (
    tester,
  ) async {
    final runtime = _TerminalRuntime()..appCursorKeys = true;
    addTearDown(runtime.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: SessionTerminalView(
          runtime: runtime,
          sessionId: 'session',
          id: 'pty',
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('↑'));
    await tester.pump();
    expect(runtime.writes.last, '\u001bOA');
    runtime.appCursorKeys = false;
    runtime.revision++;
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('↑'));
    await tester.pump();
    expect(runtime.writes.last, '\u001b[A');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'draft input brackets paste and places Return after the delimiter',
    (tester) async {
      final runtime = _TerminalRuntime()..bracketedPaste = true;
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTerminalView(
            runtime: runtime,
            sessionId: 'session',
            id: 'pty',
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('实时输入'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'echo ok');
      await tester.tap(find.byTooltip('发送命令'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(runtime.writes.last, '\u001b[200~echo ok\u001b[201~\r');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), 'draft');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'draft',
      );
      expect(
        tester
            .widget<GlassButton>(
              find.ancestor(
                of: find.byTooltip('仅发送输入，不按回车'),
                matching: find.byType(GlassButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byTooltip('仅发送输入，不按回车'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(runtime.writes.last, '\u001b[200~draft\u001b[201~');
      runtime.bracketedPaste = false;
      runtime.revision++;
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), 'plain');
      await tester.pump();
      await tester.tap(find.byTooltip('发送命令'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(runtime.writes.last, 'plain\r');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('hardware mouse reports use the current Session PTY write path', (
    tester,
  ) async {
    final runtime = _TerminalRuntime()
      ..mouseTracking = 'drag'
      ..sgrMouse = true;
    addTearDown(runtime.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: pocketTheme(Brightness.dark),
      home: SessionTerminalView(runtime: runtime, sessionId: 'session', id: 'pty'),
    ));
    await tester.pump();
    final row = find.byKey(const ValueKey('terminal-line-0'));
    expect(row, findsOneWidget);
    await tester.ensureVisible(row);
    await tester.pump();
    expect(row.hitTestable(), findsOneWidget);
    final point = tester.getTopLeft(row) +
        Offset(50, tester.getSize(row).height / 2);
    final mouse = await tester.startGesture(point, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await mouse.moveBy(const Offset(9, 0));
    await tester.pump();
    await mouse.up();
    await tester.pump();
    expect(runtime.writes.first, matches(RegExp(r'^\x1b\[<0;[1-8];1M$')));
    expect(runtime.writes.last, matches(RegExp(r'^\x1b\[<0;[1-8];1m$')));
    expect(runtime.writes, contains(matches(RegExp(r'^\x1b\[<32;[1-8];1M$'))));
    final count = runtime.writes.length;
    final touch = await tester.startGesture(point, kind: PointerDeviceKind.touch);
    await touch.up();
    await tester.pump();
    expect(runtime.writes.length, count);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'hardware PTY keys preserve bytes without consuming IME composition',
    (tester) async {
      final runtime = _TerminalRuntime();
      addTearDown(runtime.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTerminalView(
            runtime: runtime,
            sessionId: 'session',
            id: 'pty',
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('实时输入'));
      await tester.pump();
      final field = find.byType(TextField);
      await tester.tap(field);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(runtime.writes, ['\u0003']);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(runtime.writes.last, '\u001b[A');
      final controller = tester.widget<TextField>(field).controller!;
      controller.value = const TextEditingValue(
        text: '中',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      );
      await tester.pump();
      final before = runtime.writes.length;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(runtime.writes.length, before);
      expect(controller.text, '中');
      await tester.tap(find.byTooltip('发送命令'));
      await tester.pump();
      expect(runtime.writes.length, before);
      expect(find.textContaining('请先确认正在输入的文字'), findsOneWidget);
      controller.value = const TextEditingValue(
        text: '中文',
        selection: TextSelection.collapsed(offset: 2),
      );
      await tester.tap(find.byTooltip('发送命令'));
      await tester.pump();
      expect(runtime.writes.last, '中文\r');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'acknowledged input leaves the next draft and uncertain writes stop queued keys',
    (tester) async {
      final runtime = _TerminalRuntime();
      addTearDown(runtime.dispose);
      final hold = Completer<void>();
      runtime.holdFirstWrite = hold;
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTerminalView(
            runtime: runtime,
            sessionId: 'session',
            id: 'pty',
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('实时输入'));
      await tester.pump();
      final field = find.byType(TextField);
      await tester.enterText(field, 'pwd');
      await tester.tap(find.byTooltip('发送命令'));
      await tester.pump();
      expect(runtime.writes, ['pwd\r']);
      await tester.enterText(field, 'pwd下一条');
      await tester.pump();
      expect(tester.widget<TextField>(field).enabled, true);
      hold.complete();
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '下一条');
      await tester.pumpWidget(const SizedBox.shrink());

      final failure = _TerminalRuntime()..failHeldWrite = true;
      addTearDown(failure.dispose);
      final failedHold = Completer<void>();
      failure.holdFirstWrite = failedHold;
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTerminalView(
            runtime: failure,
            sessionId: 'session',
            id: 'pty',
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('↑'));
      await tester.tap(find.text('↓'));
      failedHold.complete();
      await tester.pump();
      expect(failure.writes, ['\u001b[A']);
      expect(find.textContaining('后续按键未发送'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('failed post-write read discards queued control keys', (
    tester,
  ) async {
    final runtime = _TerminalRuntime()..failReadAfterWrite = true;
    addTearDown(runtime.dispose);
    final hold = Completer<void>();
    runtime.holdFirstWrite = hold;
    await tester.pumpWidget(
      MaterialApp(
        theme: pocketTheme(Brightness.dark),
        home: SessionTerminalView(
          runtime: runtime,
          sessionId: 'session',
          id: 'pty',
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('↑'));
    await tester.tap(find.text('↓'));
    expect(runtime.writes, ['\u001b[A']);
    hold.complete();
    await tester.pump();
    expect(find.textContaining('排队按键未发送'), findsOneWidget);
    runtime.failReadAfterWrite = false;
    runtime.notifyListeners();
    await tester.pump();
    await tester.tap(find.text('←'));
    await tester.pump();
    expect(runtime.writes, ['\u001b[A', '\u001b[D']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'an old write acknowledgement cannot clear a new connection input',
    (tester) async {
      final runtime = _TerminalRuntime();
      addTearDown(runtime.dispose);
      final oldWrite = Completer<void>();
      runtime.holdFirstWrite = oldWrite;
      await tester.pumpWidget(
        MaterialApp(
          theme: pocketTheme(Brightness.dark),
          home: SessionTerminalView(
            runtime: runtime,
            sessionId: 'session',
            id: 'pty',
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('↑'));
      expect(runtime.writes, ['\u001b[A']);
      runtime.reconnect();
      await tester.pump();
      await tester.tap(find.text('↓'));
      await tester.pump();
      expect(runtime.writes, ['\u001b[A', '\u001b[B']);
      oldWrite.complete();
      await tester.pump();
      await tester.tap(find.text('←'));
      await tester.pump();
      expect(runtime.writes, ['\u001b[A', '\u001b[B', '\u001b[D']);
      expect(find.textContaining('送达状态未知'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
