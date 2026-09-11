import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

type KnownDevice = { host: string; port: number; fingerprint: string };
type PreviewItem = { name: string; kind: string; detail: string; diff: string[]; changes: boolean };
type DeploySummary = { steps_ok: number; files_changed: boolean; changed_files: string[]; restarts: string[] };
type DeployLogEvent = { deviceId: string; step: string; level: string; line: string };
type DeployStatusEvent = { deviceId: string; phase: string; done: boolean };

const KIND_STYLES: Record<string, string> = {
  run: "bg-zinc-800 text-zinc-300",
  info: "bg-zinc-800 text-zinc-400",
  "write-new": "bg-emerald-900/50 text-emerald-300 ring-emerald-800",
  update: "bg-amber-900/50 text-amber-300 ring-amber-800",
  unchanged: "bg-zinc-800 text-zinc-500",
  restart: "bg-sky-900/50 text-sky-300 ring-sky-800",
};

function rolesForDeploy(role: Role | null): string[] {
  if (role === "both") return ["server", "client"];
  if (role === "server") return ["server"];
  if (role === "client") return ["client"];
  return [];
}
type ServerCombo = { host: string; port: number; runs_client: boolean };
type DeviceLiveness = { host: string; port: number; live: boolean };

type ClientEntry = {
  ip: string;
  name?: string;
  ssh_user: string;
  output_volume: number;
  latency_ms: number;
  audio_device: string;
};

type BackendConfig = {
  server_ip: string;
  ssh_user: string;
  server_combo: boolean;
  clients: ClientEntry[];
  profile: string;
  [key: string]: unknown;
};

type Role = "both" | "server" | "client";

function roleOf(cfg: BackendConfig, ip: string): Role | null {
  const isServer = cfg.server_ip === ip;
  const isClient = cfg.clients.some((c) => c.ip === ip) || (isServer && cfg.server_combo);
  if (isServer && isClient) return "both";
  if (isServer) return "server";
  if (isClient) return "client";
  return null;
}

const ROLE_STYLES: Record<string, string> = {
  server: "bg-sky-900/50 text-sky-300 ring-sky-800",
  client: "bg-emerald-900/50 text-emerald-300 ring-emerald-800",
};

function displayRoles(role: Role, comboDetected: boolean): Role[] {
  if (role === "both" || (role === "server" && comboDetected)) return ["server", "client"];
  return [role];
}

export function DeviceList({ onConfigChange }: { onConfigChange?: () => void }) {
  const [devices, setDevices] = useState<KnownDevice[]>([]);
  const [live, setLive] = useState<Record<string, boolean>>({});
  const [cfg, setCfg] = useState<BackendConfig | null>(null);
  const [loading, setLoading] = useState(true);
  const [status, setStatus] = useState<string | null>(null);
  const [editingIp, setEditingIp] = useState<string | null>(null);
  const [deployIp, setDeployIp] = useState<string | null>(null);
  const [preview, setPreview] = useState<PreviewItem[] | null>(null);
  const [previewBusy, setPreviewBusy] = useState(false);
  const [deploying, setDeploying] = useState(false);
  const [deployLog, setDeployLog] = useState<string[]>([]);
  const unlisteners = useRef<Array<() => void>>([]);
  const [comboDetected, setComboDetected] = useState<Record<string, boolean>>({});
  const [setupDone, setSetupDone] = useState<Record<string, boolean>>({});
  const [formRole, setFormRole] = useState<"server" | "client">("client");
  const [formUser, setFormUser] = useState("");
  const [formCombo, setFormCombo] = useState(false);
  const [formName, setFormName] = useState("");

  async function reload() {
    setLoading(true);
    setStatus(null);
    try {
      const [known, config] = await Promise.all([
        invoke<KnownDevice[]>("list_device_connections"),
        invoke<BackendConfig>("load_config"),
      ]);
      setDevices(known);
      setCfg(config);
      if (known.length > 0) {
        const liveList = await invoke<DeviceLiveness[]>("check_devices_live", {
          devices: known.map((d) => ({ host: d.host, port: d.port })),
        });
        const map: Record<string, boolean> = {};
        for (const l of liveList) map[`${l.host}:${l.port}`] = l.live;
        setLive(map);
        const configured = known.filter((d) => roleOf(config, d.host) !== null);
        const setupEntries = await Promise.all(
          configured.map(async (d) => {
            const r = roleOf(config, d.host);
            const rolesNeeded = r === "both" ? ["server", "client"] : [r as string];
            const checks = await Promise.all(
              rolesNeeded.map((rr) =>
                invoke<boolean>("check_device_setup", { host: d.host, port: d.port, role: rr }).catch(() => false)
              )
            );
            return [`${d.host}:${d.port}`, checks.every(Boolean)] as const;
          })
        );
        const smap: Record<string, boolean> = {};
        for (const [k, v] of setupEntries) smap[k] = v;
        setSetupDone(smap);
        const servers = known.filter(
          (d) => config.server_ip === d.host && !config.clients.some((c) => c.ip === d.host) && !config.server_combo
        );
        if (servers.length > 0) {
          try {
            const combos = await invoke<ServerCombo[]>("check_servers_combo", {
              devices: servers.map((d) => ({ host: d.host, port: d.port, ssh_user: config.ssh_user })),
            });
            const cmap: Record<string, boolean> = {};
            for (const c of combos) cmap[`${c.host}:${c.port}`] = c.runs_client;
            setComboDetected(cmap);
          } catch {
            /* detection is best-effort; rows fall back to configured role */
          }
        }
      }
    } catch (e) {
      setStatus(`Failed to load devices: ${String(e)}`);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void reload();
    return () => {
      for (const f of unlisteners.current) f();
      unlisteners.current = [];
    };
  }, []);

  async function openDeploy(ip: string, role: Role | null) {
    const roles = rolesForDeploy(role);
    if (roles.length === 0) return;
    setDeployIp(ip);
    setPreview(null);
    setDeployLog([]);
    setPreviewBusy(true);
    try {
      const items = await invoke<PreviewItem[]>("preview_deploy", { deviceId: ip, roles });
      setPreview(items);
    } catch (e) {
      setStatus(`Deploy preview failed: ${String(e)}`);
      setDeployIp(null);
    } finally {
      setPreviewBusy(false);
    }
  }

  async function confirmDeploy(ip: string, role: Role | null) {
    const roles = rolesForDeploy(role);
    if (roles.length === 0) return;
    setDeploying(true);
    setDeployLog([]);
    try {
      const offLog = await listen<DeployLogEvent>("deploy-log", (e) => {
        if (e.payload.deviceId !== ip) return;
        const line = `[${e.payload.step}] ${e.payload.line}`;
        setDeployLog((l) => [...l.slice(-99), line]);
      });
      const offStatus = await listen<DeployStatusEvent>("deploy-status", (e) => {
        if (e.payload.deviceId !== ip) return;
        setDeployLog((l) => [...l.slice(-99), `— ${e.payload.phase} ${e.payload.done ? "done" : "…"}`]);
      });
      unlisteners.current.push(offLog, offStatus);
      const summary = await invoke<DeploySummary>("deploy_device", { deviceId: ip, roles });
      setStatus(
        `Deploy finished: ${summary.steps_ok} steps, ${summary.changed_files.length} file(s) changed, restarts: ${summary.restarts.join(", ") || "none"}.`
      );
      setPreview(null);
      setDeployIp(null);
      await reload();
    } catch (e) {
      setStatus(`Deploy failed: ${String(e)}`);
    } finally {
      setDeploying(false);
    }
  }

  async function forget(ip: string, port: number) {
    try {
      await invoke<boolean>("forget_device_connection", { host: ip, port });
      setStatus(`Forgot ${ip} (config entry kept — remove it in Settings if needed).`);
      await reload();
    } catch (e) {
      setStatus(`Forget failed: ${String(e)}`);
    }
  }

  function openEditor(ip: string, port: number) {
    if (!cfg) return;
    const current = roleOf(cfg, ip);
    setFormRole(current === "server" ? "server" : "client");
    setFormUser(cfg.ssh_user || "");
    setFormCombo(current === "both" || comboDetected[`${ip}:${port}`] === true || cfg.server_combo);
    setFormName(cfg.clients.find((c) => c.ip === ip)?.name ?? "");
    setEditingIp(ip);
  }

  async function saveConfig(ip: string) {
    if (!cfg) return;
    if (!formUser.trim()) {
      setStatus("SSH user is required");
      return;
    }
    try {
      if (formRole === "server") {
        const next: BackendConfig = {
          ...cfg,
          server_ip: ip,
          ssh_user: formUser.trim(),
          server_combo: formCombo,
        };
        await invoke("save_config", { config: next });
        setStatus(
          cfg.server_ip && cfg.server_ip !== ip
            ? `Server changed from ${cfg.server_ip} to ${ip}.`
            : `Device ${ip} configured as ${formCombo ? "server + client" : "server"}.`
        );
      } else {
        const clients = [...cfg.clients];
        const idx = clients.findIndex((c) => c.ip === ip);
        const entry: ClientEntry = {
          ip,
          name: formName.trim() || undefined,
          ssh_user: formUser.trim(),
          output_volume: idx >= 0 ? clients[idx].output_volume : 90,
          latency_ms: idx >= 0 ? clients[idx].latency_ms : 0,
          audio_device: idx >= 0 ? clients[idx].audio_device : "auto",
        };
        if (idx >= 0) clients[idx] = entry;
        else clients.push(entry);
        const next: BackendConfig = { ...cfg, clients };
        if (!next.ssh_user) next.ssh_user = formUser.trim();
        await invoke("save_config", { config: next });
        setStatus(`Device ${ip} configured as client.`);
      }
      setEditingIp(null);
      await reload();
      onConfigChange?.();
    } catch (e) {
      setStatus(`Saving config failed: ${String(e)}`);
    }
  }

  return (
    <section className="rounded-xl border border-zinc-800 bg-zinc-900 p-5">
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-medium">Connected devices</h2>
        <button onClick={() => void reload()} className="text-xs text-zinc-400 underline">
          Refresh
        </button>
      </div>

      {loading ? (
        <p className="mt-2 text-xs text-zinc-500">Checking devices…</p>
      ) : devices.length === 0 ? (
        <p className="mt-2 text-xs text-zinc-500">
          No connected devices yet — add one below to get started.
        </p>
      ) : (
        <ul className="mt-3 divide-y divide-zinc-800 rounded-lg border border-zinc-800 overflow-hidden">
          {devices.map((d) => {
            const key = `${d.host}:${d.port}`;
            const isLive = live[key] ?? false;
            const role = cfg ? roleOf(cfg, d.host) : null;
            const editing = editingIp === d.host;
            return (
              <li key={key} className="bg-zinc-950 px-3 py-2.5">
                <div className="flex items-center gap-2 flex-wrap">
                  <span
                    title={isLive ? "Reachable" : "Not reachable"}
                    className={`inline-block h-2 w-2 rounded-full ${isLive ? "bg-emerald-400" : "bg-zinc-600"}`}
                  />
                  <span className="font-mono text-sm">
                    {d.host}
                    {d.port !== 22 ? `:${d.port}` : ""}
                  </span>
                  {!isLive && <span className="text-[11px] text-zinc-500">offline</span>}
                  {role ? (
                    <>
                      {displayRoles(role, comboDetected[key] === true).map((r) => (
                        <span
                          key={r}
                          className={`inline-flex items-center rounded-full px-2 py-0.5 text-[10px] font-medium ring-1 ${ROLE_STYLES[r]}`}
                          title={
                            r === "client" && role === "server"
                              ? "snapclient is active on this server (detected live, not saved in config — tick combo under Edit to save)"
                              : undefined
                          }
                        >
                          {r}
                        </span>
                      ))}
                      <button
                        onClick={() => (editing ? setEditingIp(null) : openEditor(d.host, d.port))}
                        className="ml-auto text-xs text-zinc-400 underline"
                      >
                        {editing ? "Cancel" : "Edit"}
                      </button>
                      {role && setupDone[key] === false && (
                        <button
                          onClick={() => void openDeploy(d.host, role)}
                          disabled={deploying}
                          className="rounded-lg bg-white text-zinc-900 px-3 py-1 text-xs font-medium disabled:opacity-50"
                          title="Fresh device: preview the full install first, then confirm"
                        >
                          Set up
                        </button>
                      )}
                      <button
                        onClick={() => void forget(d.host, d.port)}
                        className="text-xs text-zinc-600 underline hover:text-red-300"
                        title="Remove trust for this device (key stays on device; re-add to reconnect)"
                      >
                        Forget
                      </button>
                    </>
                  ) : (
                    <>
                      <span className="inline-flex items-center rounded-full bg-amber-900/50 px-2 py-0.5 text-[10px] font-medium text-amber-300 ring-1 ring-amber-800">
                        not configured
                      </span>
                      <button
                        onClick={() => (editing ? setEditingIp(null) : openEditor(d.host, d.port))}
                        className="ml-auto rounded-lg bg-white text-zinc-900 px-3 py-1 text-xs font-medium"
                      >
                        {editing ? "Cancel" : "Configure"}
                      </button>
                    </>
                  )}
                </div>
                <div
                  className="mt-0.5 text-[11px] text-zinc-600 font-mono"
                  title={d.fingerprint}
                >
                  {d.fingerprint.slice(0, 20)}…
                </div>

                {editing && cfg && (
                  <div className="mt-3 space-y-2 rounded-lg border border-zinc-800 bg-zinc-900 p-3">
                    <div className="flex gap-2">
                      {(["server", "client"] as const).map((r) => (
                        <button
                          key={r}
                          onClick={() => setFormRole(r)}
                          className={`px-3 py-1.5 rounded-full text-xs ${formRole === r ? "bg-white text-zinc-900" : "bg-zinc-800 text-zinc-400"}`}
                        >
                          {r === "server" ? "Server" : "Client"}
                        </button>
                      ))}
                    </div>
                    {formRole === "server" && cfg.server_ip && cfg.server_ip !== d.host && (
                      <p className="text-[11px] text-amber-300">
                        This replaces the current server ({cfg.server_ip}).
                      </p>
                    )}
                    <label className="flex flex-col gap-1">
                      <span className="text-xs text-zinc-400">SSH user</span>
                      <input
                        value={formUser}
                        onChange={(e) => setFormUser(e.currentTarget.value)}
                        className="rounded-lg bg-zinc-950 border border-zinc-800 px-3 py-1.5 text-sm w-48"
                      />
                    </label>
                    {formRole === "server" ? (
                      <label className="flex items-center gap-2 text-xs text-zinc-300">
                        <input
                          type="checkbox"
                          checked={formCombo}
                          onChange={(e) => setFormCombo(e.currentTarget.checked)}
                        />
                        Also run audio client on this server (combo)
                      </label>
                    ) : (
                      <label className="flex flex-col gap-1">
                        <span className="text-xs text-zinc-400">Display name (optional)</span>
                        <input
                          value={formName}
                          onChange={(e) => setFormName(e.currentTarget.value)}
                          placeholder="Kitchen"
                          className="rounded-lg bg-zinc-950 border border-zinc-800 px-3 py-1.5 text-sm w-48"
                        />
                      </label>
                    )}
                    <button
                      onClick={() => void saveConfig(d.host)}
                      className="rounded-lg bg-white text-zinc-900 px-4 py-1.5 text-xs font-medium"
                    >
                      Save
                    </button>
                  </div>
                )}

                {deployIp === d.host && (
                  <div className="mt-3 space-y-2 rounded-lg border border-zinc-800 bg-zinc-900 p-3">
                    <p className="text-xs font-medium text-zinc-300">
                      Setup preview — {role ? rolesForDeploy(role).join(" + ") : ""} role(s), dry run (nothing changes until Confirm)
                    </p>
                    {previewBusy && <p className="text-xs text-zinc-500">Reading device state…</p>}
                    {preview && (
                      <>
                        <ul className="space-y-1 max-h-56 overflow-auto">
                          {preview.map((item) => (
                            <li key={item.name} className="text-[11px]">
                              <span
                                className={`inline-flex items-center rounded-full px-2 py-0.5 font-medium ring-1 ${KIND_STYLES[item.kind] ?? KIND_STYLES.info}`}
                              >
                                {item.kind}
                              </span>{" "}
                              <span className="font-mono text-zinc-300">{item.name}</span>
                              <div className="ml-1 text-zinc-500 font-mono break-all">{item.detail}</div>
                              {item.diff.length > 0 && (
                                <pre className="ml-1 mt-0.5 max-h-24 overflow-auto whitespace-pre-wrap font-mono text-zinc-400">
                                  {item.diff.slice(0, 20).join("\n")}
                                </pre>
                              )}
                            </li>
                          ))}
                        </ul>
                        <div className="flex gap-2">
                          <button
                            onClick={() => void confirmDeploy(d.host, role)}
                            disabled={deploying}
                            className="rounded-lg bg-emerald-600 hover:bg-emerald-500 text-white px-4 py-1.5 text-xs font-medium disabled:opacity-50"
                          >
                            {deploying ? "Setting up…" : "Confirm setup"}
                          </button>
                          <button
                            onClick={() => {
                              setDeployIp(null);
                              setPreview(null);
                            }}
                            disabled={deploying}
                            className="text-xs text-zinc-400 underline"
                          >
                            Cancel
                          </button>
                        </div>
                      </>
                    )}
                    {deployLog.length > 0 && (
                      <pre className="max-h-40 overflow-auto whitespace-pre-wrap font-mono text-[11px] text-zinc-400 rounded bg-zinc-950 p-2">
                        {deployLog.join("\n")}
                      </pre>
                    )}
                  </div>
                )}
              </li>
            );
          })}
        </ul>
      )}
      {status && <p className="mt-2 text-xs text-zinc-400">{status}</p>}
    </section>
  );
}
