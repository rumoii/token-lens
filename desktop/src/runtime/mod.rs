use std::{io, path::PathBuf};

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub use macos::*;
#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use windows::*;

// 与 src/core/paths.js 的默认目录一致：TOKEN_LENS_DATA_DIR、DB_PATH，否则 <家目录>/.token-lens。
pub fn data_dir() -> io::Result<PathBuf> {
    let home = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    let directory =
        if let Some(path) = std::env::var_os("TOKEN_LENS_DATA_DIR").filter(|p| !p.is_empty()) {
            PathBuf::from(path)
        } else if let Some(path) = std::env::var_os("DB_PATH").filter(|p| !p.is_empty()) {
            std::path::absolute(path)?
                .parent()
                .ok_or_else(|| io::Error::other("DB_PATH 缺少父目录"))?
                .to_owned()
        } else {
            PathBuf::from(
                std::env::var_os(home)
                    .ok_or_else(|| io::Error::other(format!("{home} 未设置，无法解析数据目录")))?,
            )
            .join(".token-lens")
        };
    std::path::absolute(directory)
}
