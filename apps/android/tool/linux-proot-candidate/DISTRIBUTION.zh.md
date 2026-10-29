# Linux 客体分发门槛

这是针对**当前固定候选版本**的工程清单，不是法律意见，也不表示可以分发。
本次核对时，PRoot 候选二进制和 Alpine minirootfs 均未进入 APK。可运行：

```powershell
python apps/android/tool/linux-proot-candidate/verify-distribution.py --apk .cache/android/pocket-harness-0.1.0+96-arm64-debug.apk
python -m unittest discover -s apps/android/tool/linux-proot-candidate -p 'test_*.py'
```

脚本核验三个 PRoot 构建输入源码归档、其中的许可证文件、锁定的 Alpine
归档及其已安装软件包数据库；若 APK 出现**已知候选载荷文件名**，即拒绝。
通过时仍输出 `distributionApproved: false`。更名或重新编码的载荷不在
扫描范围内；这不是通用许可证扫描器。
另有 [APK 校验与主机预检](PROBE-READINESS.zh.md)，可拒绝在 APK 顶层
改名后的这两个**精确** ELF 摘要；两种检查都不覆盖任意修改或嵌套载荷。

## 固定源码中的实际内容

| 产物 | 固定归档中的证据 | 分发前工作 |
| --- | --- | --- |
| Termux PRoot 5.1.107.96 | `COPYING` 为 GPLv2；部分核心与 loader 源码头部写明 GPL-2.0-or-later。`src/extension/sysvipc/sysvipc_sys.h` 声明定义取自 glibc，采用 LGPL-2.1-or-later。候选 CMake 选中的 66 个 C 文件中有 31 个在前 2 KiB 没有单独的 GPL 声明。 | 逐个核对参与编译的单元和复制的头文件定义的来源及授权，再决定组合程序的许可版本；保留声明、准确源码、构建方法与修改。 |
| Samba talloc 2.4.3 | `talloc.c`、`talloc.h` 为 LGPL-3.0-or-later，`LICENSE` 为 LGPLv3；候选程序**静态链接** `talloc.c`。 | 核对 GPLv2-or-later 与 LGPLv3 的组合、保留两方声明，并按所选条款提供对应源码和修改／重新链接途径。当前构建不属于已审核的分发物。 |
| Termux libandroid-shmem 0.7 | `LICENSE` 的形式接近 BSD-3-Clause，并列出两位版权人，但第三项条件仍有原样 `{organization}` 占位符。 | 应向版权人或可靠的上游许可记录核实占位符的含义，不能擅改许可文本并直接认定精确的许可类型。当前候选静态链接了补丁后的源码；若分发，须保留实际声明和准确改动。带键共享模式默认关闭。 |
| Alpine 3.24.3 aarch64 minirootfs | `./lib/apk/db/installed` 列出来自十个源码 origin 的 16 个包，许可各异。 | 归档是多个二进制软件包的集合。纳入 APK 前须逐一核对对应源码、打包配方／补丁、版权和许可证声明及具体版本。 |

Alpine 已安装数据库记载：

| 源码 origin | 已安装软件包 | 许可证元数据 |
| --- | --- | --- |
| `alpine-baselayout` | `alpine-baselayout`, `alpine-baselayout-data` | GPL-2.0-only |
| `alpine-keys` | `alpine-keys` | MIT |
| `alpine-base` | `alpine-release` | MIT |
| `apk-tools` | `apk-tools`, `libapk` | GPL-2.0-only |
| `busybox` | `busybox`, `busybox-binsh`, `ssl_client` | GPL-2.0-only |
| `ca-certificates` | `ca-certificates-bundle` | MPL-2.0 AND MIT |
| `openssl` | `libcrypto3`, `libssl3` | Apache-2.0 |
| `musl` | `musl`, `musl-utils` | MIT；MIT AND BSD-2-Clause AND GPL-2.0-or-later |
| `pax-utils` | `scanelf` | GPL-2.0-only |
| `zlib` | `zlib` | Zlib |

minirootfs 自身**没有**包含完整打包配方及对应源码。Alpine 说明
[aports 仓库](https://wiki.alpinelinux.org/wiki/Aports_tree)含 `APKBUILD`
配方，而已构建的 `tar.gz` 镜像不含配方。其
[打包指南](https://wiki.alpinelinux.org/wiki/Creating_an_Alpine_package)
也要求依据源码头部和许可证文件检查软件包的许可元数据。已安装数据库只是
清单，不能独自证明各包上游许可或匹配的源码修订。

## 调试包与正式包的当前决定

已锁定的源码包有助于重建，但尚未完成二进制交付审核。文件级授权、
`libandroid-shmem` 声明、适用许可证全文、对应源码交付方式和实际重新链接
方法明确之前，发送给测试人员或用户的 APK 均不应包含 PRoot、loader 或
Alpine。不能仅凭“调试版”标签豁免分发条件。纯本地编译且不转交二进制
属于另一种活动；具体转交是否构成分发仍取决于事实。
[GNU 许可 FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#v2v3Compatibility)
说明 GPLv2-or-later 可选 GPLv3；其[静态链接解释](https://www.gnu.org/licenses/gpl-faq.en.html#LGPLStaticVsDynamic)
说明 LGPL 库的重新链接材料。[BSD-3-Clause 正文](https://opensource.org/license/bsd-3-clause)
要求二进制分发时复制声明，而固定的 shmem 源码仍有占位符需要核实。
这些资料支持工程闸门，但不能直接判定 App 与 PRoot 是否构成组合作品。

## 加入任何客体载荷前的发布证据

1. 固定 APK 构建、PRoot／loader ELF 摘要、rootfs 摘要、源码归档、
   依赖图及全部改动。对应源码包中包括候选 `build.ps1`、CMake 配置、
   生成文件的方法、补丁以及精确的编译工具链前提。
2. 对照每个参与构建的源文件，包含 `sysvipc_sys.h` 内复制的 glibc
   定义，解决 PRoot/talloc 许可组合问题。talloc 归档只含 LGPLv3 正文，
   其中引用 GPLv3；交付时还须检查适用的 GPLv3 和 LGPLv2.1 正文。
   [GNU 兼容矩阵](https://www.gnu.org/licenses/gpl-faq.en.html#AllCompatibility)
   显示 GPLv2-or-later 与 LGPLv3 可在 GPLv3 下组合，但前提是实际
   源码授权允许。[LGPLv3 组合作品条款](https://www.gnu.org/licenses/lgpl-3.0.html#section4)
   和 [GPLv3 对应源码条款](https://www.gnu.org/licenses/gpl-3.0.html#section6)
   决定具体分发方式。不能认为只有上游网址或压缩包摘要就满足要求。
3. 对上表中每个 Alpine origin，取得并固定与**已安装版本**匹配的
   上游源码、Alpine `APKBUILD`、补丁及配置。保留声明，使 APK 接收者
   能按分发二进制时选用的条款实际取得对应源码。
   [GPLv2 对象代码条款](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html#SEC3)
   明确将编译和安装脚本计入完整源码。
4. 在 APK 分发处提供许可证正文、版权／修改声明、源码获取方式；审核
   PRoot 构建单元和 Alpine 全包的附加许可。另需审查 App 与 PRoot 的
   集成边界，不能仅凭进程分离就作出法律结论。
5. 完成上述工作后，才能更新 APK 门禁，让其识别有意纳入的客体载荷，
   将该载荷摘要与已审核的源码包绑定，并核验 APK 和源码同步发布。
   Android 客体执行、tracee 回收、文件／网络代理和真机验收是**独立**
   的技术门槛。

目前固定 URL 的安装器没有连接到用户操作或模型工具，不使 APK 包含 Alpine。
如果未来支持运行时下载，还需单独审查向用户展示的源码／许可信息及平台
义务，不能预先把该方案视为绕开再分发义务的方法。
