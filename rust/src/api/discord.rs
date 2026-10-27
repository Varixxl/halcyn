//! Discord Rich Presence (see `crate::discord`).

/// Shows `activity` (Discord's activity object, as JSON) on the user's Discord profile, or
/// with None clears it. Returns at once; Discord hears about it in the background.
#[flutter_rust_bridge::frb(sync)]
pub fn discord_set(app_id: String, activity: Option<String>) {
    crate::discord::set(app_id, activity);
}

/// "" before the first try, "on" while Discord shows it, or why it doesn't.
#[flutter_rust_bridge::frb(sync)]
pub fn discord_status() -> String {
    crate::discord::status()
}
