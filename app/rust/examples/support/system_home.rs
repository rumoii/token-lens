use std::path::PathBuf;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

// Match PowerShell's native UserProfile even after the SDK changes HOME/USERPROFILE.
#[cfg(windows)]
pub(super) fn system_home() -> Result<PathBuf> {
    use std::{ffi::OsString, os::windows::ffi::OsStringExt};
    #[repr(C)]
    struct Guid(u32, u16, u16, [u8; 8]);
    #[link(name = "shell32")]
    extern "system" {
        fn SHGetKnownFolderPath(
            id: *const Guid,
            flags: u32,
            token: isize,
            path: *mut *mut u16,
        ) -> i32;
    }
    #[link(name = "ole32")]
    extern "system" {
        fn CoTaskMemFree(memory: *mut std::ffi::c_void);
    }
    let profile = Guid(
        0x5e6c858f,
        0x0e22,
        0x4760,
        [0x9a, 0xfe, 0xea, 0x33, 0x17, 0xb6, 0x71, 0x73],
    );
    let mut pointer = std::ptr::null_mut();
    // KF_FLAG_DONT_VERIFY avoids touching the protected user directory.
    unsafe {
        let status = SHGetKnownFolderPath(&profile, 0x4000, 0, &mut pointer);
        if status < 0 || pointer.is_null() {
            if !pointer.is_null() {
                CoTaskMemFree(pointer.cast());
            }
            return Err("native user profile unavailable".into());
        }
        let mut len = 0;
        while *pointer.add(len) != 0 {
            len += 1;
        }
        let home = PathBuf::from(OsString::from_wide(std::slice::from_raw_parts(
            pointer, len,
        )));
        CoTaskMemFree(pointer.cast());
        Ok(home)
    }
}

#[cfg(not(windows))]
pub(super) fn system_home() -> Result<PathBuf> {
    Ok(PathBuf::from(
        std::env::var_os("HOME").ok_or("system home missing")?,
    ))
}
