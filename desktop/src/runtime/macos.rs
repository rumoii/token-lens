use objc2::{MainThreadMarker, MainThreadOnly, sel};
use objc2_app_kit::{NSApplication, NSMenu, NSMenuItem};
use objc2_foundation::{NSString, ns_string};
use std::{
    fs::{self, File},
    io::{self, Read},
    os::unix::process::ExitStatusExt,
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

fn invalid(reason: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, reason)
}

fn exe_dir() -> io::Result<PathBuf> {
    let exe = std::env::current_exe()?;
    Ok(exe
        .parent()
        .ok_or_else(|| invalid("无法定位应用目录"))?
        .to_owned())
}

/// .app 布局：Contents/MacOS/{token-lens,node}，内核与前端在 Contents/Resources/app。
pub fn runtime_root() -> io::Result<PathBuf> {
    let macos = exe_dir()?;
    let incomplete = || invalid("应用包不完整，请从 dmg 重新拖入「应用程序」");
    let root = macos
        .join("../Resources/app")
        .canonicalize()
        .map_err(|_| incomplete())?;
    let complete = macos.join("node").is_file()
        && [
            "bin/lens.js",
            "src/core/cli.js",
            "src/core/server.js",
            "src/core/package.json",
            "dashboard/dist/index.html",
            "package.json",
        ]
        .iter()
        .all(|file| root.join(file).is_file());
    if !complete {
        return Err(incomplete());
    }
    Ok(root)
}

// 双击已运行的 .app 时 LaunchServices 会激活已有实例；此锁挡住直接运行二进制等其余情况。
pub fn single_instance() -> io::Result<Option<File>> {
    let home = std::env::var_os("HOME").ok_or_else(|| io::Error::other("HOME 未设置"))?;
    let base = PathBuf::from(home).join("Library/Application Support/token-lens-app");
    fs::create_dir_all(&base)?;
    let file = File::options()
        .create(true)
        .truncate(false)
        .write(true)
        .open(base.join("instance.lock"))?;
    match file.try_lock() {
        Ok(()) => Ok(Some(file)),
        Err(fs::TryLockError::WouldBlock) => Ok(None),
        Err(fs::TryLockError::Error(error)) => Err(error),
    }
}

pub fn show_error(message: &str) {
    // 消息经 argv 传入，不拼进脚本。
    let _ = Command::new("/usr/bin/osascript")
        .args([
            "-e",
            "on run argv",
            "-e",
            "display alert \"Token Lens\" message (item 1 of argv) as critical",
            "-e",
            "end run",
        ])
        .arg(message)
        .status();
}

pub fn open_external(url: &str) {
    // 只把 Web 链接交给 open，不允许网页启动任意本地文件或协议处理器。
    if url.starts_with("https://") || url.starts_with("http://") {
        let url = url.to_owned();
        std::thread::spawn(move || {
            let _ = Command::new("/usr/bin/open").arg(url).status();
        });
    }
}

/// 应用菜单：没有「编辑」菜单时 WKWebView 不响应 ⌘C/⌘V。
pub fn install_menu() {
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    let item = |title: &NSString, action, key: &NSString| unsafe {
        NSMenuItem::initWithTitle_action_keyEquivalent(NSMenuItem::alloc(mtm), title, action, key)
    };
    let submenu = |title: &NSString, items: &[(&NSString, objc2::runtime::Sel, &NSString)]| {
        let menu = NSMenu::initWithTitle(NSMenu::alloc(mtm), title);
        for (name, action, key) in items {
            menu.addItem(&item(name, Some(*action), key));
        }
        let holder = NSMenuItem::new(mtm);
        holder.setSubmenu(Some(&menu));
        holder
    };
    let bar = NSMenu::new(mtm);
    bar.addItem(&submenu(
        ns_string!("Token Lens"),
        &[(ns_string!("退出 Token Lens"), sel!(terminate:), ns_string!("q"))],
    ));
    bar.addItem(&submenu(
        ns_string!("编辑"),
        &[
            (ns_string!("撤销"), sel!(undo:), ns_string!("z")),
            (ns_string!("重做"), sel!(redo:), ns_string!("Z")),
            (ns_string!("剪切"), sel!(cut:), ns_string!("x")),
            (ns_string!("拷贝"), sel!(copy:), ns_string!("c")),
            (ns_string!("粘贴"), sel!(paste:), ns_string!("v")),
            (ns_string!("全选"), sel!(selectAll:), ns_string!("a")),
        ],
    ));
    NSApplication::sharedApplication(mtm).setMainMenu(Some(&bar));
}

/// 持有 stdin 写端与子进程：释放时关闭管道并结束内核。壳被强杀时由内核读到 EOF 自行退出。
pub struct Guard {
    stdin: Option<ChildStdin>,
    child: Arc<Mutex<Child>>,
}

impl Drop for Guard {
    fn drop(&mut self) {
        drop(self.stdin.take());
        let mut child = self.child.lock().unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while child.try_wait().ok().flatten().is_none() {
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

pub struct Process(Arc<Mutex<Child>>);

impl Process {
    /// 等待至多 `ms` 毫秒；内核已退出时返回退出码或信号。
    pub fn wait(&self, ms: u32) -> Option<String> {
        let deadline = Instant::now() + Duration::from_millis(ms.into());
        loop {
            if let Ok(Some(status)) = self.0.lock().unwrap().try_wait() {
                return Some(match status.code() {
                    Some(code) => code.to_string(),
                    None => format!("signal {}", status.signal().unwrap_or(0)),
                });
            }
            if Instant::now() >= deadline {
                return None;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    pub fn terminate(&self) {
        let _ = self.0.lock().unwrap().kill();
    }
}

pub struct Kernel {
    pub guard: Guard,
    pub process: Process,
    pub pid: u32,
    pub stdout: Box<dyn Read + Send>,
    pub stderr: Box<dyn Read + Send>,
}

pub fn start_kernel(root: &Path, data: &Path) -> io::Result<Kernel> {
    let mut child = Command::new(exe_dir()?.join("node"))
        .arg(root.join("bin/lens.js"))
        .args([
            "serve",
            "--port",
            "3456",
            "--strict-port",
            "--desktop-logs",
            "--exit-on-stdin-end",
            "--data-dir",
        ])
        .arg(data)
        .current_dir(root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let pid = child.id();
    let stdin = child.stdin.take();
    let stdout = Box::new(child.stdout.take().unwrap());
    let stderr = Box::new(child.stderr.take().unwrap());
    let child = Arc::new(Mutex::new(child));
    Ok(Kernel {
        guard: Guard {
            stdin,
            child: child.clone(),
        },
        process: Process(child),
        pid,
        stdout,
        stderr,
    })
}
