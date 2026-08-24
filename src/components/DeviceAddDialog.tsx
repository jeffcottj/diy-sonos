import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";

type DiscoveredDevice = {
  hostname: string;
  ip: string;
  port: number;
  likely_pi: boolean;
};

type ConnectResult =
  | { kind: "ok"; status: { host: string; port: number; reachable: boolean; host_key_fingerprint?: string } }
  | { kind: "host_key_untrusted"; fingerprint: string; host: string };

export function DeviceAddDialog({ onAdded }: { onAdded?: (ip: string) => void }) {
  const [ip, setIp] = useState("");
  const [username, setUsername] = useState("pi");
  const [password, setPassword] = useState("");
  const [scanning, setScanning] = useState(false);
  const [devices, setDevices] = useState<DiscoveredDevice[]>([]);
  const [status, setStatus] = useState<string | null>(null);
  const [pendingFingerprint, setPendingFingerprint] = useState<string | null>(null);
  const [pendingHost, setPendingHost] = useState<string | null>(null);

  async function scan() {
    setScanning(true);
    setStatus(null);
    try {
      const result = await invoke<DiscoveredDevice[]>("scan_mdns");
      setDevices(result);
      setStatus(`Found ${result.length} device(s)`);
    } catch (e) {
      setStatus(`Scan failed: ${String(e)}`);
    } finally {
      setScanning(false);
    }
  }

  async function connect() {
    if (!ip) {
      setStatus("Enter an IP address");
      return;
    }
    setStatus("Connecting…");
    setPendingFingerprint(null);
    try {
      const res = await invoke<ConnectResult>("connect_device", {
        host: ip,
        port: 22,
        sshUser: username,
        password,
      });
      if (res.kind === "host_key_untrusted") {
        setPendingFingerprint(res.fingerprint);
        setPendingHost(res.host);
        setStatus(`Host key untrusted: ${res.fingerprint}. Confirm to trust.`);
        return;
      }
      // Ok
      setStatus(`Connected to ${ip}. Installing key…`);
      await invoke("install_device_key", { host: ip, port: 22, sshUser: username, password });
      setStatus(`Device ${ip} ready. Key installed.`);
      onAdded?.(ip);
    } catch (e) {
      setStatus(`Connect failed: ${String(e)}`);
    }
  }

  async function trust() {
    if (!pendingHost || !pendingFingerprint) return;
    try {
      await invoke("trust_host_key", { host: pendingHost, fingerprint: pendingFingerprint });
      setStatus(`Trusted ${pendingHost}. Retrying connect…`);
      setPendingFingerprint(null);
      await connect();
    } catch (e) {
      setStatus(`Trust failed: ${String(e)}`);
    }
  }

  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 space-y-4">
      <h2 className="text-lg font-medium">Add device</h2>

      <div className="flex gap-2">
        <button
          onClick={scan}
          disabled={scanning}
          className="rounded-lg bg-zinc-800 hover:bg-zinc-700 disabled:opacity-50 px-4 py-2 text-sm font-medium"
        >
          {scanning ? "Scanning…" : "Scan network"}
        </button>
        <span className="text-xs text-zinc-500 self-center">Lists SSH hosts on the LAN via mDNS (_ssh._tcp)</span>
      </div>

      {devices.length > 0 && (
        <div className="space-y-1">
          <p className="text-xs font-medium text-zinc-400">Discovered:</p>
          <ul className="divide-y divide-zinc-800 rounded-lg border border-zinc-800 overflow-hidden">
            {devices.map((d) => (
              <li
                key={d.ip}
                className="flex items-center justify-between bg-zinc-950 px-3 py-2 hover:bg-zinc-900 cursor-pointer"
                onClick={() => setIp(d.ip)}
              >
                <div>
                  <span className="font-mono text-sm">{d.ip}</span>
                  <span className="ml-2 text-xs text-zinc-400">{d.hostname}:{d.port}</span>
                  {d.likely_pi && (
                    <span className="ml-2 inline-flex items-center rounded-full bg-emerald-900/50 px-2 py-0.5 text-[10px] font-medium text-emerald-300 ring-1 ring-emerald-800">
                      likely Pi
                    </span>
                  )}
                </div>
                <span className="text-xs text-zinc-500">click to fill</span>
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
        <label className="flex flex-col gap-1">
          <span className="text-xs text-zinc-400">IP address</span>
          <input
            value={ip}
            onChange={(e) => setIp(e.currentTarget.value)}
            placeholder="192.168.1.100"
            className="rounded-lg bg-zinc-950 border border-zinc-800 px-3 py-2 text-sm font-mono"
          />
        </label>
        <label className="flex flex-col gap-1">
          <span className="text-xs text-zinc-400">SSH user</span>
          <input
            value={username}
            onChange={(e) => setUsername(e.currentTarget.value)}
            className="rounded-lg bg-zinc-950 border border-zinc-800 px-3 py-2 text-sm"
          />
        </label>
        <label className="flex flex-col gap-1">
          <span className="text-xs text-zinc-400">Password (first connect only)</span>
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.currentTarget.value)}
            className="rounded-lg bg-zinc-950 border border-zinc-800 px-3 py-2 text-sm"
          />
        </label>
      </div>

      <div className="flex gap-2">
        <button
          onClick={connect}
          className="rounded-lg bg-white text-zinc-900 hover:bg-zinc-200 px-4 py-2 text-sm font-medium"
        >
          Connect
        </button>
        {pendingFingerprint && (
          <button
            onClick={trust}
            className="rounded-lg bg-amber-600 hover:bg-amber-500 text-white px-4 py-2 text-sm font-medium"
          >
            Trust {pendingFingerprint.slice(0, 16)}… and retry
          </button>
        )}
      </div>

      {status && <p className="text-xs text-zinc-400">{status}</p>}
      <p className="text-[11px] text-zinc-600">
        Username + password is used only on first connect; the app then installs its own key into
        authorized_keys (like ssh-copy-id). Sudo runs as <code>sudo -S -p ''</code> per command; password held in memory only during operation.
      </p>
    </div>
  );
}
