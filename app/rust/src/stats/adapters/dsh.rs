use super::super::{
    jscompat::{self, LocalZone},
    Result,
};
use super::{lines::*, num::*};
use serde_json::{json, Value};
use std::path::Path;

use super::project::project;
pub(super) fn parse(
    identity: &str,
    _file: &Path,
    bytes: &[u8],
    zone: &LocalZone,
    notes: &mut Value,
) -> Result<Vec<Value>> {
    let data = json(bytes)?;
    let rows = &data["record"]["rows"];
    let totals = &rows["tokenUsage"]["val"]["totals"];
    if !jscompat::truthy(totals) {
        return Ok(vec![]);
    }
    let tokens = [
        token_of(totals, &["uncachedInputTokens", "inputTokens"], notes),
        token_of(totals, &["outputTokens"], notes),
        token_of(totals, &["cacheReadTokens"], notes),
        token_of(totals, &["cacheWriteTokens"], notes),
    ];
    if empty(&tokens, notes) {
        return Ok(vec![]);
    }
    let name = basename(identity)
        .strip_suffix(".json")
        .unwrap_or(basename(identity));
    let session = name.strip_prefix("session-").unwrap_or(name).to_owned();
    let model = rows["modelSelection"]["val"]["lastUsed"]["model"]
        .as_str()
        .filter(|s| !trim(s).is_empty())
        .map(str::to_owned);
    let time = jscompat::normalize_timestamp(&data["record"]["identity"]["createdAt"], zone);
    let ended = jscompat::normalize_timestamp(&rows["timeContext"]["val"]["lastMessageTime"], zone)
        .filter(|end| time.as_ref().is_some_and(|start| end >= start));
    let mut r = event(
        "dsh",
        format!("dsh|{session}"),
        session.clone(),
        model,
        time,
        tokens,
    );
    r["session_id"] = json!(session);
    r["kind"] = json!("cumulative");
    r["ended_at"] = json!(ended);
    r["project_key"] = json!(project(&data["record"]["identity"]["cwd"])
        .or_else(|| project(&rows["workingDirectory"]["val"])));
    Ok(vec![r])
}
