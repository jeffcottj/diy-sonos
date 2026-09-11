import { useEffect, useState, type ReactNode } from "react";
import { invoke } from "@tauri-apps/api/core";

type PreviewItem = { name: string; kind: string; detail: string; diff: string[]; changes: boolean };
type DeploySummary = { steps_ok: number; files_changed: boolean; changed_files: string[]; restarts: string[] };

type DeviceReview = {
  ip: string;
  roles: string[];
  items: PreviewItem[] | null;
  error: string | null;
};

function deployRoles(cfg: AppConfig, ip: string): string[] {
  if (ip === cfg.server_ip) {
    const roles = ["server"];
    if (cfg.server_combo || cfg.clients.some((c) => c.ip === ip)) roles.push("client");
    return roles;
  }
  return ["client"];
}

function reviewStats(items: PreviewItem[]): { files: number; restarts: boolean } {
  return {
    files: items.filter((i) => i.kind === "write-new" || i.kind === "update").length,
    restarts: items.some((i) => i.kind === "restart" && i.changes),
  };
}

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

const inputCls = "rounded-lg bg-zinc-950 border border-zinc-800 px-3 py-2 text-sm";

function Field({ label, help, children }: { label: string; help?: string; children: ReactNode }) {
  return (
    <label className="flex flex-col gap-1">
      <span className="text-xs text-zinc-400">{label}</span>
      {children}
      {help && <span className="text-[11px] leading-snug text-zinc-500">{help}</span>}
    </label>
  );
}

function Section({ title, blurb, children }: { title: string; blurb: string; children: ReactNode }) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-4 space-y-3">
      <div>
        <h3 className="font-medium text-sm">{title}</h3>
        <p className="text-[11px] text-zinc-500">{blurb}</p>
      </div>
      {children}
    </div>
  );
}

const PRESETS = {
  basic: { codec: "flac", buffer_ms: 1000, latency_ms: 0 },
  advanced: { codec: "pcm", buffer_ms: 800, latency_ms: -20 },
} as const;

function matchPreset(codec: string, buffer_ms: number, latency_ms: number): string {
  for (const [name, preset] of Object.entries(PRESETS)) {
    if (preset.codec === codec && preset.buffer_ms === buffer_ms && preset.latency_ms === latency_ms) {
      return name;
    }
  }
  return "custom";
}

export function Settings() {
  const [cfg, setCfg] = useState<AppConfig | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [review, setReview] = useState<DeviceReview[] | null>(null);
  const [reviewBusy, setReviewBusy] = useState(false);
  const [applying, setApplying] = useState(false);
  const [applyLog, setApplyLog] = useState<string[]>([]);

  useEffect(() => {
    invoke<AppConfig>("load_config").then(setCfg).catch((e) => setStatus(String(e)));
  }, []);

  async function save() {
    if (!cfg) return;
    try {
      await invoke("save_config", { config: cfg });
      const fresh = await invoke<AppConfig>("load_config");
      setCfg(fresh);
      setStatus("Saved. Checking what would change on your devices…");
      setReviewBusy(true);
      setReview(null);
      try {
        const targets: { ip: string; roles: string[] }[] = [];
        if (fresh.server_ip) targets.push({ ip: fresh.server_ip, roles: deployRoles(fresh, fresh.server_ip) });
        for (const c of fresh.clients) {
          if (c.ip && c.ip !== fresh.server_ip) targets.push({ ip: c.ip, roles: ["client"] });
        }
        const reviews: DeviceReview[] = [];
        for (const target of targets) {
          try {
            const items = await invoke<PreviewItem[]>("preview_deploy", {
              deviceId: target.ip,
              roles: target.roles,
            });
            reviews.push({ ...target, items, error: null });
          } catch (e) {
            reviews.push({ ...target, items: null, error: String(e) });
          }
        }
        setReview(reviews);
        setStatus("Saved. Review the changes below, then apply to push them to your devices.");
      } finally {
        setReviewBusy(false);
      }
    } catch (e) {
      setStatus(String(e));
    }
  }

  async function applyAll() {
    if (!review) return;
    setApplying(true);
    setApplyLog([]);
    const lines: string[] = [];
    for (const device of review) {
      if (!device.items) {
        lines.push(`${device.ip}: skipped (preview failed)`);
        continue;
      }
      try {
        const summary = await invoke<DeploySummary>("deploy_device", {
          deviceId: device.ip,
          roles: device.roles,
        });
        lines.push(
          `${device.ip}: ${summary.steps_ok} steps, ${summary.changed_files.length} file(s) changed, restarts: ${summary.restarts.join(", ") || "none"}`
        );
      } catch (e) {
        lines.push(`${device.ip}: FAILED — ${String(e)}`);
      }
    }
    setApplyLog(lines);
    setApplying(false);
    try {
      const fresh = await invoke<AppConfig>("load_config");
      setCfg(fresh);
    } catch {
      /* keep current editor state */
    }
  }

  function applyPreset(name: "basic" | "advanced") {
    if (!cfg) return;
    const preset = PRESETS[name];
    setCfg({
      ...cfg,
      profile: name,
      snapserver: { ...cfg.snapserver, codec: preset.codec, buffer_ms: preset.buffer_ms },
      snapclient: { ...cfg.snapclient, latency_ms: preset.latency_ms },
    });
  }

  function tune(patch: { codec?: string; buffer_ms?: number; latency_ms?: number }) {
    if (!cfg) return;
    const next = {
      codec: patch.codec ?? cfg.snapserver.codec,
      buffer_ms: patch.buffer_ms ?? cfg.snapserver.buffer_ms,
      latency_ms: patch.latency_ms ?? cfg.snapclient.latency_ms,
    };
    setCfg({
      ...cfg,
      profile: matchPreset(next.codec, next.buffer_ms, next.latency_ms),
      snapserver: { ...cfg.snapserver, codec: next.codec, buffer_ms: next.buffer_ms },
      snapclient: { ...cfg.snapclient, latency_ms: next.latency_ms },
    });
  }

  if (!cfg) return <p className="text-sm text-zinc-500">Loading config…</p>;

  return (
    <div className="space-y-4">
      <h2 className="text-lg font-medium">Settings</h2>

      <Section
        title="Audio"
        blurb="Pick a preset to fill the fields, or edit any field directly — that flips the profile to Custom automatically. Saved exactly as shown; nothing is rewritten behind your back."
      >
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <Field
            label="Profile"
            help={
              cfg.profile === "custom"
                ? "Custom settings — saved exactly as shown above."
                : "Preset values — editing any field below switches to Custom."
            }
          >
            <select
              value={cfg.profile}
              onChange={(e) => {
                const v = e.target.value;
                if (v === "basic" || v === "advanced") applyPreset(v);
              }}
              className={inputCls}
            >
              <option value="basic">basic (flac, 1000ms, latency 0)</option>
              <option value="advanced">advanced (pcm, 800ms, latency -20)</option>
              <option value="custom" disabled={cfg.profile !== "custom"}>
                Custom (automatic when you edit below)
              </option>
            </select>
          </Field>
          <Field
            label="Stream codec"
            help="flac compresses reliably on Wi-Fi; pcm is raw — lower latency but roughly 4× the bandwidth."
          >
            <select
              value={cfg.snapserver.codec}
              onChange={(e) => tune({ codec: e.target.value })}
              className={inputCls}
            >
              <option value="flac">flac</option>
              <option value="pcm">pcm</option>
            </select>
          </Field>
          <Field label="Buffer (ms)" help="End-to-end latency target. Higher rides out Wi-Fi dropouts; lower keeps rooms tighter to Spotify. 100–10000.">
            <input
              type="number"
              min={100}
              max={10000}
              value={cfg.snapserver.buffer_ms}
              onChange={(e) => {
                const v = parseInt(e.target.value, 10);
                if (!Number.isNaN(v)) tune({ buffer_ms: v });
              }}
              className={`${inputCls} font-mono`}
            />
          </Field>
          <Field label="Client latency trim (ms)" help="Global sync offset applied to speaker clients. Negative plays earlier. −5000–5000; per-room trim is a future setting.">
            <input
              type="number"
              min={-5000}
              max={5000}
              value={cfg.snapclient.latency_ms}
              onChange={(e) => {
                const v = parseInt(e.target.value, 10);
                if (!Number.isNaN(v)) tune({ latency_ms: v });
              }}
              className={`${inputCls} font-mono`}
            />
          </Field>
        </div>
      </Section>

      <Section title="Spotify" blurb="How this system appears inside your Spotify app.">
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <Field label="Device name" help="Name shown in Spotify's speaker picker.">
            <input
              value={cfg.spotify.device_name}
              onChange={(e) => setCfg({ ...cfg, spotify: { ...cfg.spotify, device_name: e.target.value } })}
              className={inputCls}
            />
          </Field>
          <Field label="Bitrate" help="Sound quality. 320 needs a steady ~320 kbit/s of bandwidth per stream.">
            <select
              value={cfg.spotify.bitrate}
              onChange={(e) => setCfg({ ...cfg, spotify: { ...cfg.spotify, bitrate: parseInt(e.target.value, 10) } })}
              className={inputCls}
            >
              <option value={96}>96</option>
              <option value={160}>160</option>
              <option value={320}>320</option>
            </select>
          </Field>
        </div>
      </Section>

      <p className="text-[11px] text-zinc-600">
        Server address, combo mode, and the client roster live on the{" "}
        <span className="text-zinc-300">Devices</span> tab.
      </p>

      <button onClick={save} className="rounded-lg bg-white text-zinc-900 px-4 py-2 text-sm">
        Save config
      </button>
      {status && <p className="text-xs text-zinc-400">{status}</p>}

      {reviewBusy && <p className="text-xs text-zinc-500">Reading device state for review…</p>}

      {review && (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-4 space-y-3">
          <div>
            <h3 className="font-medium text-sm">Review & apply</h3>
            <p className="text-[11px] text-zinc-500">
              Dry run — nothing has changed on your devices yet. Applying restarts only services whose files changed;
              expect a brief audio cut on restarted devices.
            </p>
          </div>
          <ul className="space-y-2">
            {review.map((device) => {
              const stats = device.items ? reviewStats(device.items) : null;
              return (
                <li key={device.ip} className="rounded-lg bg-zinc-950 border border-zinc-800 px-3 py-2">
                  <div className="flex items-center gap-2 flex-wrap">
                    <span className="font-mono text-xs">{device.ip}</span>
                    <span className="text-[11px] text-zinc-500">({device.roles.join(" + ")})</span>
                    {device.error ? (
                      <span className="text-[11px] text-red-400">preview failed: {device.error}</span>
                    ) : stats && stats.files === 0 && !stats.restarts ? (
                      <span className="text-[11px] text-emerald-400">no changes</span>
                    ) : (
                      stats && (
                        <span className="text-[11px] text-amber-300">
                          {stats.files} file(s){stats.restarts ? ", will restart services" : ""}
                        </span>
                      )
                    )}
                  </div>
                  {device.items && stats && stats.files > 0 && (
                    <ul className="mt-1 space-y-0.5">
                      {device.items
                        .filter((i) => i.kind === "write-new" || i.kind === "update")
                        .map((i) => (
                          <li key={i.name} className="text-[11px] font-mono text-zinc-400">
                            {i.kind === "write-new" ? "new" : "update"} {i.detail}
                          </li>
                        ))}
                    </ul>
                  )}
                </li>
              );
            })}
          </ul>
          <div className="flex gap-2 items-center">
            <button
              onClick={() => void applyAll()}
              disabled={applying || review.every((d) => !d.items)}
              className="rounded-lg bg-emerald-600 hover:bg-emerald-500 text-white px-4 py-1.5 text-xs font-medium disabled:opacity-50"
            >
              {applying ? "Applying…" : "Apply to devices"}
            </button>
            <button onClick={() => setReview(null)} disabled={applying} className="text-xs text-zinc-400 underline">
              Dismiss
            </button>
          </div>
          {applyLog.length > 0 && (
            <pre className="whitespace-pre-wrap font-mono text-[11px] text-zinc-400 rounded bg-zinc-950 p-2">
              {applyLog.join("\n")}
            </pre>
          )}
        </div>
      )}

      <p className="text-[11px] text-zinc-600">
        App config stored at <code className="font-mono">~/.config/dev.jeffcottj.diy-sonos/config.yml</code>. Device passwords are never
        persisted; the app key is the only credential stored.
      </p>
    </div>
  );
}
