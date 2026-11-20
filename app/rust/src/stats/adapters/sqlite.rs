use super::super::{jscompat, Error, Result};
use rusqlite::{types::ValueRef, Connection, OpenFlags};
use serde_json::{json, Map, Value};
use std::collections::HashSet;
use std::path::Path;

pub(super) fn open(path: &Path) -> Result<Connection> {
    let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    db.execute_batch("PRAGMA busy_timeout = 3000; PRAGMA query_only = ON")?;
    Ok(db)
}

fn value(raw: ValueRef<'_>, notes: &mut Value) -> Result<Value> {
    Ok(match raw {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(n) => {
            // node:sqlite rejects every selected INTEGER outside this range, including unused columns.
            if !(-9007199254740991..=9007199254740991).contains(&n) {
                return Err(Error(
                    "SQLite INTEGER exceeds Number.MAX_SAFE_INTEGER".into(),
                ));
            }
            json!(n)
        }
        ValueRef::Real(n) if n.is_finite() => {
            if n.fract() == 0.0 && n.abs() <= 9007199254740991.0 {
                json!(n as i64)
            } else {
                json!(n)
            }
        }
        ValueRef::Real(_) => {
            // Approved anomalous-input difference: Infinity becomes NULL with a diagnostic.
            super::lines::note(notes, "bad_fields");
            Value::Null
        }
        ValueRef::Text(bytes) => json!(String::from_utf8_lossy(bytes)),
        ValueRef::Blob(bytes) => json!(bytes),
    })
}

pub(super) fn query(
    db: &Connection,
    sql: &str,
    params: &[Value],
    notes: &mut Value,
) -> Result<Vec<Value>> {
    query_limit(db, sql, params, notes, false)
}

pub(super) fn get(
    db: &Connection,
    sql: &str,
    params: &[Value],
    notes: &mut Value,
) -> Result<Option<Value>> {
    Ok(query_limit(db, sql, params, notes, true)?
        .into_iter()
        .next())
}

fn query_limit(
    db: &Connection,
    sql: &str,
    params: &[Value],
    notes: &mut Value,
    first: bool,
) -> Result<Vec<Value>> {
    let params = params
        .iter()
        .map(|v| match v {
            Value::String(s) => rusqlite::types::Value::Text(s.clone()),
            Value::Number(n) => rusqlite::types::Value::Real(n.as_f64().unwrap()),
            Value::Array(bytes) => rusqlite::types::Value::Blob(
                bytes
                    .iter()
                    .map(|b| b.as_u64().unwrap_or(0) as u8)
                    .collect(),
            ),
            _ => rusqlite::types::Value::Null,
        })
        .collect::<Vec<_>>();
    let mut statement = db.prepare(sql)?;
    let names = statement
        .column_names()
        .into_iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    let mut rows = statement.query(rusqlite::params_from_iter(params))?;
    let mut out = Vec::new();
    while let Some(row) = rows.next()? {
        let mut object = Map::new();
        for (index, name) in names.iter().enumerate() {
            object.insert(name.clone(), value(row.get_ref(index)?, notes)?);
        }
        out.push(Value::Object(object));
        if first {
            break;
        }
    }
    Ok(out)
}

pub(super) fn json_parse(value: Option<&Value>) -> Result<Value> {
    let text = value
        .map(jscompat::string)
        .unwrap_or_else(|| "undefined".into());
    jscompat::JsJson::parse(&text)
        .map(|v| v.to_value())
        .map_err(Error)
}

pub(super) fn columns(db: &Connection, table: &str, notes: &mut Value) -> Result<HashSet<String>> {
    Ok(
        query(db, &format!("PRAGMA table_info({table})"), &[], notes)?
            .iter()
            .filter_map(|r| r["name"].as_str().map(str::to_owned))
            .collect(),
    )
}

pub(super) fn table_exists(db: &Connection, table: &str, notes: &mut Value) -> Result<bool> {
    Ok(get(
        db,
        "SELECT count(*) AS cnt FROM sqlite_master WHERE type='table' AND name=?",
        &[json!(table)],
        notes,
    )?
    .is_some_and(|r| r["cnt"].as_i64().unwrap_or(0) > 0))
}

pub(super) fn directory_query(
    db: &Connection,
    table: &str,
    id: &str,
    column: &str,
    notes: &mut Value,
) -> Result<Option<String>> {
    let cols = columns(db, table, notes)?;
    if !cols.contains(id) || !cols.contains(column) {
        return Ok(None);
    }
    let sql = format!("SELECT {column} FROM {table} WHERE {id} = ?");
    db.prepare(&sql)?;
    Ok(Some(sql))
}

pub(super) fn directory(
    db: &Connection,
    sql: &Option<String>,
    id: &Value,
    column: &str,
    notes: &mut Value,
) -> Result<Option<String>> {
    let Some(sql) = sql else {
        return Ok(None);
    };
    let row = get(db, sql, std::slice::from_ref(id), notes)?.unwrap_or(Value::Null);
    Ok(super::project::project(&row[column]))
}

#[cfg(test)]
pub(super) fn materialize(root: &Path, setup: &Value) -> Vec<Connection> {
    let file = root.join(setup["file"].as_str().unwrap());
    assert!(file.starts_with(root));
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let mut writers = Vec::new();
    let kind = setup["kind"].as_str().unwrap();
    match kind {
        "missing" => {}
        "empty" => std::fs::write(&file, []).unwrap(),
        "garbage" => std::fs::write(&file, vec![0x5a; 1024]).unwrap(),
        "open-error" => std::fs::create_dir(&file).unwrap(),
        "csv" | "csv-crlf" => {
            let mut bytes = std::fs::read(crate::stats::golden_fixture(
                setup["input"].as_str().unwrap(),
            ))
            .unwrap();
            if kind == "csv-crlf" {
                bytes = String::from_utf8(bytes)
                    .unwrap()
                    .replace('\n', "\r\n")
                    .into_bytes();
            }
            std::fs::write(&file, bytes).unwrap();
        }
        "wal-live" | "wal-leftover" => {
            let path = if kind == "wal-live" {
                file.clone()
            } else {
                root.join("writers")
                    .join(setup["source"].as_str().unwrap())
                    .join("source.db")
            };
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            let writer = Connection::open(&path).unwrap();
            writer
                .execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
                .unwrap();
            writer
                .execute_batch(
                    &std::fs::read_to_string(crate::stats::golden_fixture(
                        setup["seed"].as_str().unwrap(),
                    ))
                    .unwrap(),
                )
                .unwrap();
            if kind == "wal-leftover" {
                std::fs::copy(&path, &file).unwrap();
                std::fs::copy(
                    format!("{}-wal", path.display()),
                    format!("{}-wal", file.display()),
                )
                .unwrap();
            }
            writers.push(writer);
        }
        "seed" | "missing-table" => {
            let db = Connection::open(&file).unwrap();
            let sql = if kind == "missing-table" {
                "CREATE TABLE unrelated (id)".into()
            } else {
                std::fs::read_to_string(crate::stats::golden_fixture(
                    setup["seed"].as_str().unwrap(),
                ))
                .unwrap()
            };
            db.execute_batch(&sql).unwrap();
        }
        _ => panic!("unknown setup kind: {kind}"),
    }
    for sibling in setup["siblings"].as_array().into_iter().flatten() {
        let mut sibling = sibling.clone();
        sibling["source"] = setup["source"].clone();
        sibling["file"] = json!(Path::new(setup["file"].as_str().unwrap())
            .parent()
            .unwrap()
            .join(sibling["file"].as_str().unwrap())
            .to_string_lossy());
        writers.extend(materialize(root, &sibling));
    }
    writers
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sqlite_node_values_b3() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(if cfg!(windows) {
            "literal#.db"
        } else {
            "literal?#.db"
        });
        let writer = Connection::open(&path).unwrap();
        writer.execute_batch("CREATE TABLE t (n, r, s, b, nil); INSERT INTO t VALUES (12,12.0,CAST(X'61ff' AS TEXT),X'0102',NULL)").unwrap();
        let db = open(&path).unwrap();
        let rows = query(&db, "SELECT * FROM t", &[], &mut json!({})).unwrap();
        assert_eq!(
            rows,
            vec![json!({"n":12,"r":12,"s":"a\u{fffd}","b":[1,2],"nil":null})]
        );
        assert!(rows[0].get("missing").is_none());
        assert_eq!(json_parse(rows[0].get("nil")).unwrap(), Value::Null);
        assert_eq!(json_parse(rows[0].get("r")).unwrap().as_f64(), Some(12.0));
        assert!(json_parse(rows[0].get("missing")).is_err());
        assert!(json_parse(rows[0].get("b")).is_err());
        assert!(db.execute_batch("DELETE FROM t").is_err());
        writer
            .execute_batch("INSERT INTO t (n) VALUES (9007199254740993)")
            .unwrap();
        assert!(query(&db, "SELECT * FROM t", &[], &mut json!({})).is_err());
        let row = get(
            &db,
            "SELECT typeof(?) AS kind",
            &[json!(12)],
            &mut json!({}),
        )
        .unwrap()
        .unwrap();
        assert_eq!(row["kind"], "real");
        let mut notes = json!({});
        assert_eq!(
            get(&db, "SELECT 1e999 AS n", &[], &mut notes)
                .unwrap()
                .unwrap()["n"],
            Value::Null
        );
        assert_eq!(notes["bad_fields"], 1);
        let version: String = db
            .query_row("select sqlite_version()", [], |r| r.get(0))
            .unwrap();
        println!("rusqlite bundled SQLite: {version}");
    }
}
