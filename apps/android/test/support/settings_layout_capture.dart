import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Optional local artifacts; normal tests never write screenshots.
class SettingsLayoutCapture {
  final key = GlobalKey();

  Widget wrap(BuildContext context, Widget? child, {double scale = 1}) =>
      MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: key, child: child!),
      );

  Future<void> save(WidgetTester tester, String name) async {
    final directory = Platform.environment['POCKET_CAPTURE_DIR'];
    if (directory == null) return;
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      try {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File('$directory/$name.png')
            .writeAsBytes(png!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }
}

Future<void> loadSettingsCaptureFonts() async {
  final path = Platform.environment['POCKET_CAPTURE_FONT'];
  if (path == null) return;
  await (FontLoader('Roboto')..addFont(
        Future.value(ByteData.sublistView(await File(path).readAsBytes())),
      ))
      .load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}
