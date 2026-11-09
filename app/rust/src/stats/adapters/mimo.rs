use super::super::{jscompat::LocalZone, Result};
use serde_json::Value;
use std::path::Path;
pub(super) fn parse(
    identity: &str,
    file: &Path,
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let mut records = super::opencode::parse(identity, file, "mimo", zone, notes)?;
    for record in &mut records {
        record.as_object_mut().unwrap().remove("timestamp");
    }
    Ok(records)
}
