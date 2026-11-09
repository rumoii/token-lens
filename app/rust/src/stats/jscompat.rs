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

/// ECMAScript WhiteSpace and LineTerminator (also the character class used by /\s/).
pub fn whitespace(c: char) -> bool {
    matches!(c, '\u{0009}'..='\u{000d}' | '\u{0020}' | '\u{00a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}')
}

pub fn trim(text: &str) -> &str {
    text.trim_matches(whitespace)
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

/// JSON.parse values retain UTF-16 strings (including lone surrogates) and key order.
#[derive(Clone, Debug)]
pub enum JsJson {
    Null,
    Bool(bool),
    Number(f64),
    String(Vec<u16>),
    Array(Vec<JsJson>),
    Object(Vec<(Vec<u16>, JsJson)>),
}

impl JsJson {
    pub fn values(&self) -> Vec<&Self> {
        match self {
            Self::Array(a) => a.iter().collect(),
            Self::Object(o) => o.iter().map(|(_, v)| v).collect(),
            _ => Vec::new(),
        }
    }
    pub fn get(&self, key: &str) -> &Self {
        match self {
            Self::Object(o) => o
                .iter()
                .find(|(k, _)| k.iter().copied().eq(key.encode_utf16()))
                .map_or(&Self::Null, |(_, v)| v),
            _ => &Self::Null,
        }
    }
    pub fn to_value(&self) -> Value {
        match self {
            Self::Null => Value::Null,
            Self::Bool(b) => Value::Bool(*b),
            Self::Number(n) => serde_json::json!(n),
            Self::String(s) => Value::String(String::from_utf16_lossy(s)),
            Self::Array(a) => Value::Array(a.iter().map(Self::to_value).collect()),
            Self::Object(o) => Value::Object(
                o.iter()
                    .map(|(k, v)| (String::from_utf16_lossy(k), v.to_value()))
                    .collect(),
            ),
        }
    }

    pub fn parse(text: &str) -> Result<Self, String> {
        struct Parser<'a> {
            text: &'a str,
            pos: usize,
        }
        impl Parser<'_> {
            fn ws(&mut self) {
                while self
                    .text
                    .as_bytes()
                    .get(self.pos)
                    .is_some_and(|b| matches!(b, b' ' | b'\r' | b'\n' | b'\t'))
                {
                    self.pos += 1;
                }
            }
            fn take(&mut self, b: u8) -> bool {
                self.ws();
                if self.text.as_bytes().get(self.pos) == Some(&b) {
                    self.pos += 1;
                    true
                } else {
                    false
                }
            }
            fn string(&mut self) -> Result<Vec<u16>, String> {
                if !self.take(b'"') {
                    return Err("expected string".into());
                }
                let mut out = Vec::new();
                while let Some(&b) = self.text.as_bytes().get(self.pos) {
                    self.pos += 1;
                    match b {
                        b'"' => return Ok(out),
                        b'\\' => {
                            let escape =
                                *self.text.as_bytes().get(self.pos).ok_or("short escape")?;
                            self.pos += 1;
                            out.push(match escape {
                                b'"' => 34,
                                b'\\' => 92,
                                b'/' => 47,
                                b'b' => 8,
                                b'f' => 12,
                                b'n' => 10,
                                b'r' => 13,
                                b't' => 9,
                                b'u' => {
                                    let hex = self
                                        .text
                                        .get(self.pos..self.pos + 4)
                                        .ok_or("short unicode")?;
                                    if !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
                                        return Err("invalid unicode".into());
                                    }
                                    self.pos += 4;
                                    u16::from_str_radix(hex, 16).map_err(|e| e.to_string())?
                                }
                                _ => return Err("invalid escape".into()),
                            });
                        }
                        0..=31 => return Err("control character".into()),
                        _ => {
                            self.pos -= 1;
                            let c = self.text[self.pos..].chars().next().unwrap();
                            self.pos += c.len_utf8();
                            out.extend(c.encode_utf16(&mut [0; 2]).iter().copied());
                        }
                    }
                }
                Err("unterminated string".into())
            }
            fn value(&mut self) -> Result<JsJson, String> {
                self.ws();
                match self.text.as_bytes().get(self.pos) {
                    Some(b'"') => Ok(JsJson::String(self.string()?)),
                    Some(b'{') => {
                        self.pos += 1;
                        let mut entries: Vec<(Vec<u16>, JsJson)> = Vec::new();
                        if !self.take(b'}') {
                            loop {
                                let key = self.string()?;
                                if !self.take(b':') {
                                    return Err("expected colon".into());
                                }
                                let value = self.value()?;
                                if let Some((_, old)) = entries.iter_mut().find(|(k, _)| *k == key)
                                {
                                    *old = value;
                                } else {
                                    entries.push((key, value));
                                }
                                if self.take(b'}') {
                                    break;
                                }
                                if !self.take(b',') {
                                    return Err("expected comma".into());
                                }
                            }
                        }
                        fn index(key: &[u16]) -> Option<u32> {
                            let s = String::from_utf16(key).ok()?;
                            let n = s.parse::<u32>().ok()?;
                            (n < u32::MAX && n.to_string() == s).then_some(n)
                        }
                        entries.sort_by(|(a, _), (b, _)| match (index(a), index(b)) {
                            (Some(a), Some(b)) => a.cmp(&b),
                            (Some(_), None) => Ordering::Less,
                            (None, Some(_)) => Ordering::Greater,
                            _ => Ordering::Equal,
                        });
                        Ok(JsJson::Object(entries))
                    }
                    Some(b'[') => {
                        self.pos += 1;
                        let mut entries = Vec::new();
                        if !self.take(b']') {
                            loop {
                                entries.push(self.value()?);
                                if self.take(b']') {
                                    break;
                                }
                                if !self.take(b',') {
                                    return Err("expected comma".into());
                                }
                            }
                        }
                        Ok(JsJson::Array(entries))
                    }
                    _ => {
                        let start = self.pos;
                        while self.text.as_bytes().get(self.pos).is_some_and(|b| {
                            !matches!(b, b' ' | b'\r' | b'\n' | b'\t' | b',' | b']' | b'}')
                        }) {
                            self.pos += 1;
                        }
                        let word = &self.text[start..self.pos];
                        match word {
                            "null" => Ok(JsJson::Null),
                            "true" => Ok(JsJson::Bool(true)),
                            "false" => Ok(JsJson::Bool(false)),
                            _ => {
                                // Validate JSON number grammar separately: JSON.parse permits overflow to Infinity.
                                let bytes = word.as_bytes();
                                let mut i = usize::from(bytes.first() == Some(&b'-'));
                                match bytes.get(i) {
                                    Some(b'0') => i += 1,
                                    Some(b'1'..=b'9') => {
                                        i += 1;
                                        while bytes.get(i).is_some_and(u8::is_ascii_digit) {
                                            i += 1;
                                        }
                                    }
                                    _ => return Err("invalid number".into()),
                                }
                                if bytes.get(i) == Some(&b'.') {
                                    i += 1;
                                    let first = i;
                                    while bytes.get(i).is_some_and(u8::is_ascii_digit) {
                                        i += 1;
                                    }
                                    if first == i {
                                        return Err("invalid fraction".into());
                                    }
                                }
                                if matches!(bytes.get(i), Some(b'e' | b'E')) {
                                    i += 1;
                                    if matches!(bytes.get(i), Some(b'+' | b'-')) {
                                        i += 1;
                                    }
                                    let first = i;
                                    while bytes.get(i).is_some_and(u8::is_ascii_digit) {
                                        i += 1;
                                    }
                                    if first == i {
                                        return Err("invalid exponent".into());
                                    }
                                }
                                if i != bytes.len() {
                                    return Err("invalid number suffix".into());
                                }
                                Ok(JsJson::Number(
                                    word.parse::<f64>().map_err(|e| e.to_string())?,
                                ))
                            }
                        }
                    }
                }
            }
        }
        let mut parser = Parser { text, pos: 0 };
        let value = parser.value()?;
        parser.ws();
        if parser.pos != text.len() {
            return Err("trailing JSON".into());
        }
        Ok(value)
    }
    pub fn stringify(&self) -> String {
        fn quoted(units: &[u16]) -> String {
            let mut out = String::from("\"");
            for c in char::decode_utf16(units.iter().copied()) {
                match c {
                    Err(e) => out.push_str(&format!("\\u{:04x}", e.unpaired_surrogate())),
                    Ok(c) => match c {
                        '"' => out.push_str("\\\""),
                        '\\' => out.push_str("\\\\"),
                        '\n' => out.push_str("\\n"),
                        '\r' => out.push_str("\\r"),
                        '\t' => out.push_str("\\t"),
                        '\u{8}' => out.push_str("\\b"),
                        '\u{c}' => out.push_str("\\f"),
                        '\0'..='\u{1f}' => out.push_str(&format!("\\u{:04x}", c as u32)),
                        _ => out.push(c),
                    },
                }
            }
            out.push('"');
            out
        }
        match self {
            Self::Null => "null".into(),
            Self::Bool(b) => b.to_string(),
            Self::Number(n) => {
                if n.is_finite() {
                    number_string(*n)
                } else {
                    "null".into()
                }
            }
            Self::String(s) => quoted(s),
            Self::Array(a) => format!(
                "[{}]",
                a.iter().map(Self::stringify).collect::<Vec<_>>().join(",")
            ),
            Self::Object(o) => format!(
                "{{{}}}",
                o.iter()
                    .map(|(k, v)| format!("{}:{}", quoted(k), v.stringify()))
                    .collect::<Vec<_>>()
                    .join(",")
            ),
        }
    }
}

pub fn encode_uri_component(units: &[u16]) -> Result<String, String> {
    let text = String::from_utf16(units).map_err(|_| "URIError: URI malformed".to_owned())?;
    let mut out = String::new();
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    Ok(out)
}

#[cfg(test)]
mod b2_tests {
    use super::*;
    #[test]
    fn node_jscompat_b2() {
        for line in include_str!("../../tests/golden/jscompat-b2.jsonl").lines() {
            let row: Value = serde_json::from_str(line).unwrap();
            if row["fn"] == "json" {
                assert_eq!(
                    JsJson::parse(row["input"].as_str().unwrap())
                        .unwrap()
                        .stringify(),
                    row["expected"].as_str().unwrap(),
                    "{line}"
                );
            } else {
                let units: Vec<u16> = row["units"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|v| v.as_u64().unwrap() as u16)
                    .collect();
                let actual = encode_uri_component(&units);
                if row["error"] == true {
                    assert!(actual.is_err(), "{line}");
                } else {
                    assert_eq!(actual.unwrap(), row["expected"].as_str().unwrap(), "{line}");
                }
            }
        }
    }
}
pub fn encode_cursor(offset: u64) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let text = offset.to_string();
    let mut result = String::new();
    for chunk in text.as_bytes().chunks(3) {
        let bits = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for i in 0..4 {
            result.push(if i > chunk.len() {
                '='
            } else {
                ALPHABET[((bits >> (18 - 6 * i)) & 63) as usize] as char
            });
        }
    }
    result
}

pub fn decode_cursor(cursor: Option<&str>) -> u64 {
    let mut decoded = Vec::new();
    let (mut bits, mut buffer) = (0, 0u32);
    for byte in cursor.unwrap_or("").bytes().take_while(|c| *c != b'=') {
        let digit = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            _ => continue,
        };
        buffer = (buffer << 6) | u32::from(digit);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            decoded.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    // Approved D33 difference: Number-only forms (hex, exponent, surrounding
    // whitespace) are invalid; only a nonnegative ASCII decimal integer is used.
    if decoded.is_empty() || !decoded.iter().all(u8::is_ascii_digit) {
        return 0;
    }
    std::str::from_utf8(&decoded)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

#[cfg(test)]
mod d33_cursor_tests {
    use super::*;
    #[test]
    fn d33_cursor_node_permissiveness_and_approved_exceptions() {
        for n in [0, 1, 50, 9007199254740991] {
            assert_eq!(decode_cursor(Some(&encode_cursor(n))), n);
        }
        assert_eq!(encode_cursor(50), "NTA=");
        assert_eq!(decode_cursor(Some("N!T@A")), 50);
        for value in [
            "", "LTE=", "MS41", "YWJj", "MHgxMA==", "MWUz", "IDUwIA==", "-___",
        ] {
            assert_eq!(decode_cursor(Some(value)), 0, "{value}");
        }
        assert_eq!(decode_cursor(None), 0);
    }
}
