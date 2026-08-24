use regex::Regex;
use std::collections::HashMap;

/// Render a template string by replacing `{{VAR}}` placeholders with values from `vars`.
/// `VAR` must match `[A-Z0-9_]+`. Missing key returns a hard error, same as
/// `render_template_if_changed` in `scripts/common.sh:668-705`.
pub fn render_template(template: &str, vars: &HashMap<String, String>) -> Result<String, String> {
    let re = Regex::new(r"\{\{([A-Z0-9_]+)\}\}").unwrap();
    let mut missing: Option<String> = None;
    let result = re.replace_all(template, |caps: &regex::Captures| {
        let var = &caps[1];
        if let Some(val) = vars.get(var) {
            val.clone()
        } else {
            if missing.is_none() {
                missing = Some(var.to_string());
            }
            caps[0].to_string()
        }
    });
    if let Some(var) = missing {
        return Err(format!(
            "Template variable not found in environment: {}",
            var
        ));
    }
    Ok(result.into_owned())
}

/// Convenience: build the vars dict from an AppConfig for the known templates.
/// Mirrors the env exports that `parse_config` creates: flattened uppercased keys with `__`.
pub fn vars_from_config(
    cfg: &crate::config::AppConfig,
    resolved_audio_device: &str,
) -> HashMap<String, String> {
    let mut m = HashMap::new();
    // Top-level
    m.insert("SERVER_IP".to_string(), cfg.server_ip.clone());
    // Spotify
    m.insert(
        "SPOTIFY__DEVICE_NAME".to_string(),
        cfg.spotify.device_name.clone(),
    );
    m.insert(
        "SPOTIFY__DEVICE_TYPE".to_string(),
        cfg.spotify.device_type.clone(),
    );
    m.insert(
        "SPOTIFY__BITRATE".to_string(),
        cfg.spotify.bitrate.to_string(),
    );
    m.insert(
        "SPOTIFY__INITIAL_VOLUME".to_string(),
        cfg.spotify.initial_volume.to_string(),
    );
    let normalise_flag = if cfg.spotify.normalise {
        "--enable-volume-normalisation".to_string()
    } else {
        String::new()
    };
    m.insert("SPOTIFY__NORMALISE_FLAG".to_string(), normalise_flag);
    m.insert(
        "SPOTIFY__CACHE_DIR".to_string(),
        cfg.spotify.cache_dir.clone(),
    );
    m.insert(
        "SPOTIFY__OAUTH_CALLBACK_PORT".to_string(),
        cfg.spotify.oauth_callback_port.to_string(),
    );
    // Snapserver
    m.insert(
        "SNAPSERVER__FIFO_PATH".to_string(),
        cfg.snapserver.fifo_path.clone(),
    );
    m.insert(
        "SNAPSERVER__SAMPLEFORMAT".to_string(),
        cfg.snapserver.sampleformat.clone(),
    );
    m.insert(
        "SNAPSERVER__CODEC".to_string(),
        cfg.snapserver.codec.clone(),
    );
    m.insert(
        "SNAPSERVER__BUFFER_MS".to_string(),
        cfg.snapserver.buffer_ms.to_string(),
    );
    m.insert(
        "SNAPSERVER__PORT".to_string(),
        cfg.snapserver.port.to_string(),
    );
    m.insert(
        "SNAPSERVER__CONTROL_PORT".to_string(),
        cfg.snapserver.control_port.to_string(),
    );
    // Snapclient — resolved device is passed in (either auto-detected or explicit)
    m.insert(
        "RESOLVED_AUDIO_DEVICE".to_string(),
        resolved_audio_device.to_string(),
    );
    m.insert(
        "SNAPCLIENT__LATENCY_MS".to_string(),
        cfg.snapclient.latency_ms.to_string(),
    );
    m.insert(
        "SNAPCLIENT__INSTANCE".to_string(),
        cfg.snapclient.instance.to_string(),
    );
    // Also expose SNAPCLIENT__AUDIO_DEVICE for completeness
    m.insert(
        "SNAPCLIENT__AUDIO_DEVICE".to_string(),
        cfg.snapclient.audio_device.clone(),
    );
    m
}

// Embedded templates via include_str! — these are the verbatim copies from `templates/*.tmpl`
pub const LIBRESPOT_SERVICE_TMPL: &str = include_str!("../templates/librespot.service.tmpl");
pub const SNAPSERVER_SERVICE_TMPL: &str = include_str!("../templates/snapserver.service.tmpl");
pub const SNAPSERVER_CONF_TMPL: &str = include_str!("../templates/snapserver.conf.tmpl");
pub const SNAPCLIENT_SERVICE_TMPL: &str = include_str!("../templates/snapclient.service.tmpl");

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn render_simple_replacement() {
        let mut vars = HashMap::new();
        vars.insert("FOO".to_string(), "bar".to_string());
        vars.insert("BAZ".to_string(), "qux".to_string());
        let tmpl = "hello {{FOO}} and {{BAZ}}";
        assert_eq!(render_template(tmpl, &vars).unwrap(), "hello bar and qux");
    }

    #[test]
    fn render_missing_var_is_error() {
        let vars = HashMap::new();
        let tmpl = "hello {{MISSING}}";
        let err = render_template(tmpl, &vars).unwrap_err();
        assert!(err.contains("MISSING"));
        assert!(err.contains("Template variable not found"));
    }

    #[test]
    fn render_if_changed_identical_content() {
        // Simulate "if-changed" check: rendered content compared to existing file.
        // If identical, caller should skip write (return false / unchanged).
        let mut vars = HashMap::new();
        vars.insert("FOO".to_string(), "bar".to_string());
        let tmpl = "value={{FOO}}";
        let rendered = render_template(tmpl, &vars).unwrap();
        let existing = "value=bar";
        assert_eq!(rendered, existing);
        // Not testing file I/O here; just the string equality that drives if-changed.
    }

    #[test]
    fn render_templates_clean_with_defaults() {
        // All four vendored templates should render without missing-var error using defaults.
        let cfg = crate::config::AppConfig::default();
        // For snapclient template we pass resolved device "plughw:Test,0" to satisfy RESOLVED_AUDIO_DEVICE
        let vars = vars_from_config(&cfg, "plughw:Test,0");
        // Need also to ensure SERVER_IP is set for snapclient template (default empty -> should be empty string is okay)
        // The template expects {{SERVER_IP}}; default config has empty server_ip -> empty string still counts as present
        // But our vars map includes SERVER_IP even if empty, so not missing.
        assert!(
            render_template(LIBRESPOT_SERVICE_TMPL, &vars).is_ok(),
            "{}",
            render_template(LIBRESPOT_SERVICE_TMPL, &vars).unwrap_err()
        );
        assert!(render_template(SNAPSERVER_SERVICE_TMPL, &vars).is_ok());
        assert!(render_template(SNAPSERVER_CONF_TMPL, &vars).is_ok());
        assert!(render_template(SNAPCLIENT_SERVICE_TMPL, &vars).is_ok());
    }

    #[test]
    fn render_normalise_flag_handling() {
        let mut cfg = crate::config::AppConfig::default();
        cfg.spotify.normalise = true;
        let vars = vars_from_config(&cfg, "default");
        let rendered = render_template(LIBRESPOT_SERVICE_TMPL, &vars).unwrap();
        assert!(rendered.contains("--enable-volume-normalisation"));

        cfg.spotify.normalise = false;
        let vars2 = vars_from_config(&cfg, "default");
        let rendered2 = render_template(LIBRESPOT_SERVICE_TMPL, &vars2).unwrap();
        assert!(!rendered2.contains("--enable-volume-normalisation"));
        // When false, the flag is empty string -> the template line contains empty expansion but still renders.
        assert!(rendered2.contains("--initial-volume"));
    }

    #[test]
    fn oauth_url_regex_samples() {
        // OAuth URL regex ported from librespot-auth-helper.sh: https://accounts\.spotify\.com/[^ ]+
        let re = Regex::new(r"https://accounts\.spotify\.com/[^ ]+").unwrap();
        let log = "2024-01-01 librespot: Please visit https://accounts.spotify.com/authorize?client_id=abc&response_type=code and log in";
        let m = re.find(log).unwrap().as_str();
        assert!(m.starts_with("https://accounts.spotify.com/"));
        assert!(re.find("no url here").is_none());
    }
}
