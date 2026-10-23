import 'package:material_ui/material_ui.dart';

import 'chat_feedback.dart';
import 'ui.dart';

/// Shared category and optional remark editor for session and message feedback.
/// Both targets use DSH's durable category ids and differ only in submission.
class FeedbackDraftBody extends StatelessWidget {
  const FeedbackDraftBody({
    required this.text,
    required this.category,
    required this.enabled,
    required this.hint,
    required this.explanation,
    required this.onCategory,
    super.key,
  });

  final TextEditingController text;
  final String? category;
  final bool enabled;
  final String hint, explanation;
  final ValueChanged<String> onCategory;

  @override
  Widget build(BuildContext context) => PocketList(
    children: [
      PocketSection(
        title: '反馈分类',
        divided: true,
        children: [
          for (final entry in chatFeedbackCategories.entries)
            PocketTile(
              title: Text(entry.value),
              selected: category == entry.key,
              trailing: category == entry.key
                  ? const Icon(Icons.check_rounded, size: 20)
                  : const SizedBox(width: 20),
              onTap: enabled ? () => onCategory(entry.key) : null,
            ),
        ],
      ),
      PocketSection(
        title: '反馈详情',
        children: [
          TextField(
            controller: text,
            enabled: enabled,
            minLines: 3,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            decoration: InputDecoration(
              hintText: hint,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
          ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Text(explanation),
      ),
    ],
  );
}
