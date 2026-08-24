import { useEffect, useRef, useState } from "react";

type SnapClient = {
  id: string;
  host: { name: string; ip: string; mac: string };
  config: { name: string; instance: number; latency: number; volume: { percent: number; muted: boolean } };
  lastSeen: { sec: number; usec: number };
  connected: boolean;
};

type SnapGroup = {
  id: string;
  name: string;
  stream_id: string;
  muted: boolean;
  clients: SnapClient[];
};

type SnapStream = { id: string; status: string; uri: { query: { name: string } } };

type SnapStatus = {
  groups: SnapGroup[];
  clients: SnapClient[];
  streams: SnapStream[];
};

type Props = { serverIp: string };

export function Dashboard({ serverIp }: Props) {
  const [status, setStatus] = useState<SnapStatus | null>(null);
  const [wsState, setWsState] = useState<"idle" | "connecting" | "open" | "error">("idle");
  const wsRef = useRef<WebSocket | null>(null);
  const [log, setLog] = useState<string[]>([]);

  function appendLog(line: string) {
    setLog((l) => [...l.slice(-49), line]);
  }

  useEffect(() => {
    if (!serverIp) return;
    const url = `ws://${serverIp}:1780/jsonrpc`;
    setWsState("connecting");
    const ws = new WebSocket(url);
    wsRef.current = ws;

    ws.onopen = () => {
      setWsState("open");
      appendLog(`WebSocket open ${url}`);
      ws.send(JSON.stringify({ id: 1, jsonrpc: "2.0", method: "Server.GetStatus" }));
    };
    ws.onerror = () => {
      setWsState("error");
      appendLog(`WebSocket error ${url}`);
    };
    ws.onclose = () => {
      if (wsState !== "error") setWsState("idle");
      appendLog("WebSocket closed");
    };
    ws.onmessage = (ev) => {
      try {
        const msg = JSON.parse(ev.data as string);
        // Notifications have method like Client.OnConnect etc.
        if (msg.method) {
          const method = msg.method as string;
          appendLog(`${method} ${JSON.stringify(msg.params ?? {})}`);
          // Live updates: re-fetch status or patch locally
          if (
            method.startsWith("Client.") ||
            method.startsWith("Group.") ||
            method.startsWith("Server.")
          ) {
            // For simplicity, re-request status on any notification
            ws.send(JSON.stringify({ id: 1, jsonrpc: "2.0", method: "Server.GetStatus" }));
          }
          return;
        }
        if (msg.result) {
          const result = msg.result as SnapStatus | { server?: SnapStatus };
          // Server.GetStatus returns { server: { groups, streams, clients } } or directly groups?
          const snap = (result as { server?: SnapStatus }).server ?? (result as SnapStatus);
          if (snap.groups) {
            setStatus(snap);
          }
        }
      } catch (e) {
        appendLog(`parse error ${String(e)}`);
      }
    };

    return () => {
      ws.close();
      wsRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [serverIp]);

  function rpc(method: string, params: unknown) {
    const ws = wsRef.current;
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      appendLog(`not connected, cannot send ${method}`);
      return;
    }
    const id = Math.floor(Math.random() * 100000);
    ws.send(JSON.stringify({ id, jsonrpc: "2.0", method, params }));
    appendLog(`→ ${method} ${JSON.stringify(params)}`);
  }

  if (!serverIp) {
    return (
      <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6">
        <p className="text-sm text-zinc-400">Set server IP in Settings to connect to Snapcast.</p>
      </div>
    );
  }

  const streamStatus = status?.streams?.[0]?.status ?? "unknown";
  const streamName = status?.streams?.[0]?.uri?.query?.name ?? "Spotify";

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-3">
        <h2 className="text-lg font-medium">Dashboard</h2>
        <span className="text-xs px-2 py-1 rounded-full bg-zinc-800 text-zinc-400">{wsState}</span>
        <span className="text-xs px-2 py-1 rounded-full bg-zinc-800 text-zinc-300">
          stream {streamName}: {streamStatus}
        </span>
      </div>

      {status ? (
        <div className="grid gap-4">
          {status.groups.map((group) => (
            <div key={group.id} className="rounded-xl border border-zinc-800 bg-zinc-900 p-4">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <input
                    defaultValue={group.name}
                    onBlur={(e) => {
                      const name = e.currentTarget.value.trim();
                      if (name && name !== group.name) rpc("Group.SetName", { id: group.id, name });
                    }}
                    className="bg-transparent text-sm font-medium focus:bg-zinc-800 rounded px-1"
                  />
                  <span className="text-xs text-zinc-500">id {group.id.slice(0, 6)}</span>
                  <span className="text-xs text-zinc-500">stream {group.stream_id}</span>
                </div>
                <div className="flex items-center gap-2">
                  <button
                    onClick={() => rpc("Group.SetMute", { id: group.id, mute: !group.muted })}
                    className={`text-xs px-2 py-1 rounded ${group.muted ? "bg-red-900 text-red-200" : "bg-zinc-800 text-zinc-300"}`}
                  >
                    {group.muted ? "muted" : "mute"}
                  </button>
                  <button
                    onClick={() => rpc("Group.SetMute", { id: group.id, mute: !group.muted })}
                    className="text-xs text-zinc-500"
                  >
                    toggle mute
                  </button>
                </div>
              </div>

              <div className="mt-3 grid grid-cols-1 md:grid-cols-2 gap-3">
                {group.clients.map((client) => (
                  <div key={client.id} className="rounded-lg border border-zinc-800 bg-zinc-950 p-3">
                    <div className="flex items-center justify-between">
                      <div>
                        <input
                          defaultValue={client.config.name || client.host.name}
                          onBlur={(e) => {
                            const name = e.currentTarget.value.trim();
                            if (name) rpc("Client.SetName", { id: client.id, name });
                          }}
                          className="bg-transparent text-sm font-medium focus:bg-zinc-800 rounded px-1"
                        />
                        <div className="text-[11px] text-zinc-500">
                          {client.host.ip} • {client.host.mac} • {client.connected ? "online" : "offline"}
                        </div>
                      </div>
                      <button
                        onClick={() => rpc("Server.DeleteClient", { id: client.id })}
                        className="text-[11px] text-red-400 hover:text-red-300"
                      >
                        delete
                      </button>
                    </div>

                    <div className="mt-2 flex items-center gap-2">
                      <input
                        type="range"
                        min={0}
                        max={100}
                        defaultValue={client.config.volume.percent}
                        onChange={(e) => rpc("Client.SetVolume", { id: client.id, volume: { percent: parseInt(e.target.value, 10) } })}
                        className="flex-1"
                      />
                      <span className="text-xs font-mono w-8">{client.config.volume.percent}%</span>
                      <button
                        onClick={() =>
                          rpc("Client.SetVolume", {
                            id: client.id,
                            volume: { percent: client.config.volume.percent, muted: !client.config.volume.muted },
                          })
                        }
                        className="text-xs px-2 py-1 rounded bg-zinc-800"
                      >
                        {client.config.volume.muted ? "unmute" : "mute"}
                      </button>
                    </div>

                    <div className="mt-2 flex items-center gap-2">
                      <span className="text-[11px] text-zinc-500">latency</span>
                      <input
                        type="number"
                        defaultValue={client.config.latency}
                        onBlur={(e) => {
                          const latency = parseInt(e.currentTarget.value, 10);
                          if (!Number.isNaN(latency)) rpc("Client.SetLatency", { id: client.id, latency });
                        }}
                        className="w-20 bg-zinc-900 border border-zinc-800 rounded px-1 py-0.5 text-xs font-mono"
                      />
                      <span className="text-[11px] text-zinc-500">ms</span>
                      <button
                        onClick={() => {
                          const other = prompt("Move to group id (or create new)");
                          if (other) rpc("Group.SetClients", { id: other, clients: [client.id] });
                        }}
                        className="ml-auto text-[11px] px-2 py-1 rounded bg-zinc-800"
                      >
                        move group
                      </button>
                    </div>
                  </div>
                ))}

                {group.clients.length === 0 && (
                  <p className="text-xs text-zinc-500">No clients in this group — drag or assign via Group.SetClients.</p>
                )}
              </div>

              <div className="mt-3 flex gap-2">
                <button
                  onClick={() => {
                    const clientId = prompt("Add client id to this group");
                    if (clientId) {
                      const existing = group.clients.map((c) => c.id);
                      rpc("Group.SetClients", { id: group.id, clients: [...existing, clientId] });
                    }
                  }}
                  className="text-xs px-2 py-1 rounded bg-zinc-800"
                >
                  + client
                </button>
              </div>
            </div>
          ))}
        </div>
      ) : (
        <p className="text-sm text-zinc-500">Waiting for Server.GetStatus…</p>
      )}

      <div className="rounded-xl border border-zinc-800 bg-zinc-950 p-3">
        <p className="text-xs font-mono text-zinc-500">Live log</p>
        <pre className="mt-1 text-[11px] text-zinc-400 whitespace-pre-wrap max-h-40 overflow-auto">{log.join("\n") || "—"}</pre>
      </div>

      <p className="text-[11px] text-zinc-600">
        Frontend talks directly to Snapcast on <code className="font-mono">ws://{serverIp}:1780/jsonrpc</code>. Methods: Server.GetStatus,
        Server.DeleteClient, Client.SetVolume, Client.SetLatency, Client.SetName, Group.SetMute, Group.SetClients, Group.SetName.
        Snapcast clients are matched to app devices by <code>client.host.ip</code>. If Snapcast or webview rejects cross-origin WebSocket, the Rust fallback in
        <code>snapcast.rs</code> (tokio-tungstenite) will bridge via Tauri events.
      </p>
    </div>
  );
}
