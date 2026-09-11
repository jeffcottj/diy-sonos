import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useAppStore } from "./store";
import { DeviceAddDialog } from "./components/DeviceAddDialog";
import { DeviceList } from "./components/DeviceList";
import { Dashboard } from "./components/Dashboard";
import { Settings } from "./components/Settings";
import { ConnectSpotify } from "./components/ConnectSpotify";

type AppConfig = {
  ssh_user: string;
  server_ip: string;
  clients: { ip: string }[];
};

type Tab = "devices" | "dashboard" | "settings";

function App() {
  const { serverIp, setServerIp } = useAppStore();
  const [config, setConfig] = useState<AppConfig | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("devices");

  useEffect(() => {
    refreshConfig();
  }, []);

  const [listNonce, setListNonce] = useState(0);

  async function refreshConfig() {
    try {
      const c = await invoke<AppConfig>("load_config");
      setConfig(c);
      if (c.server_ip) setServerIp(c.server_ip);
      setError(null);
    } catch (e: unknown) {
      setError(String(e));
    }
  }

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100 flex flex-col">
      <header className="border-b border-zinc-800 px-6 py-4 flex items-center justify-between">
        <h1 className="text-xl font-semibold tracking-tight">DIY Sonos</h1>
        <div className="flex items-center gap-2">
          <nav className="flex gap-1 text-xs">
            <button
              onClick={() => setTab("devices")}
              className={`px-3 py-1.5 rounded-full ${tab === "devices" ? "bg-white text-zinc-900" : "bg-zinc-800 text-zinc-400"}`}
            >
              Devices
            </button>
            <button
              onClick={() => setTab("dashboard")}
              className={`px-3 py-1.5 rounded-full ${tab === "dashboard" ? "bg-white text-zinc-900" : "bg-zinc-800 text-zinc-400"}`}
            >
              Dashboard
            </button>
            <button
              onClick={() => setTab("settings")}
              className={`px-3 py-1.5 rounded-full ${tab === "settings" ? "bg-white text-zinc-900" : "bg-zinc-800 text-zinc-400"}`}
            >
              Settings
            </button>
          </nav>
          <span className="ml-2 text-[11px] text-zinc-600">v1.0.0</span>
        </div>
      </header>

      <main className="flex-1 px-6 py-6 max-w-6xl w-full mx-auto space-y-6">
        {error && <p className="text-sm text-red-400">Failed to load config: {error}</p>}

        {tab === "devices" && (
          <div className="space-y-4">
            <DeviceList key={listNonce} onConfigChange={() => { void refreshConfig(); }} />
            <DeviceAddDialog
              onAdded={() => {
                setListNonce((n) => n + 1);
                void refreshConfig();
              }}
            />
            <ConnectSpotify deviceId={config?.server_ip || serverIp || "server"} />
          </div>
        )}

        {tab === "dashboard" && <Dashboard serverIp={config?.server_ip || serverIp} />}

        {tab === "settings" && <Settings />}

        <p className="text-xs text-zinc-600">
          Frontend talks directly to Snapcast on ws://&lt;server_ip&gt;:1780/jsonrpc. Spotify browsing not included — use any Spotify app and select “DIY Sonos”.
        </p>
      </main>
    </div>
  );
}

export default App;
