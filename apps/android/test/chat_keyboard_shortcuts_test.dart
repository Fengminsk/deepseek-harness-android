import 'package:dsh_android/chat_shortcuts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('external keyboard opens a new chat and conversation search', (
    tester,
  ) async {
    var newChats = 0;
    var searches = 0;
    var focusRequests = 0;
    var sidebarToggles = 0;
    var settingsOpens = 0;
    final shortcuts = ChatKeyboardShortcuts(
      isActive: () => true,
      isComposing: () => false,
      isEditingOtherField: () => false,
      newChat: () => newChats++,
      searchConversations: () => searches++,
      focusComposer: () => focusRequests++,
      toggleSidebar: () => sidebarToggles++,
      openSettings: () => settingsOpens++,
      canOpenSessionResource: () => true,
      openFiles: () {},
      openBrowser: () {},
      openTerminal: () {},
      dismiss: () => false,
    )..attach();
    addTearDown(shortcuts.dispose);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect((newChats, searches, focusRequests), (1, 1, 1));
    expect((sidebarToggles, settingsOpens), (1, 1));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect((newChats, searches, focusRequests), (1, 1, 1));
    expect((sidebarToggles, settingsOpens), (1, 1));
  });

  testWidgets('composition, another editor, and inactive route keep keys', (
    tester,
  ) async {
    var active = true;
    var composing = true;
    var editingOther = false;
    var newChats = 0;
    var focusRequests = 0;
    var sidebarToggles = 0;
    var settingsOpens = 0;
    final shortcuts = ChatKeyboardShortcuts(
      isActive: () => active,
      isComposing: () => composing,
      isEditingOtherField: () => editingOther,
      newChat: () => newChats++,
      searchConversations: () {},
      focusComposer: () => focusRequests++,
      toggleSidebar: () => sidebarToggles++,
      openSettings: () => settingsOpens++,
      canOpenSessionResource: () => true,
      openFiles: () {},
      openBrowser: () {},
      openTerminal: () {},
      dismiss: () => false,
    )..attach();
    addTearDown(shortcuts.dispose);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    composing = false;
    active = false;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    active = true;
    editingOther = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(newChats, 0);
    expect(focusRequests, 0);
    expect((sidebarToggles, settingsOpens), (0, 0));
  });

  testWidgets('Escape dismisses only an owned chat layer', (tester) async {
    var dismissible = false;
    var dismissals = 0;
    final shortcuts = ChatKeyboardShortcuts(
      isActive: () => true,
      isComposing: () => false,
      isEditingOtherField: () => false,
      newChat: () {},
      searchConversations: () {},
      focusComposer: () {},
      toggleSidebar: () {},
      openSettings: () {},
      canOpenSessionResource: () => true,
      openFiles: () {},
      openBrowser: () {},
      openTerminal: () {},
      dismiss: () {
        if (!dismissible) return false;
        dismissals++;
        return true;
      },
    )..attach();
    addTearDown(shortcuts.dispose);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(dismissals, 0);
    dismissible = true;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(dismissals, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(dismissals, 1);
  });

  testWidgets('Command key works and mixed primary modifiers do not', (
    tester,
  ) async {
    var toggles = 0;
    var settings = 0;
    final shortcuts = ChatKeyboardShortcuts(
      isActive: () => true,
      isComposing: () => false,
      isEditingOtherField: () => false,
      newChat: () {},
      searchConversations: () {},
      focusComposer: () {},
      toggleSidebar: () => toggles++,
      openSettings: () => settings++,
      canOpenSessionResource: () => true,
      openFiles: () {},
      openBrowser: () {},
      openTerminal: () {},
      dismiss: () => false,
    )..attach();
    addTearDown(shortcuts.dispose);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect((toggles, settings), (1, 1));
  });

  testWidgets('resource shortcuts open only for an existing active session', (
    tester,
  ) async {
    var active = true;
    var composing = false;
    var hasSession = false;
    var files = 0;
    var browser = 0;
    var terminal = 0;
    final shortcuts = ChatKeyboardShortcuts(
      isActive: () => active,
      isComposing: () => composing,
      isEditingOtherField: () => false,
      newChat: () {},
      searchConversations: () {},
      focusComposer: () {},
      toggleSidebar: () {},
      openSettings: () {},
      canOpenSessionResource: () => hasSession,
      openFiles: () => files++,
      openBrowser: () => browser++,
      openTerminal: () => terminal++,
      dismiss: () => false,
    )..attach();
    addTearDown(shortcuts.dispose);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
    expect((files, browser, terminal), (0, 0, 0));

    hasSession = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
    expect((files, browser, terminal), (1, 1, 1));

    composing = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    composing = false;
    active = false;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    active = true;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect((files, browser, terminal), (1, 1, 1));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect((files, browser, terminal), (2, 2, 1));
  });
}
