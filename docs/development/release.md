# 发布流程

## 版本号

对外版本是 `app/pubspec.yaml` 里 `version` 的 `+` 前部分，按语义化版本编号；`+` 后的构建号不进入标签和包名。1.0 之前，加了新功能升第二位（0.1.0 → 0.2.0），只修问题升第三位（0.2.0 → 0.2.1）。首个公开版本是 0.1.0。

`app/pubspec.yaml` 和 `app/rust/Cargo.toml` 的版本必须一致，CLI 的 `--version` 读的是后者。

## 步骤

1. **准备**：改两处版本号（`app/rust/Cargo.lock` 随之更新），在 `docs/releases/<版本>.md` 写版本说明，一起提交到 main。main 上的桌面检查要先通过。
2. **打标签**：在这个提交上打 `v<版本>`（例如 `v0.1.0`）并推送。
3. **构建草稿**：推送标签触发 `.github/workflows/release.yml`：
   - 核对标签与两处版本号一致，不一致就失败；
   - 在标签的提交上跑完整桌面检查（调用 `desktop.yml`，Windows、macOS 都要通过）；
   - 在 GitHub 托管的 Windows、macOS runner 上构建，打成 `token-lens-<版本>-windows-x64.zip`（Release 目录的全部内容）和 `token-lens-<版本>-macos.zip`（顶层是 `Token Lens.app`），两个包都带 `LICENSE`、`THIRD_PARTY_NOTICES.md`、`THIRD_PARTY_LICENSES.txt`；
   - 每个包先解到临时目录，用 `scripts/verify-desktop-zip.py` 核对程序、资源和许可文件都在，再对解出来的程序跑一次合成数据冒烟；
   - 用 `scripts/desktop-release-assets.py` 写出 `SHA256SUMS.txt`（两个包的 SHA-256，格式同 `sha256sum`，按文件名排序，LF 换行），`sha256sum --check` 通过后建草稿 Release，上传两个包和这份清单。同一标签的 Release 已存在时失败，不覆盖。
4. **核对草稿**：在 Actions 里手动运行 `Verify draft release`（`.github/workflows/verify-draft-release.yml`），必须从 main 触发，输入草稿 Release 的数字 ID 和完整的源提交 SHA。它会：
   - 确认检出的提交等于输入的 SHA、是 main 的祖先、工作区干净；
   - 下载草稿的全部附件，确认恰好是两个包和 `SHA256SUMS.txt`，清单与实际哈希一致；
   - Windows：解包后用 `verify-desktop-zip.py` 核对结构，跑 CLI 检查和两次冒烟（合成日志、空日志目录）；
   - macOS：解包后核对 `.app` 的 `Info.plist`、主程序、Frameworks、CLI 和许可文件，跑 CLI 检查和合成日志冒烟。

   这个工作流只读草稿，不会发布。
5. **发布**：把 `docs/releases/<版本>.md` 贴进草稿说明，检查附件，然后在 GitHub 上手动发布。

## 下载者怎么校验

`SHA256SUMS.txt` 和下载的包放在同一个文件夹（只下了一个包也可以）：

- macOS：`grep macos.zip SHA256SUMS.txt | shasum -a 256 -c`，显示 `OK`。
- Windows（PowerShell）：`Get-FileHash .\token-lens-<版本>-windows-x64.zip`，把输出和 `SHA256SUMS.txt` 里同名那一行对一下，大小写不同不要紧。

面向用户的步骤写在 [INSTALL.md](../../INSTALL.md)。

## 还没做的

- 程序没有代码签名，macOS 也没有公证；首次运行时 SmartScreen 和 Gatekeeper 会提示。
- macOS 版没有在真机上验收过。
- 没有安装程序：Windows 和 macOS 都是 zip。
