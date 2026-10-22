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
    final shortcuts = ChatKeyboardShortcuts(
      isActive: () => true,
      isComposing: () => false,
      isEditingOtherField: () => false,
      newChat: () => newChats++,
      searchConversations: () => searches++,
      focusComposer: () => focusRequests++,
      dismiss: () => false,
    )..attach();
    addTearDown(shortcuts.dispose);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect((newChats, searches, focusRequests), (1, 1, 1));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect((newChats, searches, focusRequests), (1, 1, 1));
  });

  testWidgets('composition, another editor, and inactive route keep keys', (
    tester,
  ) async {
    var active = true;
    var composing = true;
    var editingOther = false;
    var newChats = 0;
    var focusRequests = 0;
    final shortcuts = ChatKeyboardShortcuts(
      isActive: () => active,
      isComposing: () => composing,
      isEditingOtherField: () => editingOther,
      newChat: () => newChats++,
      searchConversations: () {},
      focusComposer: () => focusRequests++,
      dismiss: () => false,
    )..attach();
    addTearDown(shortcuts.dispose);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    composing = false;
    active = false;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    active = true;
    editingOther = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(newChats, 0);
    expect(focusRequests, 0);
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
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(dismissals, 1);
  });
}
