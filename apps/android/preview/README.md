# Android document preview

English | [中文](README.zh.md)

This entry mounts the original DSH document-preview plugin in a document-only Cordis client. Flutter owns the title and navigation; the original document owner, resource faces, renderers, lifecycle, file-change stream, and cancellation remain in use. It does not embed the full Web app or start its HTTP listener.

`tool/build-document-preview.mjs` bundles the small native shell and its existing platform singleton dependencies, then copies the built original client chunks without modification. Run the repository build first when original sources have changed. Output is `.cache/android/document-preview`; `asset-manifest.json` records the source chunk hashes and every distributed asset's path, byte length, and SHA-256. Each build safely replaces only its checked Android cache directory.

```powershell
node apps/android/tool/build-document-preview.mjs
node --test apps/android/preview/bridge.test.mjs apps/android/tool/build-document-preview.test.mjs
node --test apps/android/preview/browser.test.mjs
```

The browser check uses the installed Edge browser with an isolated temporary profile and fixture data. Its 412-pixel screenshots under `.cache/android/document-preview-smoke` include a simulated floating title for layout review; they are not evidence of Android WebView or phone acceptance.

## Native contract

The sole channel is `window.PocketDocument.postMessage(JSON.stringify(frame))`; responses arrive through `PocketDocument.onmessage`. Every frame has a unique `id`, including fire-and-forget cancellation, ACK, unsubscribe, and release.

- `ready` returns the fixed session, path, locale, theme, optional line, and native title/bottom insets. Insets belong to document scroll content so content can continue behind the floating native title.
- `call` forwards original positional services as named arguments. The native host independently restricts the document client to its bound session and approved `workspaceFiles`/`officeToPdf` methods. Calls return original `RemoteResult` envelopes.
- Binary results use a byte lease. `bytes` reads at most 256 KiB per frame; `release` runs on success or failed decode. Closing or aborting cancels pending calls and lets the native document lifetime reclaim abandoned leases.
- `subscribe` opens the original file-change stream. Events may precede its receipt. `ack` carries the event's sequence and generation only after the original consumer processes it; `unsubscribe` closes the feed.
- `external` forwards a user-selected HTTP(S) link through the original Markdown delegate. The native host validates the URL and opens the system browser; the document WebView does not navigate or create a new window. Local-file delegates remain unchanged.

The native host permits only the exact app asset origin and packaged document assets. Static assets use query-free URLs. Original HTML keeps its sandboxed iframe and no script permission. Embedded local Markdown images use the original `api/file?path=...` route, which requires the separate native session-bound media adapter; it is not a general network or filesystem bridge.

## Current verification boundary

Host browser checks exercise original text, Markdown with local images, source code, image, PDF, CSV, XLSX and static HTML renderers, PDF/Excel workers, a live file change, byte lease release, and HTML isolation. Original PDF assets and Excel workers remain inside their unchanged renderer chunks; bundled fonts and licenses are included in the inventory. Excel retains the original grid, formula strip and sheet tabs, including its desktop-sized cell typography and horizontal scrolling.

Word and PowerPoint use the original `office-to-pdf` provider with the pinned 0.2.0 LibreOffice-kit WASM engine. The Android profile caps one active conversion, 10 MiB input, 20 MiB output, queue/cache size, font loading, and a 90-second conversion deadline. The original session-scoped file authorization, cancellation, source-version check, byte lease, and PDF renderer remain in the path. Staging verifies npm SHA-512 and engine asset SHA-256; packaging rechecks the actual runtime ZIP, including license files.

Host checks have converted real DOCX and XLSX fixtures through the staged engine, and a DOCX through the original authorized provider, verified cache reuse and malformed/oversized rejection, and confirmed the runtime ZIP contains the engine. The kit terminates its worker after each conversion. In a repeated host run, process peak RSS reached 958 MiB for DOCX and 1.26 GiB after XLSX; current RSS settled near 439 MiB after conversion, converter disposal, and explicit GC. This is still a substantial persistent footprint, and host memory behavior does not establish Android's per-app survival limit.

Office parity must remain pending until a real ARM64 device opens DOCX and PPTX through the document UI, repeats conversions, cancels one, backgrounds and resumes the app during a conversion, and shows neither a process death nor loss of the Agent task. Check Android system-font substitution and PDF page content, not only a `%PDF-` header. If the device kills the process or conversion cannot complete within the configured limits, keep a clear retry/error state and do not claim Office preview as accepted; re-evaluate a lower-memory engine or an explicit opt-in external conversion path. The full document-preview profile smoke currently stops before the Office call because the Windows test host refuses the original workspace storage atomic rename with `EPERM`. Neither host conversion nor APK presence proves WebView or on-device Office rendering.
