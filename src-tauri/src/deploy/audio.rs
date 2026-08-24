//! ALSA audio device detection — pure parser ported from `detect_alsa_usb_device` in `scripts/common.sh:561-631`.
//! Selection rules:
//! - If `/proc/asound/cards` contains a card whose driver field is exactly `USB-Audio`, pick the first such card → `plughw:<name>,0`
//! - Else via `aplay -l` secondary path (omitted here as parser over string; caller provides that output if needed)
//! - Else pick first non-HDMI card → `plughw:<fallback_name>,0`
//! - Else `default` + loud warning (caller should warn)
//!
//! We implement as two pure parsers that can be combined: `parse_cards` and `parse_aplay`.
//! The high-level `detect_device` implements the full priority.
///
/// Parse `/proc/asound/cards` content.
/// Returns (usb_card_name, fallback_non_hdmi_name)
pub fn parse_cards(cards_content: &str) -> (Option<String>, Option<String>) {
    let mut usb: Option<String> = None;
    let mut fallback: Option<String> = None;

    for line in cards_content.lines() {
        // Expected format: " 0 [Loopback       ]: Loopback  - Loopback"
        // Regex equivalent: ^\s*[0-9]+\s*\[([^]]+)\]\s*:\s*([^-]+)
        let trimmed = line.trim_start();
        if trimmed.is_empty()
            || !trimmed
                .chars()
                .next()
                .map(|c| c.is_ascii_digit())
                .unwrap_or(false)
        {
            continue;
        }
        // Find '[' and ']'
        let start = match line.find('[') {
            Some(i) => i,
            None => continue,
        };
        let end = match line.find(']') {
            Some(i) => i,
            None => continue,
        };
        if end <= start {
            continue;
        }
        let name = line[start + 1..end].trim().to_string();
        // After ']', expect ': driver'
        let after = &line[end + 1..];
        let colon = match after.find(':') {
            Some(i) => i,
            None => continue,
        };
        let driver_part = after[colon + 1..].trim();
        // Driver is up to ' -' or end
        let driver = if let Some(dash) = driver_part.find(" -") {
            driver_part[..dash].trim()
        } else if let Some(dash) = driver_part.find('-') {
            driver_part[..dash].trim()
        } else {
            driver_part.trim()
        };

        if driver == "USB-Audio" {
            usb = Some(name);
            break;
        } else if fallback.is_none() && !name.to_ascii_lowercase().contains("hdmi") {
            fallback = Some(name);
        }
    }
    (usb, fallback)
}

/// Parse `aplay -l` output for a secondary USB detection (method 2 in bash script).
/// Looks for a card line `^card N:` and then a subsequent `USB` occurrence associated with that card.
/// Returns card name if found.
pub fn parse_aplay(aplay_output: &str) -> Option<String> {
    let lines: Vec<&str> = aplay_output.lines().collect();
    let mut current_card_num: Option<String> = None;
    let mut current_card_line: Option<String> = None;

    for line in &lines {
        if let Some(rest) = line.strip_prefix("card ") {
            // Extract card number: "card 1: ..."
            // Format: "card 1: Device [USB Audio], device 0: USB Audio [USB Audio]"
            // We parse the number after "card "
            if let Some(colon) = rest.find(':') {
                let num = rest[..colon].trim().to_string();
                current_card_num = Some(num);
                current_card_line = Some(line.to_string());
                // If this line itself contains USB, immediate match
                if line.contains("USB") {
                    // Extract card name: after "card N: " up to next space or '['
                    if let Some(name) = extract_card_name_from_line(line) {
                        return Some(name);
                    } else if let Some(n) = &current_card_num {
                        return Some(n.clone());
                    }
                }
            }
        } else if line.contains("USB") {
            if let Some(card_line) = &current_card_line {
                if let Some(name) = extract_card_name_from_line(card_line) {
                    return Some(name);
                } else if let Some(n) = &current_card_num {
                    return Some(n.clone());
                }
            }
        }
    }
    None
}

fn extract_card_name_from_line(line: &str) -> Option<String> {
    // "card 1: Device [USB Audio], device 0: USB Audio [USB Audio]"
    // Extract after "card N: " up to first space or '[' pattern
    // Simpler: take substring after ": " then up to " [" or " "
    let colon = line.find(':')?;
    let after = line[colon + 1..].trim_start();
    // After is like "Device [USB Audio], device 0: ..."
    // Card name is first token before space or '['? Actually name is before " [".
    // In /proc/asound/cards, card name is inside []. In aplay -l, card identifier is similar.
    // We'll extract up to " [" if present, else up to space.
    if let Some(bracket) = after.find(" [") {
        // Card name before " [" is like "Device" ? Not ideal; but bash fallback uses that first token?
        // Bash method 2: extracts `card_name=$(aplay -l | awk ... sub(...))` which extracts after "card N: " up to space?
        // Let's mimic: split after colon, trim, then first word or bracket content?
        // Simpler: return first word before space/bracket
        let before_bracket = after[..bracket].trim();
        if !before_bracket.is_empty() {
            // That token may be the card's short name; but returning it is acceptable for test fixtures.
            // Prefer bracket content? Actually bracket contains long name.
            // Use that long name? For OBS: bash does: sub(/^card [0-9]+: /, "", line); sub(/ .*/, "", line); print line
            // That extracts "Device" from "Device [USB Audio], ..."
            // So first word before space is card alias.
            let first = before_bracket
                .split_whitespace()
                .next()
                .unwrap_or(before_bracket);
            return Some(first.to_string());
        }
    }
    // Fallback: first token
    after.split_whitespace().next().map(|s| s.to_string())
}

/// High-level detection: given `cards_content` and optional `aplay_output`, return the resolved device string.
/// Mirrors the priority in `detect_alsa_usb_device`.
pub fn detect_device(cards_content: &str, aplay_output: Option<&str>) -> String {
    let (usb, fallback) = parse_cards(cards_content);
    if let Some(name) = usb {
        return format!("plughw:{},0", name);
    }
    if let Some(aplay) = aplay_output {
        if let Some(name) = parse_aplay(aplay) {
            return format!("plughw:{},0", name);
        }
    }
    if let Some(name) = fallback {
        return format!("plughw:{},0", name);
    }
    "default".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_usb_audio_card_first() {
        let cards = r#" 0 [Loopback       ]: Loopback - Loopback
 1 [Device         ]: USB-Audio - USB Audio Device
 2 [bcm2835HDMI    ]: bcm2835 HDMI - bcm2835 HDMI"#;
        let (usb, fallback) = parse_cards(cards);
        assert_eq!(usb, Some("Device".to_string()));
        assert_eq!(fallback, Some("Loopback".to_string()));
        assert_eq!(detect_device(cards, None), "plughw:Device,0");
    }

    #[test]
    fn picks_first_usb_when_multiple() {
        let cards = r#" 0 [FirstUSB       ]: USB-Audio - First USB
 1 [SecondUSB      ]: USB-Audio - Second USB"#;
        assert_eq!(detect_device(cards, None), "plughw:FirstUSB,0");
    }

    #[test]
    fn fallback_to_non_hdmi_when_no_usb() {
        let cards = r#" 0 [Loopback       ]: Loopback - Loopback
 1 [bcm2835HDMI    ]: bcm2835 HDMI - bcm2835 HDMI
 2 [Headphones     ]: bcm2835 Headphones - bcm2835 Headphones"#;
        // No USB-Audio driver, fallback should be Loopback (first non-HDMI)
        let (usb, fallback) = parse_cards(cards);
        assert_eq!(usb, None);
        assert_eq!(fallback, Some("Loopback".to_string()));
        assert_eq!(detect_device(cards, None), "plughw:Loopback,0");
    }

    #[test]
    fn hdmi_only_falls_to_default() {
        let cards = r#" 0 [bcm2835HDMI    ]: bcm2835 HDMI - bcm2835 HDMI
 1 [bcm2835HDMI1   ]: bcm2835 HDMI - bcm2835 HDMI 1"#;
        let (usb, fallback) = parse_cards(cards);
        assert_eq!(usb, None);
        assert_eq!(fallback, None);
        assert_eq!(detect_device(cards, None), "default");
    }

    #[test]
    fn usb_detection_via_aplay_when_cards_no_usb_field() {
        let cards = r#" 0 [Loopback       ]: Loopback - Loopback
 1 [bcm2835HDMI    ]: bcm2835 HDMI - bcm2835 HDMI"#;
        let aplay = r#"**** List of PLAYBACK Hardware Devices ****
card 0: Loopback [Loopback], device 0: Loopback PCM [Loopback PCM]
  Subdevices: 8/8
card 1: Device [USB Audio Device], device 0: USB Audio [USB Audio]
  Subdevices: 1/1
"#;
        // cards has no USB-Audio driver, but aplay shows USB device on card 1
        assert_eq!(detect_device(cards, Some(aplay)), "plughw:Device,0");
    }

    #[test]
    fn empty_cards_returns_default() {
        assert_eq!(detect_device("", None), "default");
        assert_eq!(detect_device("", Some("")), "default");
    }

    #[test]
    fn case_insensitive_hdmi_filter() {
        let cards = r#" 0 [vc4hdmi0       ]: vc4-hdmi - vc4-hdmi
 1 [USB            ]: USB-Audio - USB Sound Card"#;
        // Even though vc4hdmi contains hdmi case-insensitive, it's filtered; USB wins
        assert_eq!(detect_device(cards, None), "plughw:USB,0");
    }

    #[test]
    fn parse_aplay_direct_usb_line() {
        let aplay = "card 2: U192k [AudioQuest DragonFly], device 0: USB Audio [USB Audio]";
        // This line itself contains USB and card prefix
        let name = parse_aplay(aplay);
        assert!(name.is_some());
    }
}
