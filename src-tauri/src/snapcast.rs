//! Snapcast control contingency — hand-rolled JSON-RPC client (~8 methods).
//! The primary path is frontend WebSocket to ws://<server_ip>:1780/jsonrpc directly.
//! This Rust module exists only as fallback if webview rejects cross-origin WebSocket Origin check.
//! See plan contingency: implement in Rust (tokio-tungstenite) and bridge via Tauri events.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SnapcastRequest {
    pub id: u32,
    pub jsonrpc: String,
    pub method: String,
    pub params: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SnapcastResponse {
    pub id: u32,
    pub jsonrpc: String,
    pub result: Option<Value>,
    pub error: Option<Value>,
}

pub fn build_request(id: u32, method: &str, params: Value) -> SnapcastRequest {
    SnapcastRequest {
        id,
        jsonrpc: "2.0".to_string(),
        method: method.to_string(),
        params,
    }
}

pub fn method_server_get_status() -> SnapcastRequest {
    build_request(1, "Server.GetStatus", serde_json::json!({}))
}

pub fn method_client_set_volume(client_id: &str, volume: u8) -> SnapcastRequest {
    build_request(
        2,
        "Client.SetVolume",
        serde_json::json!({ "id": client_id, "volume": { "percent": volume } }),
    )
}

pub fn method_client_set_latency(client_id: &str, latency: i16) -> SnapcastRequest {
    build_request(
        3,
        "Client.SetLatency",
        serde_json::json!({ "id": client_id, "latency": latency }),
    )
}

pub fn method_client_set_name(client_id: &str, name: &str) -> SnapcastRequest {
    build_request(
        4,
        "Client.SetName",
        serde_json::json!({ "id": client_id, "name": name }),
    )
}

pub fn method_group_set_mute(group_id: &str, mute: bool) -> SnapcastRequest {
    build_request(
        5,
        "Group.SetMute",
        serde_json::json!({ "id": group_id, "mute": mute }),
    )
}

pub fn method_group_set_clients(group_id: &str, clients: &[String]) -> SnapcastRequest {
    build_request(
        6,
        "Group.SetClients",
        serde_json::json!({ "id": group_id, "clients": clients }),
    )
}

pub fn method_server_delete_client(client_id: &str) -> SnapcastRequest {
    build_request(
        7,
        "Server.DeleteClient",
        serde_json::json!({ "id": client_id }),
    )
}

pub fn method_group_set_name(group_id: &str, name: &str) -> SnapcastRequest {
    build_request(
        8,
        "Group.SetName",
        serde_json::json!({ "id": group_id, "name": name }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_server_get_status() {
        let req = method_server_get_status();
        assert_eq!(req.method, "Server.GetStatus");
        assert_eq!(req.jsonrpc, "2.0");
    }

    #[test]
    fn builds_client_set_volume() {
        let req = method_client_set_volume("abc123", 75);
        assert_eq!(req.method, "Client.SetVolume");
        assert_eq!(req.params["volume"]["percent"], 75);
    }

    #[test]
    fn builds_all_methods_have_ids() {
        assert_eq!(method_client_set_latency("id", 0).id, 3);
        assert_eq!(method_group_set_mute("g1", true).id, 5);
        assert_eq!(method_server_delete_client("c1").id, 7);
    }
}
