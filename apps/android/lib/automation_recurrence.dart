import 'package:material_ui/material_ui.dart';

import 'text_document_page.dart';
import 'ui.dart';

const automationMaximumIntervalSeconds = 9007199254740991;

bool automationIsWorkdays(String weekdays) {
  final days = weekdays.split(',').map(int.tryParse).whereType<int>().toSet();
  return days.length == 5 && days.containsAll(const [1, 2, 3, 4, 5]);
}

String automationRepeatLabel(String kind, String weekdays) {
  if (kind == 'weekly' && automationIsWorkdays(weekdays)) return '周一至周五';
  return switch (kind) {
    'at' => '单次',
    'every' => '固定间隔',
    'daily' => '每天',
    'weekly' => '每周',
    'cron' => '自定义 Cron',
    _ => '未知规则',
  };
}

String automationIntervalLabel(int seconds) {
  if (seconds % 3600 == 0) return '每 ${seconds ~/ 3600} 小时';
  if (seconds % 60 == 0) return '每 ${seconds ~/ 60} 分钟';
  return '每 $seconds 秒';
}

String automationIntervalSummary(String raw) {
  final seconds = int.tryParse(raw);
  if (seconds == null ||
      seconds < 60 ||
      seconds > automationMaximumIntervalSeconds) {
    return '检查间隔数值';
  }
  return automationIntervalLabel(seconds);
}

class AutomationRepeatSelection {
  const AutomationRepeatSelection(this.kind, {this.weekdays});
  final String kind;
  final String? weekdays;
}

class AutomationRepeatPage extends StatelessWidget {
  const AutomationRepeatPage({
    super.key,
    required this.kind,
    required this.weekdays,
  });
  final String kind, weekdays;

  bool selected(String choice) => switch (choice) {
    'workdays' => kind == 'weekly' && automationIsWorkdays(weekdays),
    'weekly' => kind == 'weekly' && !automationIsWorkdays(weekdays),
    _ => kind == choice,
  };

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('重复'),
    body: PocketList(
      padding: const EdgeInsets.all(20),
      children: [
        PocketSection(
          divided: true,
          children: [
            for (final (choice, label) in const [
              ('at', '单次'),
              ('daily', '每天'),
              ('workdays', '周一至周五'),
              ('weekly', '每周'),
              ('every', '固定间隔'),
              ('cron', '自定义 Cron'),
            ])
              PocketTile(
                key: ValueKey('automation-repeat-$choice'),
                title: Text(label),
                selected: selected(choice),
                trailing: selected(choice)
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(
                  context,
                  choice == 'workdays'
                      ? const AutomationRepeatSelection(
                          'weekly',
                          weekdays: '1,2,3,4,5',
                        )
                      : choice == 'weekly' && automationIsWorkdays(weekdays)
                      ? const AutomationRepeatSelection('weekly', weekdays: '1')
                      : AutomationRepeatSelection(choice),
                ),
              ),
          ],
        ),
      ],
    ),
  );
}

class AutomationIntervalPage extends StatefulWidget {
  const AutomationIntervalPage({super.key, required this.seconds});
  final String seconds;

  @override
  State<AutomationIntervalPage> createState() => _AutomationIntervalPageState();
}

class _AutomationIntervalPageState extends State<AutomationIntervalPage> {
  late final initial = int.tryParse(widget.seconds);
  late int unit = initial != null && initial! > 0 && initial! % 3600 == 0
      ? 3600
      : initial != null && initial! > 0 && initial! % 60 == 0
      ? 60
      : 1;
  late final controller = TextEditingController(
    text: initial == null ? widget.seconds : '${initial! ~/ unit}',
  );

  int? get seconds {
    final amount = int.tryParse(controller.text.trim());
    if (amount == null || amount <= 0) return null;
    if (amount > automationMaximumIntervalSeconds ~/ unit) return null;
    final total = amount * unit;
    return total < 60 ? null : total;
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('重复间隔'),
    trailing: GlassButton(
      icon: Icons.check_rounded,
      label: '完成间隔编辑',
      onPressed: seconds == null ? null : () => Navigator.pop(context, seconds),
    ),
    body: PocketList(
      padding: const EdgeInsets.all(20),
      children: [
        PocketSection(
          title: '单位',
          divided: true,
          children: [
            for (final (factor, label) in const [
              (3600, '小时'),
              (60, '分钟'),
              (1, '秒'),
            ])
              PocketTile(
                key: ValueKey('automation-interval-unit-$factor'),
                title: Text(label),
                selected: unit == factor,
                trailing: unit == factor
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => setState(() => unit = factor),
              ),
          ],
        ),
        const SizedBox(height: 20),
        PocketSection(
          title: '数量',
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: TextDocumentField(
                fieldKey: const ValueKey('automation-interval-amount'),
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: false,
                ),
                errorText: seconds == null ? '间隔至少 60 秒，且须为安全整数。' : null,
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        if (seconds != null)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(automationIntervalLabel(seconds!)),
          ),
      ],
    ),
  );
}

class AutomationWeekdaysPage extends StatefulWidget {
  const AutomationWeekdaysPage({super.key, required this.weekdays});
  final String weekdays;

  @override
  State<AutomationWeekdaysPage> createState() => _AutomationWeekdaysPageState();
}

class _AutomationWeekdaysPageState extends State<AutomationWeekdaysPage> {
  late final days = widget.weekdays
      .split(',')
      .map(int.tryParse)
      .whereType<int>()
      .toSet();

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: const Text('星期'),
    trailing: GlassButton(
      icon: Icons.check_rounded,
      label: '完成星期编辑',
      onPressed: days.isEmpty
          ? null
          : () => Navigator.pop(context, (days.toList()..sort()).join(',')),
    ),
    body: PocketList(
      padding: const EdgeInsets.all(20),
      children: [
        PocketSection(
          divided: true,
          children: [
            for (var day = 1; day <= 7; day++)
              PocketTile(
                key: ValueKey('automation-weekday-$day'),
                title: Text(
                  const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][day - 1],
                ),
                selected: days.contains(day),
                trailing: days.contains(day)
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => setState(() {
                  if (!days.remove(day)) days.add(day);
                }),
              ),
          ],
        ),
        if (days.isEmpty)
          const Padding(padding: EdgeInsets.all(20), child: Text('至少选择一个星期。')),
      ],
    ),
  );
}
