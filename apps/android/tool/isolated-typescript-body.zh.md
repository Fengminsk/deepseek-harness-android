# Android TypeScript 函数体准备

[English](isolated-typescript-body.md) | 中文

原版 Node PTC 提供方把模型程序包成异步函数体，再调用 Node 的 `stripTypeScriptTypes()` 擦除类型。[`isolated-typescript-body.mjs`](../runtime/isolated-typescript-body.mjs) 在准备可信的 Android 脚本请求前使用相同的包裹方式和内置 API。它接受类型标注、接口、类型别名、泛型、`as` 和 `satisfies` 等可擦除 TypeScript；枚举、命名空间和构造函数参数属性等需要生成运行时代码的语法会被拒绝。顶层 `await` 与 `return` 仍按函数体语法处理。这一步不会调用生成的函数，也不会授予文件、网络或工具能力。

编译器按原生 64 KiB 程序上限检查原文和结果的 UTF-8 字节数，拒绝不成对的代理字符，要求类型擦除后包裹结构仍完整，并核对每个物理行的 UTF-16 长度。随后它将已擦除的函数体作为 `AsyncFunction` 参数进行编译，但不调用函数；试图逃出原包裹结构的文本不会在 App 宿主执行。冻结的结果包含 JavaScript 函数体、原文及结果的哈希和行数元数据。`originalTypeScriptLocation()` 把**传给原生 AsyncFunction 的字符串**中的位置，扣除原生增加的一行 `'use strict';` 前缀后对应回 TypeScript 原文。原生回执目前只有状态码，没有 V8 堆栈位置；该数据仅供后续准备流程使用，不能视为运行时诊断已完成源码定位。

`prepareIsolatedTypeScriptRun()` 接受可信、由 App 持有的脚本请求，拒绝访问器和多余字段，只把程序换成编译后的 JavaScript，再借现有执行预检绑定选中的会话、运行 ID、截止时间和可信策略。接入原生准入时，返回的原文与两个哈希必须先写入持久化运行所有者记录。现有手动原生页面仍使用自己的 JavaScript 入口。模型可见 PTC 和工作流闸门继续关闭：V8 客体尚缺原版 Node API、`tools.*` 回调等价实现、TypeScript 准备链路、运行时源码诊断和普通设备验收。Node 的类型擦除 API 仍是实验性功能，启用前必须一起核对开发宿主与 Android 包内 Node 版本。

运行 `node --test apps/android/tool/isolated-typescript-body.test.mjs`。测试将转译结果与原版提供方包裹方式及 Node 擦除结果比较，仅在测试中执行一个已擦除示例，拒绝不可擦除及包裹逃逸语法，验证宿主不调用代码，并覆盖 UTF-8 上限、源码位置及可信请求归属。这些宿主测试没有执行 Android V8 客体。
