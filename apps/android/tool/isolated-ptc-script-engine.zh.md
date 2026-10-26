# 隔离 JavaScript 引擎基础

中文 | [English](isolated-ptc-script-engine.md)

[`PtcScriptEngine`](../android/app/src/main/java/com/minnnng/dsh_android/PtcScriptEngine.java) 是由内部[隔离脚本执行控制器](isolated-script-run.zh.md)调用的纯 V8 JNI 引擎。它**尚未接入 DSH `run_code` 或工作流**，也没有增加模型可见工具。Android profile 中的 PTC 和工作流仍保持禁用。

调用方传入 JavaScript **函数表达式**，例如 `(input) => ({count: input.count + 1})`，以及一个 JSON 输入值。原生 V8 在客户脚本之前编译私有的快照函数，并在客户全局对象之外持有它。每个返回值都先经过该函数，再做 JSON 编码。它拷贝纯 JSON 数据，拒绝含 `undefined` 字段、数组空洞、非有限数字、`-0`、访问器、不可枚举属性或 Symbol 属性、自定义原型或循环引用的有损结果，状态为 `OUTPUT_INVALID`。快照函数在客户脚本之前捕获内建函数；测试也覆盖了伪造继承描述符字段的情况。

原版 DSH Node provider 接受异步**函数体**，支持可擦除的 TypeScript、顶层 `await` 和 `return`、捕获 `console` 日志、声明的绑定命名空间，并可按沙箱策略访问 Node 模块。Android 现在另有 `runFunctionBody` 入口，支持含顶层 `await` 和 `return` 的**纯 JavaScript 语句**；成功执行会捕获有界的 `console.log/info/warn/error/debug` 文本日志。TypeScript 剥离、Node 模块、持久 REPL 和失败执行的日志保留尚不支持。原有完整 JavaScript 函数表达式入口保持可用。新入口在客户代码运行前取得 V8 内建的 `AsyncFunction` 构造器，把函数体作为独立字符串参数传入，不插入外围表达式，随后在**调用用户代码前**重新关闭字符串代码生成。这避开了已撤回包装方案的定界符逃逸漏洞。函数体只接收 JSON `input`；带宿主回调的重载还可在 App 显式授权后接收 `host` 对象，默认重载没有宿主对象。模型入口尚未调用该引擎。每次调用新建 V8 Isolate 和 context，执行一次函数并返回紧凑 JSON。Promise 可以在 V8 microtask 中完成；未完成的 Promise 返回 `ASYNC_HOST_UNAVAILABLE`。环境没有计时器、事件循环、Node Environment、`process`、`require`、`fs`、`net`、`child_process`、`fetch`、Android 绑定或环境自带的 broker 调用；客户代码不能动态生成字符串代码或编译 WebAssembly。这只是受限计算能力，不能冒充原版可直接调用 Node API 的 PTC provider。

Java API 是 `new PtcScriptEngine()` → `run(program, inputJson, deadlineMillis)` **或** `runFunctionBody(body, inputJson, deadlineMillis)` → `Result {status, outputJson, logsJson}` → `close()`。两种运行方法都会阻塞调用线程，每个实例只能调用一次；另一线程可在运行前或运行期间调用 `cancel()`。每个 guest 进程最多登记一次原生执行。关闭或取消的实例不可复用。调用方还必须独立限制 Binder/Service 总耗时，并将 guest 进程死亡视为失败。`close()` 负责释放原生资源；运行中关闭会中断执行，并保留登记槽直到执行线程退出。

函数表达式或函数体与输入分别限 64 KiB UTF-8，编码后的日志限 16 KiB，日志与返回 JSON 合计限 64 KiB UTF-8，执行截止时间为 1–5000 ms。超限返回 `OUTPUT_TOO_LARGE`，不发布部分日志或返回值。这比原版 Node provider 默认的 120 秒和最长 600 秒更短。原生侧持有的返回值快照还限制为 8192 个值、64 层。每次运行使用新的 V8 堆，旧生代目标上限 16 MiB、新生代目标上限 4 MiB，ArrayBuffer 聚合分配限 8 MiB，禁用 `Atomics.wait`；看门狗在超时或取消时调用 `TerminateExecution()`。V8 堆耗尽可能直接终止整个隔离进程；这些 V8 限制**不等于**进程原生 RSS 的硬上限。状态区分无效请求、输入、程序、脚本错误、无效或过大的 JSON 输出、不支持的待完成异步、超时、取消和引擎不可用；失败时不返回部分 JSON。

引擎仅为使用 V8 导出符号而链接固定版本 `libnode.so`，不会调用 `node::Start`、初始化 Node Environment，也不把 App 私有工作区映射给 guest。后续 PTC 接入仍需提供有版本和大小界限的宿主调用 Promise 桥、App 侧 capability broker、持久调用与结果记录、授权租约、子 Agent 所有权，以及明确声明受限 JS 能力的独立 provider。还必须在普通无 Root 手机上验证隔离 UID 下的原生加载，以及无限循环、内存压力、取消、超时、错误输入、Binder 死亡和进程终止都只生成一次终态。原生编译和主机 Java 检查不能替代真机验收。

主机检查：`node apps/android/tool/acceptance-ptc-script-engine.mjs` 验证 Java 请求边界，针对先前的包装逃逸检查独立 AsyncFunction 函数体语法，并在受限的主机 V8 context 中以原版 PTC 的返回值用例检查原生快照源码，包含恶意原型改写；它不加载 JNI。`node apps/android/tool/acceptance-isolated-script-run.mjs` 检查带日志的版本化持久回执往返。`:app:externalNativeBuildDebug` 使用固定 Android V8 导出符号编译和链接 JNI 库。独立的 `PtcFunctionBodyInstrumentation` 测试 APK 入口会在设备上检查 JNI 运行、环境全局变量、字符串代码生成恢复为拒绝、语法逃逸和无损输出；目前只编译，尚未运行。既有隔离客体验收仍需证明独立 UID 和 Binder 行为。
