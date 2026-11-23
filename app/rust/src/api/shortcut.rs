pub fn desktop_shortcut_exists() -> bool {
    #[cfg(windows)]
    {
        native::path(false).is_ok_and(|path| path.is_file())
    }
    #[cfg(not(windows))]
    false
}

pub fn create_desktop_shortcut() -> Result<(), String> {
    #[cfg(windows)]
    {
        native::create()
    }
    #[cfg(not(windows))]
    Err("Desktop shortcuts are only supported on Windows".into())
}

#[cfg(windows)]
mod native {
    use std::ffi::{OsStr, OsString};
    use std::os::windows::ffi::{OsStrExt, OsStringExt};
    use std::path::PathBuf;
    use windows::core::{w, Interface, PCWSTR};
    use windows::Win32::Foundation::RPC_E_CHANGED_MODE;
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, IPersistFile,
        CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED,
    };
    use windows::Win32::UI::Shell::{
        FOLDERID_Desktop, IShellLinkW, SHChangeNotify, SHGetKnownFolderPath, ShellLink,
        KF_FLAG_DEFAULT, SHCNE_CREATE, SHCNE_ID, SHCNE_UPDATEITEM, SHCNF_PATHW,
    };

    fn shortcut_event(existed: bool) -> SHCNE_ID {
        if existed {
            SHCNE_UPDATEITEM
        } else {
            SHCNE_CREATE
        }
    }

    #[cfg(test)]
    #[test]
    fn selects_shell_events_for_create_and_replace() {
        assert_eq!(
            (shortcut_event(false), shortcut_event(true)),
            (SHCNE_CREATE, SHCNE_UPDATEITEM)
        );
    }

    pub(super) fn path(create: bool) -> Result<PathBuf, String> {
        let desktop = if let Some(home) = std::env::var_os("TOKEN_LENS_PREVIEW_HOME") {
            let home = PathBuf::from(home);
            if !home.is_absolute() {
                return Err("Preview home must be absolute".into());
            }
            let desktop = home.join("Desktop");
            if create {
                std::fs::create_dir_all(&desktop)
                    .map_err(|error| format!("Create preview Desktop: {error}"))?;
            }
            let resolved = desktop.canonicalize().map_err(|error| error.to_string())?;
            let home = home.canonicalize().map_err(|error| error.to_string())?;
            if !resolved.starts_with(&home) || resolved == home {
                return Err("Preview Desktop is outside the preview home".into());
            }
            desktop
        } else {
            // The shell resolves redirected desktops and allocates a UTF-16 buffer.
            unsafe {
                let path = SHGetKnownFolderPath(&FOLDERID_Desktop, KF_FLAG_DEFAULT, None)
                    .map_err(|error| format!("Resolve Windows Desktop: {error}"))?;
                let desktop = PathBuf::from(OsString::from_wide(path.as_wide()));
                CoTaskMemFree(Some(path.0.cast()));
                desktop
            }
        };
        Ok(desktop.join("Token Lens.lnk"))
    }

    fn wide(path: &OsStr) -> Vec<u16> {
        path.encode_wide().chain(std::iter::once(0)).collect()
    }

    pub(super) fn create() -> Result<(), String> {
        let destination = path(true)?;
        let executable =
            std::env::current_exe().map_err(|error| format!("Locate executable: {error}"))?;
        let directory = executable
            .parent()
            .ok_or("Executable has no parent directory")?;
        let executable = wide(executable.as_os_str());
        let working_dir = wide(directory.as_os_str());
        let temporary = tempfile::Builder::new()
            .suffix(".lnk")
            .tempfile_in(destination.parent().expect("desktop link has a parent"))
            .map_err(|error| format!("Create temporary shortcut: {error}"))?
            .into_temp_path();
        let save_path = wide(temporary.as_os_str());

        struct Apartment(bool);
        impl Drop for Apartment {
            fn drop(&mut self) {
                if self.0 {
                    unsafe { CoUninitialize() };
                }
            }
        }
        let result = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
        if result != RPC_E_CHANGED_MODE {
            result
                .ok()
                .map_err(|error| format!("Initialize COM: {error}"))?;
        }
        let _apartment = Apartment(result.is_ok());
        let save = || -> windows::core::Result<()> {
            // Each PCWSTR points to a null-terminated buffer that lives through the call.
            unsafe {
                let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
                let executable = PCWSTR(executable.as_ptr());
                link.SetPath(executable)?;
                link.SetWorkingDirectory(PCWSTR(working_dir.as_ptr()))?;
                link.SetIconLocation(executable, 0)?;
                link.SetDescription(w!("Token Lens"))?;
                link.cast::<IPersistFile>()?
                    .Save(PCWSTR(save_path.as_ptr()), false)
            }
        };
        let event = shortcut_event(destination.exists());
        save().map_err(|error| format!("Save Windows Shell link: {error}"))?;
        temporary
            .persist(&destination)
            .map_err(|error| format!("Replace desktop shortcut: {error}"))?;
        let destination = wide(destination.as_os_str());
        // SHCNF_PATHW expects a null-terminated UTF-16 path for the affected item.
        unsafe { SHChangeNotify(event, SHCNF_PATHW, Some(destination.as_ptr().cast()), None) };
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(windows)]
    #[test]
    fn creates_and_overwrites_only_in_preview_desktop() {
        let home = tempfile::tempdir().unwrap();
        let previous = std::env::var_os("TOKEN_LENS_PREVIEW_HOME");
        struct Restore(Option<std::ffi::OsString>);
        impl Drop for Restore {
            fn drop(&mut self) {
                if let Some(previous) = self.0.take() {
                    std::env::set_var("TOKEN_LENS_PREVIEW_HOME", previous);
                } else {
                    std::env::remove_var("TOKEN_LENS_PREVIEW_HOME");
                }
            }
        }
        let _restore = Restore(previous);
        std::env::set_var("TOKEN_LENS_PREVIEW_HOME", home.path());
        let shortcut = home.path().join("Desktop/Token Lens.lnk");
        assert!(!desktop_shortcut_exists());
        assert!(!shortcut.parent().unwrap().exists());
        create_desktop_shortcut().unwrap();
        assert!(desktop_shortcut_exists());
        let created = std::fs::read(&shortcut).unwrap();
        assert_eq!(&created[..4], &[0x4c, 0, 0, 0]);
        std::fs::write(&shortcut, b"old shortcut").unwrap();
        create_desktop_shortcut().unwrap();
        assert_eq!(&std::fs::read(shortcut).unwrap()[..4], &[0x4c, 0, 0, 0]);
    }

    #[cfg(not(windows))]
    #[test]
    fn shortcuts_are_unsupported() {
        assert!(!desktop_shortcut_exists());
        assert!(create_desktop_shortcut().unwrap_err().contains("Windows"));
    }
}
