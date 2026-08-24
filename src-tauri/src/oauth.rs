use regex::Regex;
use std::path::Path;

/// Check if credentials are cached in `cache_dir` — mirrors `has_cached_credentials` in librespot-auth-helper.sh:34-38
/// Checks glob `<cache_dir>/*credentials*` or `*.json` over SSH (here via local path for tests, remote via SSH in production).
pub fn has_cached_credentials_local(cache_dir: &Path) -> bool {
    if !cache_dir.exists() {
        return false;
    }
    if let Ok(entries) = std::fs::read_dir(cache_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.contains("credentials") || name.ends_with(".json") {
                return true;
            }
        }
    }
    false
}

/// Extract latest OAuth URL from journal output — mirrors `latest_oauth_url` helper line 28-32.
pub fn extract_oauth_url(journal_output: &str) -> Option<String> {
    let re = Regex::new(r"https://accounts\.spotify\.com/[^ ]+").unwrap();
    // Find all matches, return last (tail -n 1)
    let mut last: Option<String> = None;
    for m in re.find_iter(journal_output) {
        last = Some(m.as_str().to_string());
    }
    last
}

/// Build the SSH command to restart librespot and poll for OAuth URL.
/// This is the shape; actual execution is via `ssh::exec_sudo`.
pub fn librespot_restart_command() -> String {
    "systemctl restart librespot.service".to_string()
}

pub fn journal_poll_command() -> String {
    "journalctl -u librespot --no-pager -n 400 2>/dev/null | grep -Eo 'https://accounts\\.spotify\\.com/[^ ]+' | tail -n 1".to_string()
}

pub fn credentials_glob_command(cache_dir: &str) -> String {
    format!(
        "ls {}/{{*credentials*,*.json}} 2>/dev/null | head -n 1",
        cache_dir.trim_end_matches('/')
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn oauth_url_extraction() {
        let log = r#"Jan 01 00:00:00 librespot[123]: INFO librespot: Please visit https://accounts.spotify.com/authorize?client_id=abc&scope=user-read and log in
Jan 01 00:00:01 librespot[123]: another line https://accounts.spotify.com/authorize?client_id=def tail"#;
        let url = extract_oauth_url(log).unwrap();
        assert!(url.contains("accounts.spotify.com"));
        // Should be last one (def)
        assert!(url.contains("def"));
        assert!(extract_oauth_url("no url here").is_none());
    }

    #[test]
    fn has_cached_credentials_local_detects() {
        let dir = tempdir().unwrap();
        assert!(!has_cached_credentials_local(dir.path()));
        std::fs::write(dir.path().join("credentials.json"), "{}").unwrap();
        assert!(has_cached_credentials_local(dir.path()));
        std::fs::remove_file(dir.path().join("credentials.json")).unwrap();
        std::fs::write(dir.path().join("mycredentials"), "x").unwrap();
        assert!(has_cached_credentials_local(dir.path()));
    }

    #[test]
    fn journal_command_contains_regex() {
        let cmd = journal_poll_command();
        assert!(cmd.contains("accounts\\.spotify\\.com"));
        assert!(cmd.contains("journalctl -u librespot"));
    }
}
