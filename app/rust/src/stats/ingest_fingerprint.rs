use super::{adapters, LocalZone, Revisions};
use serde::Serialize;
use std::{collections::BTreeMap, fs, io, path::Path, time::UNIX_EPOCH};

const FORMAT: u32 = 1;

#[derive(Serialize)]
struct FileState {
    size: u64,
    mtime_ns: i128,
    directory: bool,
}

fn state(path: &Path) -> io::Result<Option<FileState>> {
    let metadata = match fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let mtime = metadata.modified()?;
    let mtime_ns = match mtime.duration_since(UNIX_EPOCH) {
        Ok(since) => since.as_nanos() as i128,
        Err(before) => -(before.duration().as_nanos() as i128),
    };
    Ok(Some(FileState {
        size: metadata.len(),
        mtime_ns,
        directory: metadata.is_dir(),
    }))
}

pub(super) fn fingerprint(
    source: &str,
    path: &Path,
    zone: Option<&str>,
    revisions: Revisions,
) -> Option<String> {
    let zone = zone?;
    path.to_str()?;
    let main = state(path).ok()??;
    if main.directory {
        return None;
    }
    let mut inputs = BTreeMap::new();
    if let Some(sidecar) = adapters::sidecar(source, path) {
        inputs.insert(sidecar.to_str()?.to_owned(), state(&sidecar).ok()?);
    }
    if source == "openhands" {
        let directory = adapters::openhands_events(path);
        match fs::read_dir(directory) {
            Ok(entries) => {
                for entry in entries {
                    let entry = entry.ok()?;
                    let name = entry.file_name();
                    let name = name.to_str()?;
                    if adapters::openhands_event_name(name) {
                        inputs.insert(name.to_owned(), state(&entry.path()).ok()?);
                    }
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(_) => return None,
        }
    }
    serde_json::to_string(&(
        FORMAT,
        revisions.usage,
        revisions.timing,
        zone,
        main,
        inputs,
    ))
    .ok()
}

pub(super) fn zone_identity(zone: &LocalZone) -> Option<String> {
    match zone {
        #[cfg(test)]
        LocalZone::Fixed(offset) => Some(format!("fixed:{offset}")),
        LocalZone::System => system_zone_identity(),
    }
}

#[cfg(windows)]
fn system_zone_identity() -> Option<String> {
    #[repr(C)]
    struct DynamicTimeZoneInformation {
        bias: i32,
        standard_name: [u16; 32],
        standard_date: [u16; 8],
        standard_bias: i32,
        daylight_name: [u16; 32],
        daylight_date: [u16; 8],
        daylight_bias: i32,
        key_name: [u16; 128],
        dynamic_daylight_disabled: u8,
    }

    #[link(name = "kernel32")]
    extern "system" {
        fn GetDynamicTimeZoneInformation(info: *mut DynamicTimeZoneInformation) -> u32;
    }

    let mut info = std::mem::MaybeUninit::<DynamicTimeZoneInformation>::zeroed();
    // The successful Windows call initializes the time zone and DST settings.
    let status = unsafe { GetDynamicTimeZoneInformation(info.as_mut_ptr()) };
    if status == u32::MAX {
        return None;
    }
    let info = unsafe { info.assume_init() };
    Some(format!(
        "windows:{}:{}:{}:{}:{}:{}:{:?}:{:?}:{}",
        windows_wide_string(&info.key_name),
        windows_wide_string(&info.standard_name),
        windows_wide_string(&info.daylight_name),
        info.bias,
        info.standard_bias,
        info.daylight_bias,
        info.standard_date,
        info.daylight_date,
        info.dynamic_daylight_disabled,
    ))
}

#[cfg(windows)]
fn windows_wide_string(value: &[u16]) -> String {
    let end = value
        .iter()
        .position(|&unit| unit == 0)
        .unwrap_or(value.len());
    String::from_utf16_lossy(&value[..end])
}

#[cfg(all(windows, test))]
#[test]
fn ignores_windows_buffer_contents_after_first_nul() {
    assert_eq!(windows_wide_string(&[b'A'.into(), 0, b'B'.into()]), "A");
}

#[cfg(not(windows))]
fn system_zone_identity() -> Option<String> {
    let zone = crate::stats::timezone::system_timezone().ok()?;
    let rules = state(Path::new("/etc/localtime")).ok()?;
    serde_json::to_string(&("system", zone, rules)).ok()
}
