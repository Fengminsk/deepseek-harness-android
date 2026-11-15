// 电脑文件页：目录排序、进入子目录、文本分段读取、错误与能力门控。
//
// 这里不连宿主、不拨号：页面只认 `RemoteDshFilesSource`，数据源替身来自
// `support/remote_home_fakes.dart`，因此列表、分页、错误与门控都能在没有 PC 的
// 情况下验证；真实的 `workspace.files.*` 接线由数据源解析测试与真机验收覆盖。

import 'package:dsh_android/file_browser_chrome.dart';
import 'package:dsh_android/remote_dsh_live_source.dart';
import 'package:dsh_android/remote_workspace_files_page.dart';
import 'package:dsh_android/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/remote_home_fakes.dart';

/// 挂载电脑文件页并等首次读取完成。
Future<void> _show(WidgetTester tester, FakeRemoteFilesSource source) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: pocketTheme(Brightness.light),
      home: RemoteWorkspaceFilesPage(source: source),
    ),
  );
  await tester.pumpAndSettle();
}

/// 当前屏上的文件条目名，按渲染顺序。
List<String> _entryNames(WidgetTester tester) => <String>[
  for (final entry in tester.widgetList<FileBrowserEntry>(
    find.byType(FileBrowserEntry),
  ))
    entry.name,
];

void main() {
  group('文件列表', () {
    testWidgets('目录排在文件前面，并显示已读数量', (tester) async {
      final source = FakeRemoteFilesSource(
        directories: <String, List<RemoteDshDirectoryPage>>{
          '': <RemoteDshDirectoryPage>[
            fakeDirectoryPage(
              entries: <RemoteDshFileEntry>[
                fakeFileEntry('README.md', bytes: 120),
                fakeFileEntry(
                  'src',
                  kind: RemoteDshFileKind.directory,
                  modifiedAt: 1700000000000,
                ),
                fakeFileEntry('app.log', bytes: 10),
              ],
            ),
          ],
        },
      );
      await _show(tester, source);

      expect(_entryNames(tester), <String>['src', 'README.md', 'app.log']);
      expect(find.text('共 3 项'), findsOneWidget);
      expect(source.directoryCalls, hasLength(1));
      expect(source.directoryCalls.single.path, '');
      expect(source.directoryCalls.single.offset, 0);
      expect(source.directoryCalls.single.version, isNull);
    });

    testWidgets('进入子目录，再用返回按钮回到上级', (tester) async {
      final source = FakeRemoteFilesSource(
        directories: <String, List<RemoteDshDirectoryPage>>{
          '': <RemoteDshDirectoryPage>[
            fakeDirectoryPage(
              entries: <RemoteDshFileEntry>[
                fakeFileEntry('src', kind: RemoteDshFileKind.directory),
              ],
            ),
          ],
          'src': <RemoteDshDirectoryPage>[
            fakeDirectoryPage(
              path: 'src',
              entries: <RemoteDshFileEntry>[fakeFileEntry('main.dart')],
            ),
          ],
        },
      );
      await _show(tester, source);

      await tester.tap(find.byKey(const ValueKey<String>('remote-file:src')));
      await tester.pumpAndSettle();

      expect(find.text('main.dart'), findsOneWidget);
      expect(source.directoryCalls.last.path, 'src');
      expect(find.text('src'), findsWidgets, reason: '标题与面包屑都显示当前目录');

      await tester.tap(find.byTooltip('返回上级'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('remote-file:src')),
        findsOneWidget,
      );
      expect(source.directoryCalls.last.path, '');
    });

    testWidgets('目录按 nextOffset 续读，续页带回目录版本', (tester) async {
      final source = FakeRemoteFilesSource(
        directories: <String, List<RemoteDshDirectoryPage>>{
          '': <RemoteDshDirectoryPage>[
            fakeDirectoryPage(
              entries: <RemoteDshFileEntry>[fakeFileEntry('a.txt')],
              nextOffset: 1,
            ),
            fakeDirectoryPage(
              offset: 1,
              entries: <RemoteDshFileEntry>[
                fakeFileEntry('docs', kind: RemoteDshFileKind.directory),
              ],
            ),
          ],
        },
      );
      await _show(tester, source);
      expect(
        find.byKey(const ValueKey<String>('remote-files-load-more')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('remote-files-load-more')),
      );
      await tester.pumpAndSettle();

      expect(_entryNames(tester), <String>[
        'docs',
        'a.txt',
      ], reason: '续页到达的目录仍排在文件前面');
      expect(source.directoryCalls.last.offset, 1);
      expect(source.directoryCalls.last.version, 'dir-v1');
      expect(
        find.byKey(const ValueKey<String>('remote-files-load-more')),
        findsNothing,
        reason: '读完目录后不再显示加载更多',
      );
    });

    testWidgets('读取失败展示宿主消息，重试成功后恢复列表', (tester) async {
      final source = FakeRemoteFilesSource(
        directories: <String, List<RemoteDshDirectoryPage>>{
          '': <RemoteDshDirectoryPage>[
            fakeDirectoryPage(
              entries: <RemoteDshFileEntry>[fakeFileEntry('ok.txt')],
            ),
          ],
        },
        directoryError: PlatformException(
          code: 'workspace-files/not-found',
          message: '路径已不存在，请刷新上级目录。',
        ),
      );
      await _show(tester, source);

      expect(find.text('路径已不存在，请刷新上级目录。'), findsOneWidget);

      source.directoryError = null;
      await tester.tap(
        find.byKey(const ValueKey<String>('remote-files-retry')),
      );
      await tester.pumpAndSettle();

      expect(find.text('ok.txt'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('remote-files-retry')),
        findsNothing,
      );
    });

    testWidgets('符号链接显示原因且不可点开', (tester) async {
      final source = FakeRemoteFilesSource(
        directories: <String, List<RemoteDshDirectoryPage>>{
          '': <RemoteDshDirectoryPage>[
            fakeDirectoryPage(
              entries: <RemoteDshFileEntry>[
                fakeFileEntry(
                  'shortcut',
                  kind: RemoteDshFileKind.link,
                  blockedReason: 'symlink',
                ),
              ],
            ),
          ],
        },
      );
      await _show(tester, source);

      expect(find.text('符号链接，不在此入口的读取范围内'), findsOneWidget);
      final entry = tester.widget<FileBrowserEntry>(
        find.byKey(const ValueKey<String>('remote-file:shortcut')),
      );
      expect(entry.onTap, isNull, reason: '不可打开的项目不能是能点但没用的入口');
    });
  });

  group('文本文件查看器', () {
    testWidgets('打开文本文件并按 nextOffset 分段加载', (tester) async {
      final source = FakeRemoteFilesSource(
        directories: <String, List<RemoteDshDirectoryPage>>{
          '': <RemoteDshDirectoryPage>[
            fakeDirectoryPage(
              entries: <RemoteDshFileEntry>[
                fakeFileEntry('notes.txt', bytes: 8),
              ],
            ),
          ],
        },
        files: <String, List<RemoteDshFilePage>>{
          'notes.txt': <RemoteDshFilePage>[
            fakeFilePage(
              path: 'notes.txt',
              text: '第一段',
              offset: 0,
              bytes: 8,
              eof: false,
              nextOffset: 5,
            ),
            fakeFilePage(
              path: 'notes.txt',
              text: '第二段',
              offset: 5,
              bytes: 8,
              eof: true,
              nextOffset: 8,
            ),
          ],
        },
      );
      await _show(tester, source);

      await tester.tap(
        find.byKey(const ValueKey<String>('remote-file:notes.txt')),
      );
      await tester.pumpAndSettle();

      expect(find.text('第一段'), findsOneWidget);
      expect(source.fileCalls.single.path, 'notes.txt');
      expect(source.fileCalls.single.offset, 0);
      expect(source.fileCalls.single.version, isNull);
      expect(
        find.byKey(const ValueKey<String>('remote-file-load-more')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('remote-file-load-more')),
      );
      await tester.pumpAndSettle();

      expect(find.text('第一段第二段'), findsOneWidget);
      expect(source.fileCalls.last.offset, 5);
      expect(source.fileCalls.last.version, 'file-v1');
      expect(
        find.byKey(const ValueKey<String>('remote-file-load-more')),
        findsNothing,
        reason: '到文件末尾后不再显示加载更多',
      );
    });

    testWidgets('非文本文件显示专用说明', (tester) async {
      final source = FakeRemoteFilesSource(
        directories: <String, List<RemoteDshDirectoryPage>>{
          '': <RemoteDshDirectoryPage>[
            fakeDirectoryPage(
              entries: <RemoteDshFileEntry>[
                fakeFileEntry('image.bin', bytes: 32),
              ],
            ),
          ],
        },
        fileError: PlatformException(
          code: 'workspace-files/not-text',
          message: '此文件不是可预览的 UTF-8 文本。',
        ),
      );
      await _show(tester, source);

      await tester.tap(
        find.byKey(const ValueKey<String>('remote-file:image.bin')),
      );
      await tester.pumpAndSettle();

      expect(find.text('这个文件不能作为文本预览'), findsOneWidget);
      expect(find.text('此文件不是可预览的 UTF-8 文本。'), findsOneWidget);
    });

    testWidgets('文件读取失败可重试', (tester) async {
      final source = FakeRemoteFilesSource(
        directories: <String, List<RemoteDshDirectoryPage>>{
          '': <RemoteDshDirectoryPage>[
            fakeDirectoryPage(
              entries: <RemoteDshFileEntry>[fakeFileEntry('a.txt')],
            ),
          ],
        },
        files: <String, List<RemoteDshFilePage>>{
          'a.txt': <RemoteDshFilePage>[
            fakeFilePage(path: 'a.txt', text: '内容', bytes: 6),
          ],
        },
        fileError: PlatformException(
          code: 'workspace-files/changed',
          message: '文件或目录已变化，已显示内容保留。请从头刷新后继续。',
        ),
      );
      await _show(tester, source);

      await tester.tap(find.byKey(const ValueKey<String>('remote-file:a.txt')));
      await tester.pumpAndSettle();
      expect(find.text('文件或目录已变化，已显示内容保留。请从头刷新后继续。'), findsOneWidget);

      source.fileError = null;
      await tester.tap(
        find.byKey(const ValueKey<String>('remote-files-retry')),
      );
      await tester.pumpAndSettle();

      expect(find.text('内容'), findsOneWidget);
    });
  });

  group('能力门控', () {
    testWidgets('宿主明确不支持时只显示原因，不发任何请求', (tester) async {
      final source = FakeRemoteFilesSource(
        capability: const RemoteDshCapability.unavailable(
          '这台电脑声明不支持「workspace.files.list」。',
        ),
      );
      await _show(tester, source);

      expect(find.text('这台电脑不支持浏览文件'), findsOneWidget);
      expect(find.text('这台电脑声明不支持「workspace.files.list」。'), findsOneWidget);
      expect(source.directoryCalls, isEmpty);
    });

    testWidgets('方法表里没有声明时同样给出可读原因', (tester) async {
      final source = FakeRemoteFilesSource(
        capability: const RemoteDshCapability.notDeclared(
          '这台电脑没有声明「workspace.files.read」，暂时无法使用。',
        ),
      );
      await _show(tester, source);

      expect(find.text('这台电脑不支持浏览文件'), findsOneWidget);
      expect(find.textContaining('没有声明'), findsOneWidget);
      expect(source.directoryCalls, isEmpty);
    });
  });

  group('解析 workspace.files 应答', () {
    test('目录解析保留类型、分页与不可打开原因', () {
      final page = parseRemoteDshDirectoryPage(<String, dynamic>{
        'root': r'C:\work',
        'path': '',
        'version': 'dir-v1',
        'offset': 0,
        'nextOffset': 2,
        'truncated': false,
        'listedEntries': 3,
        'entries': <dynamic>[
          <String, dynamic>{
            'name': 'src',
            'path': 'src',
            'kind': 'directory',
            'modifiedAt': 1,
          },
          <String, dynamic>{
            'name': 'a.txt',
            'path': 'a.txt',
            'kind': 'file',
            'bytes': 5,
            'modifiedAt': 2,
          },
          <String, dynamic>{'name': 'ln', 'path': null, 'kind': 'link'},
        ],
      });

      expect(page.root, r'C:\work');
      expect(page.path, '');
      expect(page.nextOffset, 2);
      expect(page.entries, hasLength(3));
      expect(page.entries.first.isDirectory, isTrue);
      expect(page.entries[1].bytes, 5);
      expect(page.entries[2].path, isEmpty);
      expect(page.entries[2].blockedReason, 'symlink');
      expect(page.entries[2].openable, isFalse);
    });

    test('续页位置不大于当前偏移时视为读完', () {
      final page = parseRemoteDshDirectoryPage(<String, dynamic>{
        'root': r'C:\work',
        'path': 'src',
        'version': 'v',
        'offset': 4,
        'nextOffset': 4,
        'entries': <dynamic>[],
      });
      expect(page.nextOffset, isNull);
    });

    test('顶层不是对象时抛可重试的读取失败', () {
      expect(
        () => parseRemoteDshDirectoryPage(<dynamic>['not', 'a', 'map']),
        throwsA(
          isA<PlatformException>().having(
            (failure) => failure.code,
            'code',
            'remote/bad-response',
          ),
        ),
      );
    });

    test('文件页解析出文本、版本与末尾标记', () {
      final page = parseRemoteDshFilePage(<String, dynamic>{
        'root': r'C:\work',
        'path': 'a.txt',
        'version': 'file-v1',
        'bytes': 8,
        'offset': 0,
        'nextOffset': 8,
        'eof': true,
        'text': '你好',
      });
      expect(page.text, '你好');
      expect(page.version, 'file-v1');
      expect(page.eof, isTrue);
      expect(page.hasMore, isFalse);
    });

    test('文件页字段不完整时抛坏响应', () {
      expect(
        () => parseRemoteDshFilePage(<String, dynamic>{
          'root': r'C:\work',
          'path': 'a.txt',
        }),
        throwsA(
          isA<PlatformException>().having(
            (failure) => failure.code,
            'code',
            'remote/bad-response',
          ),
        ),
      );
    });
  });
}
