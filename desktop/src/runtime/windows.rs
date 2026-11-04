use std::{
    ffi::{OsStr, OsString},
    fs::File,
    io::{self, Read},
    os::windows::{
        ffi::OsStrExt,
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
    },
    path::Path,
    ptr::{null, null_mut},
};
pub use crate::payload::runtime_root;
use windows_sys::Win32::{
    Foundation::{GetLastError, HANDLE, HANDLE_FLAG_INHERIT, SetHandleInformation},
    Security::SECURITY_ATTRIBUTES,
    System::{
        JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
            SetInformationJobObject,
        },
        Pipes::CreatePipe,
        Threading::{
            CREATE_NO_WINDOW, CREATE_SUSPENDED, CreateMutexW, CreateProcessW, GetExitCodeProcess,
            PROCESS_INFORMATION, ResumeThread, STARTF_USESTDHANDLES, STARTUPINFOW,
            TerminateProcess, WaitForSingleObject,
        },
    },
    UI::{
        Shell::ShellExecuteW,
        WindowsAndMessaging::{
            FindWindowW, MB_ICONERROR, MessageBoxW, SW_RESTORE, SW_SHOWNORMAL, SetForegroundWindow,
            ShowWindow,
        },
    },
};

pub fn wide(value: impl AsRef<OsStr>) -> Vec<u16> {
    value.as_ref().encode_wide().chain(Some(0)).collect()
}

fn owned(handle: HANDLE) -> io::Result<OwnedHandle> {
    if handle.is_null() {
        Err(io::Error::last_os_error())
    } else {
        Ok(unsafe { OwnedHandle::from_raw_handle(handle) })
    }
}

// 互斥量覆盖解压、启动和整个窗口生命周期，所有版本共享一个实例。
pub fn single_instance() -> io::Result<Option<OwnedHandle>> {
    let name = wide("Local\\TokenLens.Desktop.v1");
    let handle = unsafe { CreateMutexW(null(), 0, name.as_ptr()) };
    let error = unsafe { GetLastError() };
    let mutex = owned(handle)?;
    if error != windows_sys::Win32::Foundation::ERROR_ALREADY_EXISTS {
        return Ok(Some(mutex));
    }
    let title = wide("Token Lens");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        let window = unsafe { FindWindowW(null(), title.as_ptr()) };
        if !window.is_null() {
            unsafe {
                ShowWindow(window, SW_RESTORE);
                SetForegroundWindow(window);
            }
            break;
        }
        if std::time::Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    drop(mutex);
    Ok(None)
}

pub fn show_error(message: &str) {
    unsafe {
        MessageBoxW(
            null_mut(),
            wide(message).as_ptr(),
            wide("Token Lens").as_ptr(),
            MB_ICONERROR,
        );
    }
}

pub fn open_external(url: &str) {
    // 只把 Web 链接交给 ShellExecute，不允许网页启动任意本地文件或协议处理器。
    if url.starts_with("https://") || url.starts_with("http://") {
        unsafe {
            ShellExecuteW(
                null_mut(),
                wide("open").as_ptr(),
                wide(url).as_ptr(),
                null(),
                null(),
                SW_SHOWNORMAL,
            );
        }
    }
}

/// 持有 Job 句柄；释放即结束内核（KILL_ON_JOB_CLOSE）。
pub type Guard = OwnedHandle;

pub struct Process(OwnedHandle);

impl Process {
    /// 等待至多 `ms` 毫秒；内核已退出时返回退出码。
    pub fn wait(&self, ms: u32) -> Option<String> {
        if unsafe { WaitForSingleObject(self.0.as_raw_handle(), ms) } != 0 {
            return None;
        }
        let mut code = 0;
        unsafe {
            GetExitCodeProcess(self.0.as_raw_handle(), &mut code);
        }
        Some(code.to_string())
    }

    pub fn terminate(&self) {
        unsafe {
            TerminateProcess(self.0.as_raw_handle(), 1);
        }
    }
}

pub struct Kernel {
    pub guard: Guard,
    pub process: Process,
    pub pid: u32,
    pub stdout: Box<dyn Read + Send>,
    pub stderr: Box<dyn Read + Send>,
}

/// Windows 窗口自带编辑快捷键，不需要应用菜单。
pub fn install_menu() {}

fn pipe() -> io::Result<(File, OwnedHandle)> {
    let attributes = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: null_mut(),
        bInheritHandle: 1,
    };
    let (mut read, mut write) = (null_mut(), null_mut());
    if unsafe { CreatePipe(&mut read, &mut write, &attributes, 0) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let read = owned(read)?;
    let write = owned(write)?;
    if unsafe { SetHandleInformation(read.as_raw_handle(), HANDLE_FLAG_INHERIT, 0) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok((File::from(read), write))
}

pub fn start_kernel(root: &Path, data: &Path) -> io::Result<Kernel> {
    if data.as_os_str().encode_wide().any(|c| c == b'"' as u16) {
        return Err(io::Error::other("数据目录不能包含双引号"));
    }
    let job = owned(unsafe { CreateJobObjectW(null(), null()) })?;
    let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if unsafe {
        SetInformationJobObject(
            job.as_raw_handle(),
            JobObjectExtendedLimitInformation,
            &limits as *const _ as _,
            size_of_val(&limits) as u32,
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    let (stdout, out_write) = pipe()?;
    let (stderr, err_write) = pipe()?;
    let (stdin, in_write) = pipe()?;
    // stdin 的读端只在此处显式继承；写端在创建后关闭，让 Node 读到 EOF。
    if unsafe {
        SetHandleInformation(
            stdin.as_raw_handle(),
            HANDLE_FLAG_INHERIT,
            HANDLE_FLAG_INHERIT,
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    if unsafe { SetHandleInformation(in_write.as_raw_handle(), HANDLE_FLAG_INHERIT, 0) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let node = root.join("node.exe");
    let mut command = OsString::from("\"");
    command.push(&node);
    command.push("\" \"");
    command.push(root.join("bin/lens.js"));
    command.push("\" serve --port 3456 --strict-port --desktop-logs --data-dir \"");
    // Windows 路径不能含双引号；结尾反斜杠在引号前必须翻倍。
    command.push(data);
    if data.as_os_str().encode_wide().last() == Some(b'\\' as u16) {
        command.push("\\");
    }
    command.push("\"");
    let mut command = wide(command);
    let mut startup: STARTUPINFOW = unsafe { std::mem::zeroed() };
    startup.cb = size_of::<STARTUPINFOW>() as u32;
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdOutput = out_write.as_raw_handle();
    startup.hStdError = err_write.as_raw_handle();
    startup.hStdInput = stdin.as_raw_handle();
    let mut info: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
    if unsafe {
        CreateProcessW(
            wide(&node).as_ptr(),
            command.as_mut_ptr(),
            null(),
            null(),
            1,
            CREATE_NO_WINDOW | CREATE_SUSPENDED,
            null(),
            wide(root).as_ptr(),
            &startup,
            &mut info,
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    let process = owned(info.hProcess)?;
    let thread = owned(info.hThread)?;
    // 挂入 Job 之前不执行 Node，任何失败都终止仍挂起的进程。
    if unsafe { AssignProcessToJobObject(job.as_raw_handle(), process.as_raw_handle()) } == 0 {
        let error = io::Error::last_os_error();
        unsafe {
            TerminateProcess(process.as_raw_handle(), 1);
        }
        return Err(error);
    }
    if unsafe { ResumeThread(thread.as_raw_handle()) } == u32::MAX {
        return Err(io::Error::last_os_error());
    }
    Ok(Kernel {
        guard: job,
        process: Process(process),
        pid: info.dwProcessId,
        stdout: Box::new(stdout),
        stderr: Box::new(stderr),
    })
}
