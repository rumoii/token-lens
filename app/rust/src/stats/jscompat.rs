use chrono::{
    DateTime, Datelike, Duration, Local, LocalResult, NaiveDate, NaiveDateTime, TimeZone, Timelike,
    Utc,
};
use serde_json::Value;
use std::cmp::Ordering;

pub enum LocalZone {
    System,
    #[cfg(test)]
    Fixed(i32),
}

pub fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_some_and(|n| n != 0.0 && !n.is_nan()),
        Value::String(s) => !s.is_empty(),
        _ => true,
    }
}

pub fn string(value: &Value) -> String {
    match value {
        Value::Null => "null".into(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => number_string(n.as_f64().unwrap()),
        Value::String(s) => s.clone(),
        Value::Array(a) => a
            .iter()
            .map(|v| {
                if v.is_null() {
                    String::new()
                } else {
                    string(v)
                }
            })
            .collect::<Vec<_>>()
            .join(","),
        Value::Object(_) => "[object Object]".into(),
    }
}

/// Number(toFixed(4)) for a nonnegative ratio. Round the exact binary value;
/// Rust's decimal formatting uses a different rule at an exact halfway value.
pub fn ratio_four_places(value: f64) -> f64 {
    debug_assert!(value.is_finite() && (0.0..=1.0).contains(&value));
    let bits = value.to_bits();
    let exponent = ((bits >> 52) & 0x7ff) as i32;
    let fraction = bits & ((1_u64 << 52) - 1);
    let (mantissa, shift) = if exponent == 0 {
        (fraction, 1074)
    } else {
        (fraction | (1_u64 << 52), 1075 - exponent)
    };
    let numerator = mantissa as u128 * 10000;
    let rounded = if shift >= 128 {
        0
    } else {
        let half = 1_u128 << (shift - 1);
        (numerator >> shift) + u128::from(numerator & ((1_u128 << shift) - 1) >= half)
    };
    rounded as f64 / 10000.0
}

pub fn number_string(number: f64) -> String {
    if number == 0.0 {
        return "0".into();
    }
    if !number.is_finite() {
        return if number.is_nan() {
            "NaN".into()
        } else if number.is_sign_negative() {
            "-Infinity".into()
        } else {
            "Infinity".into()
        };
    }
    let sign = if number < 0.0 { "-" } else { "" };
    let text = number.abs().to_string();
    let point = text.find('.').unwrap_or(text.len());
    let digits: String = text.chars().filter(|c| *c != '.').collect();
    let first = digits.find(|c| c != '0').unwrap();
    let significant = digits[first..].trim_end_matches('0');
    let exponent = point as i32 - first as i32 - 1;
    if !(-6..21).contains(&exponent) {
        let fraction = if significant.len() > 1 {
            format!(".{}", &significant[1..])
        } else {
            String::new()
        };
        format!(
            "{sign}{}{fraction}e{}{exponent}",
            &significant[..1],
            if exponent >= 0 { "+" } else { "" }
        )
    } else {
        format!("{sign}{text}")
    }
}

fn iso(date: DateTime<Utc>) -> String {
    let year = date.year();
    let year = if (0..=9999).contains(&year) {
        format!("{year:04}")
    } else {
        format!("{year:+07}")
    };
    format!(
        "{year}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        date.month(),
        date.day(),
        date.hour(),
        date.minute(),
        date.second(),
        date.timestamp_subsec_millis()
    )
}

fn local_time(date: NaiveDateTime, zone: &LocalZone) -> Option<DateTime<Utc>> {
    match zone {
        #[cfg(test)]
        LocalZone::Fixed(minutes) => Some(date.and_utc() - Duration::minutes(*minutes as i64)),
        LocalZone::System => match Local.from_local_datetime(&date) {
            LocalResult::Single(date) | LocalResult::Ambiguous(date, _) => {
                Some(date.with_timezone(&Utc))
            }
            LocalResult::None => {
                // Date moves a nonexistent wall time forward by the DST gap.
                let prior = date - Duration::hours(24);
                let offset = Local
                    .from_local_datetime(&prior)
                    .earliest()?
                    .offset()
                    .local_minus_utc();
                Some(date.and_utc() - Duration::seconds(offset as i64))
            }
        },
    }
}

pub fn normalize_timestamp(raw: &Value, zone: &LocalZone) -> Option<String> {
    let millis = match raw {
        Value::Null | Value::Bool(false) => return None,
        Value::Bool(true) => Some(1.0),
        Value::Number(number) => {
            let n = number.as_f64()?;
            if n == 0.0 {
                return None;
            }
            Some(if n < 1e12 { n * 1000.0 } else { n })
        }
        _ => None,
    };
    if let Some(millis) = millis {
        if millis.abs() > 8.64e15 {
            return None;
        }
        return DateTime::from_timestamp_millis(millis.trunc() as i64).map(iso);
    }
    let text = raw.as_str()?;
    if text.is_empty() {
        return None;
    }
    if text == "0" {
        return local_time(
            NaiveDate::from_ymd_opt(2000, 1, 1)?.and_hms_opt(0, 0, 0)?,
            zone,
        )
        .map(iso);
    }
    if let Ok(date) = DateTime::parse_from_rfc3339(text) {
        return Some(iso(date.with_timezone(&Utc)));
    }
    // ISO dates permit day overflow up to 31 in Date, including the surveyed Feb 30.
    if text.len() >= 10 && text.is_ascii() && &text[4..5] == "-" && &text[7..8] == "-" {
        let year: i32 = text[..4].parse().ok()?;
        let month: u32 = text[5..7].parse().ok()?;
        let day: u32 = text[8..10].parse().ok()?;
        if !(1..=31).contains(&day) {
            return None;
        }
        let date = NaiveDate::from_ymd_opt(year, month, 1)?
            .checked_add_signed(Duration::days(day as i64 - 1))?;
        if text.len() == 10 {
            return Some(iso(date.and_hms_opt(0, 0, 0)?.and_utc()));
        }
        let mut time = text[10..].strip_prefix(['T', ' '])?.to_owned();
        let utc = time.ends_with('Z');
        if utc {
            time.pop();
        }
        let midnight = time == "24:00:00" || time == "24:00:00.000";
        let naive = if midnight {
            date.succ_opt()?.and_hms_opt(0, 0, 0)?
        } else {
            NaiveDateTime::parse_from_str(
                &format!("{}T{time}", date.format("%Y-%m-%d")),
                "%Y-%m-%dT%H:%M:%S%.f",
            )
            .ok()?
        };
        return if utc {
            Some(iso(naive.and_utc()))
        } else {
            local_time(naive, zone).map(iso)
        };
    }
    None
}

pub fn locale_compare(a: &str, b: &str) -> Ordering {
    fn weight(c: char) -> u32 {
        match c {
            ' ' => 0,
            '_' => 1,
            '-' => 2,
            ':' => 3,
            '.' => 4,
            '/' => 5,
            '\\' => 6,
            '0'..='9' => 7 + c as u32 - '0' as u32,
            'a'..='z' | 'A'..='Z' => 17 + c.to_ascii_lowercase() as u32 - 'a' as u32,
            _ => 0x100 + c as u32,
        }
    }
    a.chars()
        .map(weight)
        .cmp(b.chars().map(weight))
        .then_with(|| {
            a.chars()
                .map(|c| c.is_ascii_uppercase())
                .cmp(b.chars().map(|c| c.is_ascii_uppercase()))
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn node_jscompat_golden() {
        for line in include_str!("../../tests/golden/jscompat.jsonl").lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            match row["fn"].as_str() {
                Some("number") => assert_eq!(
                    number_string(row["value"].as_f64().unwrap()),
                    row["expected"].as_str().unwrap(),
                    "{line}"
                ),
                Some("date") => {
                    let offset = match row["tz"].as_str().unwrap() {
                        "Asia/Shanghai" => 480,
                        "America/New_York" => {
                            if row["value"]
                                .as_str()
                                .is_some_and(|s| s.starts_with("2026-10"))
                            {
                                -240
                            } else {
                                -300
                            }
                        }
                        _ => 0,
                    };
                    let actual = normalize_timestamp(&row["value"], &LocalZone::Fixed(offset));
                    assert_eq!(
                        serde_json::to_value(actual).unwrap(),
                        row["expected"],
                        "{line}"
                    );
                }
                Some("locale") => assert_eq!(
                    locale_compare(row["a"].as_str().unwrap(), row["b"].as_str().unwrap()) as i8,
                    row["expected"].as_i64().unwrap() as i8,
                    "{line}"
                ),
                _ => {}
            }
        }
    }
}
