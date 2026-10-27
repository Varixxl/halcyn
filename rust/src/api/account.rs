//! The Halcyn account's keys (see `crate::account`). Keys cross to Dart as base64 so the
//! app can keep the unlocked vault key in the system's keystore between runs.

use anyhow::{anyhow, Result};
use base64::engine::general_purpose::STANDARD;
use base64::Engine;

use crate::account::{self, Key};

pub struct AccountKeys {
    /// What Supabase gets as the password.
    pub login_secret: String,
    /// Wraps the vault key. Never leaves the device.
    pub password_key: String,
}

pub struct NewVault {
    pub vault_key: String,
    pub key_by_password: String,
    pub key_by_recovery: String,
    pub key_id: String,
    /// Shown to the user once, to write down.
    pub recovery_key: String,
}

fn key(text: &str) -> Result<Key> {
    STANDARD.decode(text)?.try_into().map_err(|_| anyhow!("a key is the wrong length"))
}

fn text(key: &Key) -> String {
    STANDARD.encode(key)
}

/// Argon2id of the password (a second or so, on purpose).
pub fn account_derive(email: String, password: String) -> Result<AccountKeys> {
    let master = account::master_key(&email, &password)?;
    Ok(AccountKeys {
        login_secret: account::login_secret(&master),
        password_key: text(&account::password_key(&master)),
    })
}

/// A new account's vault: a random key, wrapped by the password and by a recovery key.
pub fn account_new_vault(password_key: String, user_id: String) -> Result<NewVault> {
    let vault = account::random_key()?;
    let recovery = account::random_key()?;
    Ok(NewVault {
        key_by_password: account::wrap_vault_key(&key(&password_key)?, &vault, &user_id)?,
        key_by_recovery: account::wrap_vault_key(
            &account::recovery_wrapping_key(&recovery),
            &vault,
            &user_id,
        )?,
        key_id: account::key_id(&vault),
        recovery_key: account::format_recovery_key(&recovery),
        vault_key: text(&vault),
    })
}

/// The vault key, unwrapped with the password key. Fails with "wrong key".
pub fn account_unwrap(password_key: String, wrapped: String, user_id: String) -> Result<String> {
    Ok(text(&account::unwrap_vault_key(&key(&password_key)?, &wrapped, &user_id)?))
}

/// The vault key, unwrapped with the recovery key as the user typed it.
pub fn account_unwrap_with_recovery(recovery_key: String, wrapped: String, user_id: String) -> Result<String> {
    let recovery = account::parse_recovery_key(&recovery_key)?;
    let vault = account::unwrap_vault_key(&account::recovery_wrapping_key(&recovery), &wrapped, &user_id)
        .map_err(|_| anyhow!("That recovery key isn't this account's."))?;
    Ok(text(&vault))
}

/// The vault key wrapped by a (new) password key.
pub fn account_wrap(password_key: String, vault_key: String, user_id: String) -> Result<String> {
    account::wrap_vault_key(&key(&password_key)?, &key(&vault_key)?, &user_id)
}

#[flutter_rust_bridge::frb(sync)]
pub fn account_key_id(vault_key: String) -> Result<String> {
    Ok(account::key_id(&key(&vault_key)?))
}

#[flutter_rust_bridge::frb(sync)]
pub fn account_seal(vault_key: String, user_id: String, service: String, plain: String) -> Result<String> {
    account::seal_item(&key(&vault_key)?, &user_id, &service, &plain)
}

#[flutter_rust_bridge::frb(sync)]
pub fn account_open(vault_key: String, user_id: String, service: String, sealed: String) -> Result<String> {
    account::open_item(&key(&vault_key)?, &user_id, &service, &sealed)
}
