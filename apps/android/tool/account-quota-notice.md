---
description: "Android account quota notice driven by live Session failures."
kind: "package-reference"
---

# Android account quota notice

English | [中文](account-quota-notice.zh.md)

## User behavior

A live `turn/end` event with `ACCOUNT_QUOTA` opens one account notice above the current App page. It explains that the task stopped for lack of credit. A signed-in, connected account with a Platform top-up URL can open that URL in an Android Custom Tab; otherwise the notice offers dismissal and directs the user to Account and Balance. A browser launch failure keeps the notice open for retry without showing the private native error. A generic `QUOTA` failure shows a short toast with no account action, matching the original `ui-chat` fallback. Dismissal does not retry the task.

History paging, completed turns, and other failures do not open a quota notice. A notice already on screen is not replaced by another failure. After dismissal, a subsequent live quota failure can open a new notice. The source failure remains visible in the conversation.

## Ownership and limits

The original DSH `ui-chat` package owns the live `turn/end` error-code trigger. Its `ui-settings-account` package takes over only `ACCOUNT_QUOTA` and opens the Platform top-up page. Android uses the same error codes and the existing Account service snapshot and `account.openPage` native action. It does not infer exhaustion from a cached balance, submit a new model request, or open a browser from a restored history page.

The [keyless live Session fixture](../test/fixtures/quota_notice_live_session.json) and its widget tests cover trigger filtering, one active notice, the account-only top-up action, generic toast, narrow layout, native launch failure, and sign-out while open. The Custom Tab and account-return behavior still require device acceptance.
