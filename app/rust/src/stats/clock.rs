use chrono::{DateTime, Utc};

#[derive(Clone)]
pub enum Clock {
    System,
    Fixed(i64),
}

impl Clock {
    pub fn millis(&self) -> i64 {
        match self {
            Self::System => Utc::now().timestamp_millis(),
            Self::Fixed(time) => *time,
        }
    }

    pub fn iso(&self) -> String {
        DateTime::from_timestamp_millis(self.millis())
            .unwrap()
            .to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
    }
}
