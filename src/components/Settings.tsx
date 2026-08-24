import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";

type AppConfig = {
  ssh_user: string;
  server_ip: string;
  server_combo: boolean;
  profile: string;
  spotify: {
    device_name: string;
    bitrate: number;
    normalise: boolean;
    initial_volume: number;
    cache_dir: string;
    oauth_callback_port: number;
    device_type: string;
  };
  snapserver: {
    fifo_path: string;
    sampleformat: string;
    codec: string;
    buffer_ms: number;
    port: number;
    control_port: number;
  };
  snapclient: {
    audio_device: string;
    output_volume: number;
    latency_ms: number;
    instance: number;
  };
  clients: { ip: string; name?: string; ssh_user: string; output_volume: number; latency_ms: number; audio_device: string }[];
};

export function Settings() {
  const [cfg, setCfg] = useState<AppConfig | null>(null);
  const [status, setStatus] = useState<string | null>(null);

  useEffect(() => {
    invoke<AppConfig>("load_config").then(setCfg).catch((e) => setStatus(String(e)));
  }, []);

  async function save() {
    if (!cfg) return;
    try {
      await invoke("save_config", { config: cfg });
      setStatus("Saved. Redeploy affected devices to apply changes that affect rendered files.");
    } catch (e) {
      setStatus(String(e));
    }
  }

  if (!cfg) return <p className="text-sm text-zinc-500">Loading config…</p>;

  return (
    <div className="space-y-4">
      <h2 className="text-lg font-medium">Settings</h2>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        <label className="flex flex-col gap-1">
          <span className="text-xs text-zinc-400">Server IP</span>
          <input
            value={cfg.server_ip}
            onChange={(e) => setCfg({ ...cfg, server_ip: e.target.value })}
            className="rounded-lg bg-zinc-950 border border-zinc-800 px-3 py-2 text-sm font-mono"
          />
        </label>
        <label className="flex items-center gap-2">
          <input
            type="checkbox"
            checked={cfg.server_combo}
            onChange={(e) => setCfg({ ...cfg, server_combo: e.target.checked })}
          />
          <span className="text-xs text-zinc-400">Server also runs client (combo)</span>
        </label>

        <label className="flex flex-col gap-1">
          <span className="text-xs text-zinc-400">Profile</span>
          <select
            value={cfg.profile}
            onChange={(e) => setCfg({ ...cfg, profile: e.target.value })}
            className="rounded-lg bg-zinc-950 border border-zinc-800 px-3 py-2 text-sm"
          >
            <option value="basic">basic (flac, 1000ms, latency 0)</option>
            <option value="advanced">advanced (pcm, 800ms, latency -20)</option>
          </select>
        </label>

        <label className="flex flex-col gap-1">
          <span className="text-xs text-zinc-400">Spotify device name</span>
          <input
            value={cfg.spotify.device_name}
            onChange={(e) => setCfg({ ...cfg, spotify: { ...cfg.spotify, device_name: e.target.value } })}
            className="rounded-lg bg-zinc-950 border border-zinc-800 px-3 py-2 text-sm"
          />
        </label>

        <label className="flex flex-col gap-1">
          <span className="text-xs text-zinc-400">Spotify bitrate</span>
          <select
            value={cfg.spotify.bitrate}
            onChange={(e) => setCfg({ ...cfg, spotify: { ...cfg.spotify, bitrate: parseInt(e.target.value, 10) } })}
            className="rounded-lg bg-zinc-950 border border-zinc-800 px-3 py-2 text-sm"
          >
            <option value={96}>96</option>
            <option value={160}>160</option>
            <option value={320}>320</option>
          </select>
        </label>

        <label className="flex flex-col gap-1">
          <span className="text-xs text-zinc-400">Snapserver codec</span>
          <select
            value={cfg.snapserver.codec}
            onChange={(e) => setCfg({ ...cfg, snapserver: { ...cfg.snapserver, codec: e.target.value } })}
            className="rounded-lg bg-zinc-950 border border-zinc-800 px-3 py-2 text-sm"
          >
            <option value="flac">flac</option>
            <option value="pcm">pcm</option>
          </select>
        </label>
      </div>

      <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-4">
        <h3 className="font-medium text-sm">Clients</h3>
        <ul className="mt-2 space-y-1">
          {cfg.clients.map((c, i) => (
            <li key={c.ip} className="flex gap-2 items-center">
              <input
                value={c.ip}
                onChange={(e) => {
                  const next = [...cfg.clients];
                  next[i] = { ...c, ip: e.target.value };
                  setCfg({ ...cfg, clients: next });
                }}
                className="rounded bg-zinc-950 border border-zinc-800 px-2 py-1 text-xs font-mono flex-1"
              />
              <input
                value={c.name ?? ""}
                placeholder="Kitchen"
                onChange={(e) => {
                  const next = [...cfg.clients];
                  next[i] = { ...c, name: e.target.value || undefined };
                  setCfg({ ...cfg, clients: next });
                }}
                className="rounded bg-zinc-950 border border-zinc-800 px-2 py-1 text-xs flex-1"
              />
              <button
                onClick={() => setCfg({ ...cfg, clients: cfg.clients.filter((_, idx) => idx !== i) })}
                className="text-xs text-red-400"
              >
                remove
              </button>
            </li>
          ))}
        </ul>
        <button
          onClick={() =>
            setCfg({
              ...cfg,
              clients: [...cfg.clients, { ip: "", ssh_user: cfg.ssh_user, output_volume: 90, latency_ms: 0, audio_device: "auto" }],
            })
          }
          className="mt-2 text-xs px-2 py-1 rounded bg-zinc-800"
        >
          + client
        </button>
      </div>

      <button onClick={save} className="rounded-lg bg-white text-zinc-900 px-4 py-2 text-sm">
        Save config
      </button>
      {status && <p className="text-xs text-zinc-400">{status}</p>}

      <p className="text-[11px] text-zinc-600">
        App config stored at <code className="font-mono">~/.config/dev.jeffcottj.diy-sonos/config.yml</code> (via{" "}
        <code className="font-mono">tauri::Manager::app_config_dir()</code> + <code>config.yml</code>). App-owned SSH keypair at{" "}
        <code className="font-mono">app_data_dir()/id_ed25519</code> (0600, ed25519).
      </p>
    </div>
  );
}
