//! The services' HTTP: one agent for everything, with Halcyn's own User-Agent.

use std::io::Read;
use std::sync::LazyLock;
use std::time::Duration;

use anyhow::{anyhow, Result};
use serde_json::Value;

pub static AGENT: LazyLock<ureq::Agent> = LazyLock::new(|| {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(15))
        .timeout_read(Duration::from_secs(30))
        .user_agent(concat!("Halcyn/", env!("CARGO_PKG_VERSION")))
        .build()
});

/// An HTTP status other than 2xx, with what the service said.
#[derive(Debug)]
pub struct Status {
    pub code: u16,
    pub body: String,
}

impl std::fmt::Display for Status {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let said: String = self.body.chars().take(300).collect();
        write!(f, "HTTP {}: {said}", self.code)
    }
}

impl std::error::Error for Status {}

/// Sends `request` (with an optional form or JSON body) and reads a JSON answer.
pub fn json(request: ureq::Request, body: Option<Body>) -> Result<Value> {
    let response = match body {
        None => request.call(),
        Some(Body::Form(form)) => {
            let pairs: Vec<(&str, &str)> =
                form.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
            request.send_form(&pairs)
        }
        Some(Body::Json(value)) => {
            request.set("Content-Type", "application/json").send_string(&value.to_string())
        }
    };
    match response {
        Ok(r) => {
            let text = r.into_string()?;
            Ok(if text.trim().is_empty() { Value::Null } else { serde_json::from_str(&text)? })
        }
        Err(ureq::Error::Status(code, r)) => {
            Err(Status { code, body: r.into_string().unwrap_or_default() }.into())
        }
        Err(e) => Err(anyhow!("{e}")),
    }
}

pub enum Body {
    Form(Vec<(String, String)>),
    Json(Value),
}

/// A GET's body as a stream, and its length if the server said.
pub fn get_reader(url: &str) -> Result<(Box<dyn Read + Send + Sync>, Option<u64>)> {
    let mut last = None;
    // The CDN sometimes drops a connection; try a couple more times.
    for attempt in 0..3 {
        if attempt > 0 {
            std::thread::sleep(Duration::from_millis(500 * attempt));
        }
        match AGENT.get(url).call() {
            Ok(r) => {
                let len = r.header("Content-Length").and_then(|l| l.parse().ok());
                return Ok((Box::new(r.into_reader()), len));
            }
            Err(ureq::Error::Status(code, r)) if code < 500 => {
                return Err(Status { code, body: r.into_string().unwrap_or_default() }.into());
            }
            Err(e) => last = Some(e),
        }
    }
    Err(anyhow!("couldn't download: {}", last.map_or_else(String::new, |e| e.to_string())))
}

/// Shorthands for reading JSON answers.
pub trait Get {
    fn s(&self, key: &str) -> Option<String>;
    fn n(&self, key: &str) -> Option<f64>;
    fn list(&self, key: &str) -> Vec<Value>;
}

impl Get for Value {
    fn s(&self, key: &str) -> Option<String> {
        match &self[key] {
            Value::String(s) if !s.is_empty() => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            _ => None,
        }
    }

    fn n(&self, key: &str) -> Option<f64> {
        match &self[key] {
            Value::Number(n) => n.as_f64(),
            Value::String(s) => s.parse().ok(),
            _ => None,
        }
    }

    fn list(&self, key: &str) -> Vec<Value> {
        self[key].as_array().cloned().unwrap_or_default()
    }
}
