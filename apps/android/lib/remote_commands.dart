// 远程会话的指令目录调用面。
//
// 本地 `+` 弹层的数据源是 DSH 的 `api.call {namespace:'commands', method:'list'}`，
// 由 `ComposerCommands` 渲染成「添加 / 指令 / 技能」分组。远程会话页复用同一个
// 组件，只把调用面换成这里：`RemoteComposerCommandSurface` 用
// [RemoteConversationSource] 先 `session.ensure`（冷会话需要宿主唤醒），再透传
// `commands.list`。目录读取失败、方法不支持等情形由 `ComposerCommands` 既有的
// 错误分支与三态说明承担，页面不另造一套菜单。
//
// 线上参数与本地逐字一致：`{namespace:'commands', method:'list',
// args:{agentId: sessionId}}`，两者都在冻结的方法表内（协议 §4.2、§5）。

library;

import 'composer_commands.dart';
import 'remote_connection.dart';
import 'remote_conversation_source.dart';
import 'runtime.dart';

/// 用远程会话数据源实现 [ComposerCommandSurface]。
///
/// 数据源由会话页持有并已连到那台电脑；本类只投影连接阶段与请求入口，不新建
/// 连接、不缓存目录，也不会在页面之外发请求。
class RemoteComposerCommandSurface implements ComposerCommandSurface {
  /// 绑定会话数据源。
  ///
  /// @param source 会话页正在使用的远程会话数据源。
  RemoteComposerCommandSurface(this.source);

  /// 被包装的会话数据源。
  final RemoteConversationSource source;

  /// 连接就绪（阶段为 ready）时才开菜单；未就绪时 `ComposerCommands` 显示
  /// 「正在读取会话菜单…」而不是发起请求。
  @override
  bool get ready => source.phase == RemoteConnectionPhase.ready;

  /// 恢复会话后再读目录（门面 `session.ensure`，幂等）。
  ///
  /// [id] 必须是本数据源绑定的会话；会话页只打开自己的菜单，传错说明页面状态
  /// 不一致，直接报错而不是替另一个会话恢复。
  @override
  Future<Json> ensureSession(String id) {
    if (id != source.sessionId) {
      throw StateError('会话已变化，请返回并重新打开会话菜单。');
    }
    return source.ensureSession();
  }

  /// 门面请求透传；失败文本由数据源翻译成可直接展示的中文。
  @override
  Future<dynamic> call(
    String method, [
    Json params = const <String, dynamic>{},
  ]) => source.request(method, params);
}
