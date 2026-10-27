//! Keys for the Halcyn account's vault, which keeps the streaming services' sign-ins
//! end-to-end encrypted. Nothing here touches the network.
//!
//! ```text
//! password ──Argon2id(email salt)──▶ master
//!    master ──subkey 1──▶ login secret   (sent to Supabase as the "password")
//!    master ──subkey 2──▶ password key   (wraps the vault key)
//! recovery key ──subkey 3──▶ recovery wrapping key (wraps it too)
//! vault key (random) ──XChaCha20-Poly1305──▶ each service's sign-in
//! ```
//!
//! Supabase only sees the login secret, which can't be turned back into the master key,
//! so the vault is ciphertext to it.

use anyhow::{anyhow, bail, Result};
use argon2::{Algorithm, Argon2, Params, Version};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use blake2::digest::consts::{U16, U32};
use blake2::digest::{Digest, Mac};
use blake2::{Blake2b, Blake2bMac};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};

pub type Key = [u8; 32];

const LOGIN: u8 = 1;
const PASSWORD: u8 = 2;
const RECOVERY: u8 = 3;
const FORMAT: &str = "v1";

/// Argon2id: 64 MiB, 3 passes. Slow on purpose, a second or so.
const MEMORY_KIB: u32 = 64 * 1024;
const PASSES: u32 = 3;

pub fn normalize_email(email: &str) -> String {
    email.trim().to_lowercase()
}

/// The master key: Argon2id of the password, salted by the email (the salt must be known
/// before signing in, since the login secret depends on it).
pub fn master_key(email: &str, password: &str) -> Result<Key> {
    let salt = Blake2b::<U16>::digest(format!("halcyn.v1.login-salt:{}", normalize_email(email)));
    let params = Params::new(MEMORY_KIB, PASSES, 1, Some(32)).map_err(|e| anyhow!("{e}"))?;
    let mut key = [0u8; 32];
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(password.as_bytes(), &salt, &mut key)
        .map_err(|e| anyhow!("{e}"))?;
    Ok(key)
}

fn subkey(root: &Key, id: u8) -> Key {
    let mut mac = <Blake2bMac<U32> as blake2::digest::KeyInit>::new_from_slice(root).expect("32-byte key");
    mac.update(format!("halcyn.v1.subkey:{id}").as_bytes());
    mac.finalize().into_bytes().into()
}

/// What Supabase gets as the password.
pub fn login_secret(master: &Key) -> String {
    URL_SAFE_NO_PAD.encode(subkey(master, LOGIN))
}

pub fn password_key(master: &Key) -> Key {
    subkey(master, PASSWORD)
}

pub fn recovery_wrapping_key(recovery: &Key) -> Key {
    subkey(recovery, RECOVERY)
}

pub fn random_key() -> Result<Key> {
    let mut key = [0u8; 32];
    getrandom::fill(&mut key).map_err(|e| anyhow!("{e}"))?;
    Ok(key)
}

/// A fingerprint of the vault key (a MAC keyed by it), so a device can tell its cached
/// key is out of date without revealing anything.
pub fn key_id(vault: &Key) -> String {
    let mut mac = <Blake2bMac<U16> as blake2::digest::KeyInit>::new_from_slice(vault).expect("32-byte key");
    mac.update(b"halcyn.v1.key-id");
    URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
}

pub fn wrap_vault_key(wrapping: &Key, vault: &Key, user: &str) -> Result<String> {
    seal(wrapping, vault, &format!("vault-key:{user}"))
}

pub fn unwrap_vault_key(wrapping: &Key, wrapped: &str, user: &str) -> Result<Key> {
    open(wrapping, wrapped, &format!("vault-key:{user}"))?
        .try_into()
        .map_err(|_| anyhow!("the vault key is the wrong length"))
}

/// The user id and service are bound in, so one service's sign-in can't be swapped onto
/// another service or account.
pub fn seal_item(vault: &Key, user: &str, service: &str, plain: &str) -> Result<String> {
    seal(vault, plain.as_bytes(), &format!("item:{user}:{service}"))
}

pub fn open_item(vault: &Key, user: &str, service: &str, sealed: &str) -> Result<String> {
    Ok(String::from_utf8(open(vault, sealed, &format!("item:{user}:{service}"))?)?)
}

fn seal(key: &Key, message: &[u8], context: &str) -> Result<String> {
    let mut nonce = [0u8; 24];
    getrandom::fill(&mut nonce).map_err(|e| anyhow!("{e}"))?;
    let sealed = XChaCha20Poly1305::new(key.into())
        .encrypt(XNonce::from_slice(&nonce), Payload { msg: message, aad: context.as_bytes() })
        .map_err(|_| anyhow!("couldn't encrypt"))?;
    Ok(format!("{FORMAT}.{}", URL_SAFE_NO_PAD.encode([&nonce[..], &sealed].concat())))
}

/// Fails with "wrong key" when the key (or the context) isn't the one it was sealed with.
fn open(key: &Key, sealed: &str, context: &str) -> Result<Vec<u8>> {
    let Some(body) = sealed.strip_prefix("v1.") else { bail!("unknown vault format") };
    let bytes = URL_SAFE_NO_PAD.decode(body)?;
    if bytes.len() < 24 + 16 {
        bail!("damaged vault data");
    }
    let (nonce, rest) = bytes.split_at(24);
    XChaCha20Poly1305::new(key.into())
        .decrypt(XNonce::from_slice(nonce), Payload { msg: rest, aad: context.as_bytes() })
        .map_err(|_| anyhow!("wrong key"))
}

// Recovery keys are Crockford base32 with a checksum byte, in groups of four, so a typo
// is reported as a typo and not as the wrong key.
const BASE32: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

pub fn format_recovery_key(key: &Key) -> String {
    let check = Blake2b::<U16>::digest(key)[0];
    let bytes = [&key[..], &[check]].concat();
    let mut text = String::new();
    let (mut buffer, mut bits) = (0u32, 0);
    for byte in bytes {
        buffer = (buffer << 8) | byte as u32;
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            text.push(BASE32[((buffer >> bits) & 31) as usize] as char);
        }
    }
    if bits > 0 {
        text.push(BASE32[((buffer << (5 - bits)) & 31) as usize] as char);
    }
    text.as_bytes().chunks(4).map(|c| std::str::from_utf8(c).unwrap()).collect::<Vec<_>>().join("-")
}

pub fn parse_recovery_key(input: &str) -> Result<Key> {
    let mut bytes = Vec::new();
    let (mut buffer, mut bits) = (0u32, 0);
    for c in input.chars().filter(|c| !c.is_whitespace() && *c != '-') {
        let c = match c.to_ascii_uppercase() {
            'O' => '0',
            'I' | 'L' => '1',
            c => c,
        };
        let Some(value) = BASE32.iter().position(|&b| b as char == c) else {
            bail!("That recovery key has a letter that isn't in recovery keys.");
        };
        buffer = (buffer << 5) | value as u32;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            bytes.push((buffer >> bits) as u8);
        }
    }
    if bytes.len() != 33 {
        bail!("That recovery key is the wrong length.");
    }
    let key: Key = bytes[..32].try_into()?;
    if Blake2b::<U16>::digest(key)[0] != bytes[32] {
        bail!("That recovery key has a typo in it.");
    }
    Ok(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_vault_opens_with_the_password_or_the_recovery_key_only() {
        let master = master_key(" Me@Example.com ", "correct horse").unwrap();
        // The same email however it's typed; another password, another key.
        assert_eq!(master, master_key("me@example.com", "correct horse").unwrap());
        assert_ne!(master, master_key("me@example.com", "wrong horse").unwrap());
        assert_ne!(login_secret(&master), URL_SAFE_NO_PAD.encode(password_key(&master)));

        let vault = random_key().unwrap();
        let by_password = wrap_vault_key(&password_key(&master), &vault, "user-1").unwrap();
        let recovery = random_key().unwrap();
        let by_recovery = wrap_vault_key(&recovery_wrapping_key(&recovery), &vault, "user-1").unwrap();
        assert_eq!(unwrap_vault_key(&password_key(&master), &by_password, "user-1").unwrap(), vault);
        let typed = format_recovery_key(&recovery).to_lowercase().replace('0', "o");
        let parsed = parse_recovery_key(&typed).unwrap();
        assert_eq!(unwrap_vault_key(&recovery_wrapping_key(&parsed), &by_recovery, "user-1").unwrap(), vault);
        // Another account's wrapping, or another password, doesn't open.
        assert!(unwrap_vault_key(&password_key(&master), &by_password, "user-2").is_err());
        let other = master_key("me@example.com", "wrong horse").unwrap();
        assert!(unwrap_vault_key(&password_key(&other), &by_password, "user-1").is_err());

        let sealed = seal_item(&vault, "user-1", "tidal", "{\"token\":1}").unwrap();
        assert_eq!(open_item(&vault, "user-1", "tidal", &sealed).unwrap(), "{\"token\":1}");
        assert!(open_item(&vault, "user-1", "ytm", &sealed).is_err());
        assert_eq!(key_id(&vault), key_id(&vault));
        assert_ne!(key_id(&vault), key_id(&recovery));
    }

    #[test]
    fn a_mistyped_recovery_key_is_called_a_typo() {
        let key = random_key().unwrap();
        let text = format_recovery_key(&key);
        assert_eq!(text.split('-').count(), 14);
        let mut typo: Vec<char> = text.chars().collect();
        typo[0] = if typo[0] == 'A' { 'B' } else { 'A' };
        let typo: String = typo.into_iter().collect();
        assert!(parse_recovery_key(&typo).unwrap_err().to_string().contains("typo"));
        assert!(parse_recovery_key("ABCD").unwrap_err().to_string().contains("length"));
    }
}
