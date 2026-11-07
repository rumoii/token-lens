use super::{Error, Result};

pub fn system_timezone() -> Result<String> {
    if let Ok(zone) = std::env::var("TZ") {
        if !zone.is_empty() {
            return Ok(canonical(zone));
        }
    }
    platform_timezone().map(canonical)
}

fn canonical(zone: String) -> String {
    if matches!(
        zone.as_str(),
        "Etc/UTC" | "Etc/GMT" | "GMT" | "UCT" | "Etc/UCT"
    ) {
        "UTC".into()
    } else {
        zone
    }
}

#[cfg(any(target_os = "windows", target_os = "macos"))]
fn platform_timezone() -> Result<String> {
    #[cfg_attr(target_os = "windows", link(name = "icu"))]
    #[cfg_attr(target_os = "macos", link(name = "icucore"))]
    extern "C" {
        fn ucal_getDefaultTimeZone(result: *mut u16, capacity: i32, status: *mut i32) -> i32;
    }
    let mut output = [0_u16; 128];
    let mut status = 0;
    // ICU is provided by the target OS; output is bounded by the supplied capacity.
    let length =
        unsafe { ucal_getDefaultTimeZone(output.as_mut_ptr(), output.len() as i32, &mut status) };
    if status > 0 || length <= 0 || length as usize > output.len() {
        return Err(Error(format!("timezone: ICU error {status}")));
    }
    String::from_utf16(&output[..length as usize]).map_err(|e| Error(format!("timezone: {e}")))
}

#[cfg(not(any(target_os = "windows", target_os = "macos")))]
fn platform_timezone() -> Result<String> {
    let path = std::fs::read_link("/etc/localtime")?;
    path.to_string_lossy()
        .split_once("zoneinfo/")
        .map(|(_, zone)| zone.to_owned())
        .ok_or_else(|| Error("timezone unavailable".into()))
}
