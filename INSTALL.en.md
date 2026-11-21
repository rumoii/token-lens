# Installing Token Lens

Token Lens runs straight from the extracted folder: no installer, no administrator rights, and no Node, Python or other runtime to install. It takes two or three minutes.

[简体中文](INSTALL.md)

## Before you start

- **Windows**: Windows 10 or 11, 64-bit (x64).
- **macOS**: a Mac with Apple silicon (M1 or later), macOS 13 or later. Intel Macs are not supported yet.

## 1. Download

Open the [latest release](https://github.com/rumoii/token-lens/releases/latest) and download from Assets:

- Windows: `token-lens-<version>-windows-x64.zip`
- macOS: `token-lens-<version>-macos.zip`

### Check the download (optional)

The same page has `SHA256SUMS.txt` with the SHA-256 of each package. Save it in the same folder as the package:

- **Windows**: open PowerShell in that folder and run

  ```powershell
  Get-FileHash .\token-lens-<version>-windows-x64.zip
  ```

  The Hash should match the first part of the line for that file in `SHA256SUMS.txt` (case does not matter).
- **macOS**: open Terminal in that folder and run

  ```sh
  grep macos.zip SHA256SUMS.txt | shasum -a 256 -c
  ```

  It prints `token-lens-<version>-macos.zip: OK` when the file is intact.

## 2. Install and open

### Windows

1. Right-click the zip → "Extract All", and extract it somewhere it will stay, for example `D:\Apps\Token Lens`.
2. Open the extracted folder and double-click `token-lens.exe`.
   > Keep the exe, the DLLs and the `data` folder together; copying the exe alone does not work. First-run setup creates a desktop shortcut by default; if you move the folder later, click "Create again" under Pricing & settings → Appearance.
3. The program is not signed, so the first run may show a blue "Windows protected your PC" screen. Click "**More info**", then "**Run anyway**". You will not be asked again.

### macOS

1. Double-click the zip to extract `Token Lens.app`.
2. **Drag `Token Lens.app` into Applications first**, then open it from there.
3. The app is not signed or notarized, so macOS says it cannot verify the developer on first launch:
   1. Click "**Done**" (not "Move to Trash").
   2. Open "System Settings → Privacy & Security", find the message that Token Lens was blocked near the bottom, click "**Open Anyway**" and confirm.
   > The approval applies only to that copy of the app, which is why it goes into Applications first. Approve it again after each upgrade.

## 3. First run

1. Token Lens lists the AI coding tools it found on this computer. It has not read any log contents yet.
2. If you do not want AI news, tick "Local statistics only, no AI news" and the app will not go online for news. You can change this later in Pricing & settings.
3. Click "**Start counting**". The first pass reads all your logs, which can take a minute or two if you have many; progress shows at the top of the page.
4. Your usage appears when it finishes. From then on the app syncs every time it opens and every 5 minutes while the window is open; "Sync usage" in the sidebar syncs on demand.

Closing the window quits the app. It does not stay in the background or start at login.

## Upgrading

1. Close Token Lens.
2. Download and extract the new version as above.
3. Replace the program:
   - Windows: copy all the new files over the old folder's contents (or delete the old folder and use the new one).
   - macOS: drag the new `Token Lens.app` into Applications, choose Replace, and approve it again as in step 2.
4. Open the new version. Your usage data is not in the program folder, so replacing it loses nothing.

When a new version changes the ledger format, its first launch migrates the ledger automatically and first saves a complete copy of the old one in the data folder. After that, older versions refuse to open the upgraded ledger, so do not just switch back to an old program; if you really need to, see "运行与回退" (Running and rollback) in [app/README.md](app/README.md#运行与回退) (in Chinese).

## Where your data is

Usage, settings and the news cache are all in this folder:

- Windows: `%APPDATA%\Token Lens\Token Lens\data` (paste it into the File Explorer address bar)
- macOS: `~/Library/Application Support/io.github.rumoii.token-lens/data` (in Finder press <kbd>Shift</kbd> + <kbd>Cmd</kbd> + <kbd>G</kbd> and paste the path)

To back it up, close Token Lens and copy the whole `data` folder.

## Uninstalling

1. Close Token Lens.
2. Delete the program: the extracted folder on Windows, or `Token Lens.app` in Applications on macOS.
3. If you no longer need your data, delete the `data` folder above too. Exported diagnostics or breakdown files (`token-lens-…`) in your Downloads folder need deleting separately.

Token Lens installs no services and never changes other AI tools' files, so that removes everything.

## Common questions

**A tool I use is not listed**
Make sure the tool has actually been used on this computer and has written logs. Then open the Tools page to see which folders Token Lens looks in and whether they were found; when a folder is missing it says whether the tool is not installed or not readable. Logs stored in a non-default location cannot be read yet. Experimental tools may not match real log formats yet; reports are welcome, see the [contributing guide](CONTRIBUTING.en.md).

**The cost does not match my bill**
Costs are estimates at each model's list price, for comparison only. On a subscription plan you usually pay less.

**The app shows a startup error**
The page says what went wrong. If you need help, click "Export diagnostics" and attach the file to an [issue](https://github.com/rumoii/token-lens/issues); read it first and remove any project or file names you do not want to share.

**Double-clicking does nothing**
If Token Lens is already open, opening it again only brings the existing window to the front. Check the taskbar or Dock.
