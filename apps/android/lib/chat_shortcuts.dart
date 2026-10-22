import 'package:flutter/services.dart';

/// Chat-only external-keyboard actions. Native text editing and the IME keep
/// ownership of unmodified keys, active composition, and focused editors.
class ChatKeyboardShortcuts {
  ChatKeyboardShortcuts({
    required this.isActive,
    required this.isComposing,
    required this.isEditingOtherField,
    required this.newChat,
    required this.searchConversations,
    required this.focusComposer,
    required this.dismiss,
  });

  final bool Function() isActive;
  final bool Function() isComposing;
  final bool Function() isEditingOtherField;
  final VoidCallback newChat;
  final VoidCallback searchConversations;
  final VoidCallback focusComposer;
  final bool Function() dismiss;

  void attach() => HardwareKeyboard.instance.addHandler(handle);

  void dispose() => HardwareKeyboard.instance.removeHandler(handle);

  bool handle(KeyEvent event) {
    if (event is! KeyDownEvent || !isActive() || isComposing()) return false;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed || keyboard.isShiftPressed) return false;
    final primary = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (primary) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.keyN:
          newChat();
          return true;
        case LogicalKeyboardKey.keyK:
          searchConversations();
          return true;
        case LogicalKeyboardKey.keyL:
          if (isEditingOtherField()) return false;
          focusComposer();
          return true;
      }
      return false;
    }
    return event.logicalKey == LogicalKeyboardKey.escape && dismiss();
  }
}
