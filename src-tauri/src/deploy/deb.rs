use crate::config::SNAPCAST_VERSION;

/// Pure decision logic ported from `install_deb` in `scripts/common.sh:389-495`.
/// `installed_ver`: version string from `dpkg -s <pkg> | awk '/^Version:/ {print $2}'` or empty if not installed.
/// `stamp_content`: content of `/var/lib/diy-sonos/installed-debs/<pkg>` or empty/missing.
/// `target_filename`: the expected deb filename for the target version+arch+codename (e.g. `snapserver_0.31.0-1_arm64_bookworm.deb`).
/// `target_ver`: the version part extracted from `target_filename` (second `_`-delimited field).
#[derive(Debug, PartialEq, Eq)]
pub enum DebAction {
    /// Skip install, stamp already matches; or installed version matches target -> just update stamp if needed.
    Skip,
    /// Need to write stamp without install (installed version already matches)
    UpdateStamp,
    /// Need to download and install
    Install,
}

/// Determine action given installed version, stamp, and target filename.
/// Mirrors the logic:
/// - if installed_ver == target_ver -> skip install, update stamp to filename (idempotent fast-path)
/// - else if not installed -> install
/// - else if installed_ver != target_ver -> install
pub fn deb_action(
    installed_ver: Option<&str>,
    stamp_content: Option<&str>,
    target_ver: &str,
    target_filename: &str,
) -> DebAction {
    if let Some(inst) = installed_ver {
        if inst == target_ver {
            // Installed version matches target; check stamp
            match stamp_content {
                Some(s) if s == target_filename => DebAction::Skip,
                _ => DebAction::UpdateStamp,
            }
        } else {
            DebAction::Install
        }
    } else {
        DebAction::Install
    }
}

/// Arch mapping from `uname -m` to Debian arch, per `detect_arch` in common.sh:337-350.
pub fn deb_arch(uname_m: &str) -> &'static str {
    match uname_m {
        "aarch64" => "arm64",
        "armv7l" | "armv6l" => "armhf",
        "x86_64" => "amd64",
        _ => "arm64", // unknown -> default arm64 with warning, same as bash fallback
    }
}

/// Build snapcast deb URL.
/// `pkg` is "snapserver" or "snapclient".
/// `version` defaults to SNAPCAST_VERSION if empty.
/// `arch_deb` is the Debian arch string (arm64/armhf/amd64).
/// `codename` is the OS codename (bookworm, bullseye, etc.)
pub fn snapcast_deb_url(pkg: &str, version: &str, arch_deb: &str, codename: &str) -> String {
    let ver = if version.is_empty() {
        SNAPCAST_VERSION
    } else {
        version
    };
    format!(
        "https://github.com/badaix/snapcast/releases/download/v{ver}/{pkg}_{ver}-1_{arch}_{codename}.deb",
        ver = ver,
        pkg = pkg,
        arch = arch_deb,
        codename = codename
    )
}

/// Codename fallback chain for snapcast debs, per `install_deb` fallback in common.sh:438-463.
/// If primary deb not found for `os_codename`, try `bookworm`, then `bullseye`.
/// Returns the ordered list to try, deduped.
pub fn codename_fallback_chain(os_codename: &str) -> Vec<String> {
    let mut chain = Vec::new();
    chain.push(os_codename.to_string());
    for fallback in ["bookworm", "bullseye"] {
        if fallback != os_codename && !chain.contains(&fallback.to_string()) {
            chain.push(fallback.to_string());
        }
    }
    chain
}

pub fn stamp_path(pkg_name: &str) -> String {
    format!("/var/lib/diy-sonos/installed-debs/{}", pkg_name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deb_action_skip_when_stamp_matches() {
        assert_eq!(
            deb_action(
                Some("0.31.0"),
                Some("snapserver_0.31.0-1_arm64_bookworm.deb"),
                "0.31.0",
                "snapserver_0.31.0-1_arm64_bookworm.deb"
            ),
            DebAction::Skip
        );
    }

    #[test]
    fn deb_action_update_stamp_when_version_matches_but_stamp_differs() {
        assert_eq!(
            deb_action(
                Some("0.31.0"),
                Some("snapserver_0.31.0-1_arm64_bullseye.deb"),
                "0.31.0",
                "snapserver_0.31.0-1_arm64_bookworm.deb"
            ),
            DebAction::UpdateStamp
        );
        assert_eq!(
            deb_action(
                Some("0.31.0"),
                None,
                "0.31.0",
                "snapserver_0.31.0-1_arm64_bookworm.deb"
            ),
            DebAction::UpdateStamp
        );
        assert_eq!(
            deb_action(
                Some("0.31.0"),
                Some(""),
                "0.31.0",
                "snapserver_0.31.0-1_arm64_bookworm.deb"
            ),
            DebAction::UpdateStamp
        );
    }

    #[test]
    fn deb_action_install_when_not_installed() {
        assert_eq!(
            deb_action(
                None,
                None,
                "0.31.0",
                "snapserver_0.31.0-1_arm64_bookworm.deb"
            ),
            DebAction::Install
        );
        assert_eq!(
            deb_action(
                None,
                Some("old.deb"),
                "0.31.0",
                "snapserver_0.31.0-1_arm64_bookworm.deb"
            ),
            DebAction::Install
        );
    }

    #[test]
    fn deb_action_install_when_version_differs() {
        assert_eq!(
            deb_action(
                Some("0.30.0"),
                Some("snapserver_0.30.0-1_arm64_bookworm.deb"),
                "0.31.0",
                "snapserver_0.31.0-1_arm64_bookworm.deb"
            ),
            DebAction::Install
        );
    }

    #[test]
    fn arch_mapping() {
        assert_eq!(deb_arch("aarch64"), "arm64");
        assert_eq!(deb_arch("armv7l"), "armhf");
        assert_eq!(deb_arch("armv6l"), "armhf");
        assert_eq!(deb_arch("x86_64"), "amd64");
        assert_eq!(deb_arch("unknown"), "arm64");
    }

    #[test]
    fn url_builder() {
        let url = snapcast_deb_url("snapserver", "0.31.0", "arm64", "bookworm");
        assert_eq!(url, "https://github.com/badaix/snapcast/releases/download/v0.31.0/snapserver_0.31.0-1_arm64_bookworm.deb");
        let url2 = snapcast_deb_url("snapclient", "0.31.0", "armhf", "bullseye");
        assert_eq!(url2, "https://github.com/badaix/snapcast/releases/download/v0.31.0/snapclient_0.31.0-1_armhf_bullseye.deb");
        // version empty → default
        let url3 = snapcast_deb_url("snapserver", "", "amd64", "bookworm");
        assert!(url3.contains("0.31.0"));
    }

    #[test]
    fn codename_fallback() {
        assert_eq!(
            codename_fallback_chain("bookworm"),
            vec!["bookworm", "bullseye"]
        );
        assert_eq!(
            codename_fallback_chain("bullseye"),
            vec!["bullseye", "bookworm"]
        );
        assert_eq!(
            codename_fallback_chain("trixie"),
            vec!["trixie", "bookworm", "bullseye"]
        );
        assert_eq!(
            codename_fallback_chain("jammy"),
            vec!["jammy", "bookworm", "bullseye"]
        );
    }

    #[test]
    fn url_fallback_chain_integration() {
        let ver = "0.31.0";
        let pkg = "snapserver";
        let arch = "arm64";
        let chains = codename_fallback_chain("trixie");
        let urls: Vec<String> = chains
            .iter()
            .map(|codename| snapcast_deb_url(pkg, ver, arch, codename))
            .collect();
        assert_eq!(urls[0], "https://github.com/badaix/snapcast/releases/download/v0.31.0/snapserver_0.31.0-1_arm64_trixie.deb");
        assert_eq!(urls[1], "https://github.com/badaix/snapcast/releases/download/v0.31.0/snapserver_0.31.0-1_arm64_bookworm.deb");
        assert_eq!(urls[2], "https://github.com/badaix/snapcast/releases/download/v0.31.0/snapserver_0.31.0-1_arm64_bullseye.deb");
    }

    #[test]
    fn stamp_path_format() {
        assert_eq!(
            stamp_path("snapserver"),
            "/var/lib/diy-sonos/installed-debs/snapserver"
        );
        assert_eq!(
            stamp_path("snapclient"),
            "/var/lib/diy-sonos/installed-debs/snapclient"
        );
    }
}
