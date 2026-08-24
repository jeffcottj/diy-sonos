use anyhow::{anyhow, Context};
use std::path::Path;

pub fn ensure_app_keypair(app_data_dir: &Path) -> Result<(), anyhow::Error> {
    let priv_path = app_data_dir.join("id_ed25519");
    let pub_path = app_data_dir.join("id_ed25519.pub");

    if priv_path.exists() && pub_path.exists() {
        return Ok(());
    }

    std::fs::create_dir_all(app_data_dir).context("create app_data_dir")?;

    // Use ssh-key crate to generate ed25519 keypair
    let private_key =
        ssh_key::PrivateKey::random(&mut rand::rngs::OsRng, ssh_key::Algorithm::Ed25519)
            .map_err(|e| anyhow!("generate ed25519 key: {}", e))?;

    let pubkey = private_key.public_key().clone();

    // Write private key with 0600
    let priv_pem = private_key
        .to_openssh(ssh_key::LineEnding::LF)
        .map_err(|e| anyhow!("encode private key: {}", e))?;
    std::fs::write(&priv_path, priv_pem.as_bytes()).context("write private key")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&priv_path)?.permissions();
        perms.set_mode(0o600);
        std::fs::set_permissions(&priv_path, perms)?;
    }

    let pub_str = format!(
        "{} diy-sonos@desktop\n",
        pubkey
            .to_openssh()
            .map_err(|e| anyhow!("encode pubkey: {}", e))?
    );
    std::fs::write(&pub_path, pub_str).context("write pubkey")?;
    Ok(())
}

pub fn load_app_pubkey_string(app_data_dir: &Path) -> Result<String, anyhow::Error> {
    let pub_path = app_data_dir.join("id_ed25519.pub");
    let content = std::fs::read_to_string(&pub_path)
        .with_context(|| format!("read pubkey at {:?}", pub_path))?;
    Ok(content.trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generates_keypair_and_loads() {
        let dir = tempfile::tempdir().unwrap();
        ensure_app_keypair(dir.path()).unwrap();
        assert!(dir.path().join("id_ed25519").exists());
        assert!(dir.path().join("id_ed25519.pub").exists());
        let pubkey = load_app_pubkey_string(dir.path()).unwrap();
        assert!(pubkey.starts_with("ssh-ed25519 "));
        // Idempotent second call
        ensure_app_keypair(dir.path()).unwrap();
    }

    #[test]
    fn pubkey_permissions() {
        let dir = tempfile::tempdir().unwrap();
        ensure_app_keypair(dir.path()).unwrap();
        let pubkey = load_app_pubkey_string(dir.path()).unwrap();
        assert!(!pubkey.is_empty());
    }
}
