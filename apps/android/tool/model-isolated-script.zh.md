# Android 模型脚本适配边界

这是**尚未注册的适配草稿**，不是原版 DSH 的 `run_code` 工具。原版工具位于 `packages/core/tools/src/ptc.ts`，接受 TypeScript 异步函数体，并注入带作用域的 `tools.*` 调用；`workflow-ptc` 也要求 TypeScript 运行时。Android 宿主可把可擦除的 TypeScript 转为隔离 V8 入口所需的 JavaScript 函数体，并保持源码位置。原生 Binder 工具回调通道已经存在，但原版工具绑定尚无生产模型调用方，也未通过真机验收。Android 的 `ptc-runtime`、`workflow-ptc` 和 `tool-workflow` 继续关闭。

`prepareModelIsolatedScript` 只接收未来不可信模型工具的 `{language: "typescript-function-body", code, description}`；受信任宿主提供会话身份、期限和已签发的 `IsolatedSandboxPolicy`，适配器生成新运行 ID。宿主策略默认只读且断网，可分别描述 App 已批准的可写路径与精确 HTTPS 主机。模型与宿主必需字段都必须是自有数据属性；缺失字段不会读取继承的访问器。模型提供的 `runId`、`sessionId`、`sandboxPolicy`、路径、主机、提权和超时字段都会拒绝；伪造的宿主策略也被拒绝。生成的草稿不可变，也不会授权副作用。此适配器的原生准入目前仍拒绝非空权限范围，模型执行闸门也保持关闭；启用前必须接通 App 的受信任审批发起方并验证原生执行边界。

`runModelIsolatedScript` 总是在接触桥接器之前触发已有的 `ANDROID_PTC_UNAVAILABLE` 闸门，重复调用不能准入或重放运行。`projectModelIsolatedScriptReceipt` 只有在运行 ID 匹配且持久终态为 `COMPLETED` 时才展示结果；取消、超时和结果不确定不会泄漏输出。后一项投影属于宿主契约测试，不是真机 Binder／JNI 证据。

`startAppOwnedModelIsolatedScript` 是该关闭闸门后的 App 宿主内部执行器。它将真正签发的草稿限定为一次使用，要求 App 签发的原生桥接器和回调管理器，并通过 `native.isolated.admit` 准入编译后的函数体。App 在运行来宾代码前绑定所选纯计算／只读 ToolRuntime 白名单。每次嵌套调用在结果返回来宾前完成授权并写入父会话审计；取消会等待原生停止和回调收尾。原生适配器在准入前拒绝所有非空文件、写入或网络权限范围。宿主测试覆盖这条 Android RPC 路径；它尚未注册为模型工具，也不能代替真机 UID、Binder 与进程终止证据。

验证命令：`node --test apps/android/tool/model-isolated-script.test.mjs apps/android/tool/app-owned-model-ptc.test.mjs`。测试覆盖身份归属、伪造授权字段及原型访问器、TypeScript 格式、受信任策略投影、关闭闸门不派发、App 归属的原生准入与子调用、草稿单次使用、取消和输出扣留。启用工具前仍需原生函数体准入、嵌套工具绑定等价性、App 策略审阅、设备 UID／Binder／网络／文件／进程死亡验收和明确的产品决策。
