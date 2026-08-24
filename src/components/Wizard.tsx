import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { DeviceAddDialog } from "./DeviceAddDialog";
import { ConnectSpotify } from "./ConnectSpotify";

type WizardStep = "devices" | "profile" | "deploy" | "oauth" | "done";

export function Wizard() {
  const [step, setStep] = useState<WizardStep>("devices");
  const [serverIp, setServerIp] = useState("");
  const [profile, setProfile] = useState<"basic" | "advanced">("basic");
  const [deployLog, setDeployLog] = useState<string[]>([]);

  async function saveProfile() {
    try {
      const cfg = await invoke<{ profile: string }>("load_config");
      const next = { ...cfg, profile, server_ip: serverIp || (cfg as unknown as { server_ip?: string }).server_ip };
      await invoke("save_config", { config: next });
      setStep("deploy");
    } catch (e) {
      setDeployLog((l) => [...l, `save failed: ${String(e)}`]);
    }
  }

  async function deployAll() {
    setDeployLog(["Starting deploy…"]);
    try {
      // In real orchestration: preflight SSH to all, deploy server/combo, surface OAuth, deploy each client
      if (serverIp) {
        await invoke("deploy_device", { deviceId: serverIp, roles: ["server"] });
        setDeployLog((l) => [...l, `server ${serverIp} deployed`]);
      }
      setStep("oauth");
    } catch (e) {
      setDeployLog((l) => [...l, `deploy failed: ${String(e)}`]);
    }
  }

  return (
    <div className="space-y-4">
      <div className="flex gap-2 text-xs">
        {(["devices", "profile", "deploy", "oauth", "done"] as WizardStep[]).map((s) => (
          <span
            key={s}
            className={`px-2 py-1 rounded-full ${step === s ? "bg-white text-zinc-900" : "bg-zinc-800 text-zinc-400"}`}
          >
            {s}
          </span>
        ))}
      </div>

      {step === "devices" && (
        <div className="space-y-3">
          <p className="text-sm text-zinc-400">Add server + clients via IP or mDNS scan.</p>
          <DeviceAddDialog onAdded={(ip) => setServerIp(ip)} />
          <label className="flex flex-col gap-1">
            <span className="text-xs text-zinc-400">Server IP (for snapclient --host)</span>
            <input
              value={serverIp}
              onChange={(e) => setServerIp(e.currentTarget.value)}
              placeholder="192.168.1.100"
              className="rounded-lg bg-zinc-950 border border-zinc-800 px-3 py-2 text-sm font-mono"
            />
          </label>
          <button onClick={() => setStep("profile")} className="rounded-lg bg-white text-zinc-900 px-4 py-2 text-sm">
            Next: audio profile
          </button>
        </div>
      )}

      {step === "profile" && (
        <div className="space-y-3 rounded-xl border border-zinc-800 bg-zinc-900 p-5">
          <h3 className="font-medium">Audio profile</h3>
          <div className="grid grid-cols-2 gap-3">
            <button
              onClick={() => setProfile("basic")}
              className={`rounded-xl border p-4 text-left ${profile === "basic" ? "border-white bg-zinc-800" : "border-zinc-800 bg-zinc-950"}`}
            >
              <div className="font-medium">Basic</div>
              <div className="text-xs text-zinc-400">flac, buffer 1000ms, latency 0 — reliable, default</div>
            </button>
            <button
              onClick={() => setProfile("advanced")}
              className={`rounded-xl border p-4 text-left ${profile === "advanced" ? "border-white bg-zinc-800" : "border-zinc-800 bg-zinc-950"}`}
            >
              <div className="font-medium">Advanced</div>
              <div className="text-xs text-zinc-400">pcm, buffer 800ms, latency -20 — lower latency, more bandwidth</div>
            </button>
          </div>
          <button onClick={saveProfile} className="rounded-lg bg-white text-zinc-900 px-4 py-2 text-sm">
            Save & continue to deploy
          </button>
        </div>
      )}

      {step === "deploy" && (
        <div className="space-y-3">
          <button onClick={deployAll} className="rounded-lg bg-white text-zinc-900 px-4 py-2 text-sm">
            One-click deploy
          </button>
          <pre className="rounded-lg bg-zinc-950 border border-zinc-800 p-3 text-xs text-zinc-400 max-h-40 overflow-auto">
            {deployLog.join("\n") || "—"}
          </pre>
          <button onClick={() => setStep("oauth")} className="text-xs text-zinc-500 underline">
            Skip to OAuth →
          </button>
        </div>
      )}

      {step === "oauth" && (
        <div className="space-y-3">
          <ConnectSpotify deviceId={serverIp || "server"} />
          <button onClick={() => setStep("done")} className="rounded-lg bg-white text-zinc-900 px-4 py-2 text-sm">
            Finish
          </button>
        </div>
      )}

      {step === "done" && (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6">
          <h3 className="font-medium">All set!</h3>
          <p className="text-sm text-zinc-400">Open Spotify on any device and look for “DIY Sonos” in the device list.</p>
        </div>
      )}
    </div>
  );
}
