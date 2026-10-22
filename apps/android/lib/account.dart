import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'account_presentation.dart';
import 'account_state.dart';
import 'runtime.dart';
import 'ui.dart';
import 'diagnostics.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key, required this.runtime});
  final RuntimeController runtime;
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> with WidgetsBindingObserver {
  AccountState? account;
  String? error, signOutImpact;
  int? signOutRevision;
  bool wantedSignIn = false, checkingImpact = false;
  String? linkCopyStatus;
  Timer? linkCopyTimer;
  bool initialized = false;
  late String runtimePhase;

  @override
  void initState() {
    super.initState();
    runtimePhase = widget.runtime.phase;
    WidgetsBinding.instance.addObserver(this);
    widget.runtime.addListener(handleAccountReturn);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!initialized) {
      initialized = true;
      unawaited(initialize());
    }
  }

  void handleAccountReturn() {
    if (mounted && runtimePhase != widget.runtime.phase) {
      setState(() => runtimePhase = widget.runtime.phase);
    }
    if (!mounted ||
        widget.runtime.navigationRequest?['route'] != 'account' ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    widget.runtime.consumeNavigation();
    final model = account;
    if (model != null) {
      unawaited(
        model.connected ? model.refreshDetails() : model.ensureWatching(),
      );
    }
  }

  Future<void> initialize() async {
    setState(() => error = null);
    try {
      final model = await widget.runtime.ensureAccount(
        locale: Localizations.localeOf(context).toLanguageTag(),
      );
      if (!mounted) return;
      account?.removeListener(changed);
      model.addListener(changed);
      setState(() => account = model);
      await model.ensureWatching();
    } catch (failure) {
      if (mounted) setState(() => error = '无法初始化账号页面，请重新打开。');
    }
  }

  void changed() {
    if (!mounted) return;
    final model = account!;
    final attempt = model.attempt;
    setState(() {});
    if (wantedSignIn &&
        attempt?['phase'] == 'waiting-browser' &&
        attempt?['authorizeUrl'] is String) {
      wantedSignIn = false;
      final id = attempt!['id'];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            model.connected &&
            model.attempt?['id'] == id &&
            model.attempt?['phase'] == 'waiting-browser') {
          unawaited(openPage(attempt['authorizeUrl'] as String));
        }
      });
    }
  }

  Future<void> openPage(String url) async {
    try {
      await RuntimeController.channel.invokeMethod<void>('account.openPage', {
        'url': accountAuthorizeUrl(url, Theme.of(context).brightness),
        'dark': Theme.of(context).brightness == Brightness.dark,
      });
    } catch (failure) {
      if (mounted) {
        setState(() => error = '无法打开官方页面。请确认已安装支持 Custom Tabs 的浏览器，再点击继续授权重试。');
      }
    }
  }

  Future<void> copySignInLink(String url) async {
    final attemptId = account?.attempt?['id'];
    try {
      await Clipboard.setData(
        ClipboardData(
          text: accountAuthorizeUrl(url, Theme.of(context).brightness),
        ),
      );
      if (!mounted || account?.attempt?['id'] != attemptId) return;
      setState(() => linkCopyStatus = '已复制授权链接');
    } catch (_) {
      if (!mounted || account?.attempt?['id'] != attemptId) return;
      setState(() => linkCopyStatus = '复制失败，请重试');
    }
    linkCopyTimer?.cancel();
    linkCopyTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => linkCopyStatus = null);
    });
  }

  Future<void> signIn() async {
    setState(() {
      wantedSignIn = true;
      error = null;
    });
    if (!await account!.signIn() && mounted) {
      setState(() => wantedSignIn = false);
    }
  }

  Future<void> checkSignOut() async {
    final model = account!;
    final revision = model.revision;
    setState(() => checkingImpact = true);
    String impact;
    try {
      impact = await model.api('hasRunningAccountTasks') == true
          ? 'running'
          : 'idle';
    } catch (failure) {
      impact = 'unknown';
    }
    if (!mounted) return;
    setState(() {
      checkingImpact = false;
      if (model.revision == revision) {
        signOutImpact = impact;
        signOutRevision = revision;
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && account != null) {
      unawaited(
        account!.connected
            ? account!.refreshDetails()
            : account!.ensureWatching(),
      );
    }
  }

  @override
  void dispose() {
    linkCopyTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.runtime.removeListener(handleAccountReturn);
    account?.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = account;
    final canAct =
        model?.connected == true && widget.runtime.ready && !model!.working;
    final attempt = model?.attempt;
    final activeAttempt = const [
      'initializing',
      'waiting-browser',
      'exchanging',
      'committing',
    ].contains(attempt?['phase']);
    final profile = model?.profile?['status'] == 'ready'
        ? model!.profile!['value'] as Json
        : null;
    final confirmSignOut =
        signOutImpact != null && signOutRevision == model?.revision;
    return PocketScaffold(
      title: const Text('DeepSeek 账号'),
      trailing: GlassButton(
        icon: Icons.refresh_rounded,
        label: '刷新账号信息',
        onPressed: model == null
            ? initialize
            : () => model.connected
                  ? model.refreshDetails()
                  : model.ensureWatching(),
      ),
      body: PocketList(
        padding: const EdgeInsets.all(20),
        children: [
          if (!widget.runtime.ready)
            PocketSection(
              children: [
                PocketRow(
                  icon: Icons.info_outline_rounded,
                  title: widget.runtime.phase == 'failed'
                      ? '本地服务需要处理'
                      : '正在等待本地服务',
                  subtitle: widget.runtime.error ?? '服务就绪后才能核对账号状态。',
                  onTap: () => Navigator.push(
                    context,
                    PocketRoute<void>(
                      builder: (_) => DiagnosticsPage(runtime: widget.runtime),
                    ),
                  ),
                ),
              ],
            ),
          if (model == null)
            PocketSection(
              children: [
                PocketRow(
                  icon: Icons.person_outline_rounded,
                  title: error == null ? '正在读取账号状态' : '账号暂不可用',
                ),
              ],
            ),
          if (model != null) ...[
            PocketSection(
              children: [
                PocketRow(
                  icon: Icons.account_circle_outlined,
                  title:
                      profile?['name'] as String? ??
                      profile?['contact'] as String? ??
                      'DeepSeek',
                  subtitle: !model.connected
                      ? model.view == null
                            ? '正在读取账号状态'
                            : '显示上次账号信息，正在重新连接'
                      : model.signedIn
                      ? model.profileFresh
                            ? '本机已保存登录凭据'
                            : '本机凭据已保存 · 账号资料待刷新'
                      : '尚未登录',
                ),
                if (profile?['contact'] != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 14),
                    child: SelectableText('${profile!['contact']}'),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (model.connected && !model.signedIn && !activeAttempt)
                        PocketButton(
                          onPressed: canAct ? signIn : null,
                          child: const Text('登录 DeepSeek'),
                        ),
                      if (model.signedIn && !confirmSignOut)
                        PocketButton.tonal(
                          onPressed: canAct && !checkingImpact
                              ? checkSignOut
                              : null,
                          child: Text(checkingImpact ? '正在核对任务' : '退出登录'),
                        ),
                      if (model.signedIn && !confirmSignOut)
                        PocketButton.tonal(
                          onPressed: canAct && !model.initializingModel
                              ? model.initializeDefaultModel
                              : null,
                          child: const Text('初始化账号模型'),
                        ),
                      if (model.signedIn && confirmSignOut) ...[
                        Text(switch (signOutImpact) {
                          'running' => '当前任务正在使用这个账号，退出登录会影响这些任务。',
                          'idle' => '退出登录不会删除会话和 API Key，之后可以重新登录。',
                          _ => '无法确认任务状态，退出登录可能会中断使用这个账号的任务。',
                        }),
                        Wrap(
                          spacing: 12,
                          children: [
                            PocketButton.tonal(
                              onPressed: () =>
                                  setState(() => signOutImpact = null),
                              child: const Text('取消'),
                            ),
                            PocketButton(
                              onPressed: canAct
                                  ? () async {
                                      setState(() => signOutImpact = null);
                                      await model.signOut();
                                    }
                                  : null,
                              child: const Text('确认退出登录'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (model.initializingModel ||
                model.modelInitializationError != null ||
                model.modelInitializationNotice != null)
              PocketSection(
                title: '默认模型',
                children: [
                  PocketRow(
                    icon: Icons.auto_awesome_outlined,
                    title: model.initializingModel
                        ? '正在准备账号模型'
                        : model.modelInitializationError != null
                        ? '账号模型需要处理'
                        : '模型状态已同步',
                    subtitle:
                        model.modelInitializationError ??
                        model.modelInitializationNotice,
                  ),
                  if (model.modelInitializationError != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
                      child: PocketButton.tonal(
                        onPressed: canAct && !model.initializingModel
                            ? model.initializeDefaultModel
                            : null,
                        child: const Text('重试准备模型'),
                      ),
                    ),
                ],
              ),
            if (attempt != null)
              PocketSection(
                title: '授权进度',
                children: [
                  PocketRow(
                    icon: Icons.key_rounded,
                    title: accountAttemptLabel('${attempt['phase']}'),
                    subtitle: attempt['errorCode'] is String
                        ? accountAttemptError(attempt['errorCode'] as String)
                        : null,
                  ),
                  if (activeAttempt)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
                      child: Wrap(
                        spacing: 12,
                        children: [
                          if (attempt['phase'] == 'waiting-browser' &&
                              attempt['authorizeUrl'] is String)
                            PocketButton(
                              onPressed: canAct
                                  ? () => openPage(
                                      attempt['authorizeUrl'] as String,
                                    )
                                  : null,
                              child: const Text('继续官方授权'),
                            ),
                          if (attempt['phase'] == 'waiting-browser' &&
                              attempt['authorizeUrl'] is String)
                            PocketButton.tonal(
                              onPressed: () => copySignInLink(
                                attempt['authorizeUrl'] as String,
                              ),
                              child: Text(linkCopyStatus ?? '复制授权链接'),
                            ),
                          PocketButton.tonal(
                            onPressed:
                                canAct && attempt['phase'] != 'committing'
                                ? () async {
                                    wantedSignIn = false;
                                    await model.cancel();
                                  }
                                : null,
                            child: const Text('取消授权'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            if (model.signedIn) ...[
              PocketSection(
                title: '账号信息',
                children: [
                  if (model.profile?['status'] != 'ready')
                    PocketRow(
                      icon: Icons.person_outline_rounded,
                      title: model.loadingDetails ? '正在读取资料' : '账号资料暂不可用',
                    ),
                  if (model.balance?['status'] == 'ready') ...[
                    for (final wallet in model.balance!['value'] as List)
                      PocketRow(
                        icon: Icons.account_balance_wallet_outlined,
                        title: '充值余额',
                        subtitle: model.balanceFresh ? null : '上次读取，本次尚未更新',
                        trailing: Text(
                          formatAccountBalance(
                            '${wallet['balance']}',
                            '${wallet['currency']}',
                          ),
                        ),
                      ),
                    for (final wallet in model.balance!['bonusWallets'] as List)
                      if (accountBalanceIsPositive('${wallet['balance']}'))
                        PocketRow(
                          icon: Icons.redeem_rounded,
                          title: '赠送余额',
                          subtitle: model.balanceFresh ? null : '上次读取，本次尚未更新',
                          trailing: Text(
                            formatAccountBalance(
                              '${wallet['balance']}',
                              '${wallet['currency']}',
                            ),
                          ),
                        ),
                  ] else
                    PocketRow(
                      icon: Icons.account_balance_wallet_outlined,
                      title: model.loadingDetails ? '正在读取余额' : '余额暂不可用',
                    ),
                ],
              ),
              if (model.bonuses != null)
                PocketSection(
                  title: '平台通知',
                  children: [
                    for (final bonus
                        in (model.bonuses!['bonuses'] as List).cast<Json>())
                      if (!_expired(bonus))
                        PocketRow(
                          icon: Icons.redeem_rounded,
                          title: bonus['title'] as String? ?? '赠送通知',
                          onTap: () => Navigator.push(
                            context,
                            PocketRoute<void>(
                              builder: (_) => AccountBonusPage(
                                account: model,
                                accountId:
                                    model.bonuses!['accountId'] as String,
                                bonus: bonus,
                              ),
                            ),
                          ),
                        ),
                  ],
                ),
            ],
            if (model.view?['links'] is Json)
              PocketSection(
                title: '官方平台',
                children: [
                  PocketRow(
                    icon: Icons.data_usage_rounded,
                    title: '用量明细',
                    onTap: canAct
                        ? () => openPage(
                            model.view!['links']['usageUrl'] as String,
                          )
                        : null,
                  ),
                  PocketRow(
                    icon: Icons.account_balance_wallet_outlined,
                    title: '充值管理',
                    onTap: canAct
                        ? () => openPage(
                            model.view!['links']['topUpUrl'] as String,
                          )
                        : null,
                  ),
                ],
              ),
          ],
          for (final message in [error, model?.error, model?.detailsError])
            if (message != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(message),
              ),
        ],
      ),
    );
  }
}

bool _expired(Json bonus) {
  final expiry = bonus['expiresAt'] as String;
  final at = DateTime.tryParse(expiry);
  return at != null && !at.isAfter(DateTime.now());
}

class AccountBonusPage extends StatefulWidget {
  const AccountBonusPage({
    super.key,
    required this.account,
    required this.accountId,
    required this.bonus,
  });
  final AccountState account;
  final String accountId;
  final Json bonus;
  @override
  State<AccountBonusPage> createState() => _AccountBonusPageState();
}

class _AccountBonusPageState extends State<AccountBonusPage>
    with WidgetsBindingObserver {
  bool acknowledged = false, pending = false;
  String? error;
  bool get eligible =>
      widget.account.signedIn &&
      widget.account.connected &&
      widget.account.bonuses?['accountId'] == widget.accountId &&
      !_expired(widget.bonus);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.account.addListener(changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => shown());
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void shown() {
    if (mounted &&
        eligible &&
        ModalRoute.of(context)?.isCurrent == true &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      unawaited(acknowledge());
    }
  }

  Future<void> acknowledge() async {
    if (acknowledged || pending || !eligible) return;
    setState(() {
      pending = true;
      error = null;
    });
    final accepted = await widget.account.acknowledge(
      widget.accountId,
      widget.bonus['orderId'] as String,
    );
    if (!mounted) return;
    setState(() {
      pending = false;
      acknowledged = accepted;
      if (!accepted && eligible) error = '未能确认已展示这条通知，可重试。';
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => shown());
    }
  }

  @override
  void dispose() {
    widget.account.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PocketScaffold(
    title: Text(widget.bonus['title'] as String? ?? '赠送通知'),
    body: PocketList(
      padding: const EdgeInsets.all(20),
      children: [
        PocketCard(
          padding: const EdgeInsets.all(22),
          child: SelectableText(
            eligible
                ? widget.bonus['message'] as String
                : '这条通知所属的账号已变化，或通知已过期。',
          ),
        ),
        if (error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
        if (error != null && eligible)
          PocketButton.tonal(
            onPressed: pending ? null : acknowledge,
            child: const Text('重试确认已读'),
          ),
        PocketButton(
          onPressed: () async {
            await acknowledge();
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
