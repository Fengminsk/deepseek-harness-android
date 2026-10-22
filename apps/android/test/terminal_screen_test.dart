import 'package:dsh_android/runtime.dart';
import 'package:dsh_android/session_terminal.dart';
import 'package:dsh_android/terminal_screen.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
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
  int cols = 8, rows = 2, revision = 1;
  bool failWrites = false;

  _TerminalRuntime() {
    phase = 'ready';
  }

  @override
  Future<dynamic> call(String method, [Json params = const {}]) async {
    if (method == 'terminal.read') {
      final view = terminalView();
      view['cols'] = cols;
      view['rows'] = rows;
      return {
        'state': 'running',
        'revision': revision,
        'display': '\u001b[31mred\u001b[0m',
        'view': view,
      };
    }
    if (method == 'terminal.write') {
      if (failWrites) throw StateError('Acknowledgement unavailable');
      writes.add(params['data'] as String);
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
      find.descendant(
        of: find.byKey(const ValueKey('terminal-row')),
        matching: find.byType(RichText),
      ),
    );
    final spans = (rich.text as TextSpan).children!.cast<TextSpan>();
    expect(spans.first.text, 'red');
    expect(spans.first.style!.color, terminalColor(1));
    expect(spans.first.style!.fontWeight, FontWeight.w700);
    expect(
      spans.last.style!.backgroundColor,
      Theme.of(tester.element(find.byType(TerminalScreenLine)))
          .colorScheme
          .primary,
    );
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
}
