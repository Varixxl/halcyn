//! The plugin host's side of the bridge: Flutter subscribes to [plugin_requests] once,
//! answers each request with [plugin_reply], and drives plugins with the rest.

use std::sync::{Arc, Mutex};

use anyhow::Result;

use crate::frb_generated::StreamSink;
use crate::plugins;

/// Something a plugin asks for. `call` is 0 when it wants no answer.
pub struct PluginRequest {
    pub plugin: String,
    pub call: u32,
    pub method: String,
    /// JSON.
    pub args: String,
}

static REQUESTS: Mutex<Option<StreamSink<PluginRequest>>> = Mutex::new(None);

pub fn plugin_requests(sink: StreamSink<PluginRequest>) {
    *REQUESTS.lock().unwrap() = Some(sink);
}

/// Runs the plugin's source, replacing a running copy. Fails on a syntax error or a
/// throw at the top level.
pub fn plugin_start(id: String, source: String) -> Result<()> {
    plugins::start(
        &id,
        &source,
        Arc::new(|r: plugins::Request| {
            if let Some(sink) = REQUESTS.lock().unwrap().as_ref() {
                let _ = sink.add(PluginRequest {
                    plugin: r.plugin,
                    call: r.call,
                    method: r.method,
                    args: r.args,
                });
            }
        }),
    )
}

#[flutter_rust_bridge::frb(sync)]
pub fn plugin_stop(id: String) {
    plugins::stop(&id);
}

/// Answers request `call`: `json` is the result, or the reason when `ok` is false.
#[flutter_rust_bridge::frb(sync)]
pub fn plugin_reply(id: String, call: u32, ok: bool, json: String) -> Result<()> {
    plugins::reply(&id, call, ok, json)
}

#[flutter_rust_bridge::frb(sync)]
pub fn plugin_emit(id: String, event: String, json: String) -> Result<()> {
    plugins::emit(&id, event, json)
}

/// Calls the plugin's handler number `callback` with `json`; its result arrives as a
/// `__return` request carrying `reply`.
#[flutter_rust_bridge::frb(sync)]
pub fn plugin_invoke(id: String, callback: u32, json: String, reply: u32) -> Result<()> {
    plugins::invoke(&id, callback, json, reply)
}
