---
description: "由实时会话失败事件触发的 Android 账号额度提示。"
kind: "package-reference"
---

# Android 账号额度提示

[English](account-quota-notice.md) | 中文

## 用户行为

实时追加的 `turn/end` 事件若包含 `ACCOUNT_QUOTA` 错误码，App 会在当前页面上方显示账号额度提示，说明任务因额度不足而停止。账号已登录、连接正常且平台提供充值地址时，可在 Android Custom Tab 打开充值页面；否则可关闭提示，并前往“账号与余额”处理。浏览器启动失败时，提示保持打开以便重试，不展示原生错误中的私有细节。普通 `QUOTA` 失败仅显示短暂提示，不提供账号操作，与原版 `ui-chat` 的回退行为一致。关闭提示不会重试任务。

历史分页、已完成的任务和其他失败不会触发额度提示。同一时间已有提示时，后续失败不会替换它；关闭后，新的实时额度失败可以再次提示。原始失败仍可在会话中查看。

## 归属与限制

DSH 原版 `ui-chat` 包负责监听实时 `turn/end` 错误码，`ui-settings-account` 包只接管 `ACCOUNT_QUOTA` 并打开平台充值页。Android 沿用相同错误码、现有账号服务快照和 `account.openPage` 原生操作。它不会从缓存余额推断额度耗尽，不会提交新的模型请求，也不会因读取旧会话而打开浏览器。

[无密钥实时会话夹具](../test/fixtures/quota_notice_live_session.json)及其组件测试覆盖触发条件、单条提示、仅账号错误提供充值、普通提示、窄屏布局、原生页面启动失败和提示期间退出登录。Custom Tab 与从账号页面返回的行为仍需真机验收。
