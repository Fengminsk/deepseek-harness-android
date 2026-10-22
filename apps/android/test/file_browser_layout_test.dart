import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_android/file_browser_chrome.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const capture = bool.fromEnvironment('FILE_BROWSER_CAPTURE');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final brightness in Brightness.values) {
    for (final width in [360.0, 390.0]) {
      testWidgets('floating file browser fits ${brightness.name} at $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        if (capture) {
          await tester.runAsync(() async {
            final font = FontLoader('ScreenshotFont');
            font.addFont(
              File(r'C:\Windows\Fonts\msyh.ttc')
                  .readAsBytes()
                  .then(ByteData.sublistView),
            );
            await font.load();
            final icons = FontLoader('MaterialIcons');
            icons.addFont(
              File(
                '../../.cache/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes().then(ByteData.sublistView),
            );
            await icons.load();
          });
        }
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final paintKey = GlobalKey();
        var theme = pocketTheme(brightness);
        if (capture) {
          theme = theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'ScreenshotFont'),
          );
        }
        await tester.pumpWidget(
          RepaintBoundary(
            key: paintKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme,
              builder: (_, child) => MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 844),
                  padding: const EdgeInsets.only(top: 28, bottom: 24),
                  disableAnimations: true,
                ),
                child: LiquidGlassScope(
                  enabled: true,
                  child: LiquidGlassHost(enabled: true, child: child!),
                ),
              ),
              home: FileBrowserChrome(
                title: '项目资料',
                count: '共 5 项',
                controller: scroll,
                breadcrumbs: [
                  FileBreadcrumb('我的文件', () {}),
                  const FileBreadcrumb('项目资料', null),
                ],
                onBack: () {},
                onAdd: (_) {},
                onMore: (_) {},
                onSearch: () {},
                children: [
                  FileBrowserEntry(
                    name: '参考资料',
                    detail: '',
                    directory: true,
                    onTap: () {},
                  ),
                  FileBrowserEntry(
                    name: '方案说明.pdf',
                    detail: '4.8 MB',
                    directory: false,
                    onTap: () {},
                  ),
                  FileBrowserEntry(
                    name: '界面草图.png',
                    detail: '3.1 MB',
                    directory: false,
                    onTap: () {},
                  ),
                  FileBrowserEntry(
                    name: '任务清单.xlsx',
                    detail: '48 KB',
                    directory: false,
                    onTap: () {},
                  ),
                  FileBrowserEntry(
                    name: '会议记录.md',
                    detail: '6.2 KB',
                    directory: false,
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final controls = find.byType(GlassButton);
        expect(controls, findsNWidgets(4));
        for (final control in controls.evaluate()) {
          final size = tester.getSize(
            find.byElementPredicate(
              (candidate) => identical(candidate, control),
            ),
          );
          expect(size.width, size.height);
        }
        final listBounds = tester.getRect(
          find.byKey(const Key('file-browser-list')),
        );
        final titleBounds = tester.getRect(find.text('项目资料').first);
        expect(listBounds.top, lessThan(titleBounds.top));
        expect(titleBounds.width, greaterThan(64));
        expect(titleBounds.height, greaterThan(20));
        expect(find.text('项目资料').first.hitTestable(), findsOneWidget);
        final countBounds = tester.getRect(find.text('共 5 项'));
        expect(countBounds.width, greaterThan(20));
        expect(countBounds.height, greaterThan(10));
        expect(countBounds.top, greaterThan(titleBounds.top));
        expect(tester.getRect(find.text('我的文件')).left, 18);
        if (capture) {
          await tester.runAsync(() async {
            final boundary =
                paintKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final picture = await boundary.toImage(pixelRatio: 2);
            try {
              final png = await picture.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final target = File(
                '../../.cache/android/file-browser-${brightness.name}-${width.toInt()}.png',
              );
              await target.parent.create(recursive: true);
              await target.writeAsBytes(png!.buffer.asUint8List());
            } finally {
              picture.dispose();
            }
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
