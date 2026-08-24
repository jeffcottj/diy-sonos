import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { useAppStore } from "../store";

type OAuthEvent = { url: string | null; status?: string; deviceId?: string; port?: number };

export function ConnectSpotify({ deviceId }: { deviceId: string }) {
  const [url, setUrl] = useState<string | null>(null);
  const [status, setStatus] = useState<string>("idle");
  const { serverIp } = useAppStore();

  useEffect(() => {
    const unlisten = listen<OAuthEvent>("oauth-url", (e) => {
      if (e.payload.url) setUrl(e.payload.url);
      if (e.payload.status) setStatus(e.payload.status);
    });
    return () => {
      unlisten.then((f) => f());
    };
  }, []);

  async function start() {
    setStatus("starting");
    try {
      await invoke("start_oauth", { deviceId });
      setStatus("polling");
    } catch (e) {
      setStatus(`error: ${String(e)}`);
    }
  }

  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-5 space-y-3">
      <h3 className="font-medium">Connect Spotify</h3>
      <p className="text-xs text-zinc-400">
        If credentials are cached in <code className="font-mono">{"/var/cache/librespot"}</code>, this will be skipped. Otherwise the app restarts{" "}
        <code className="font-mono">librespot.service</code> and polls <code>journalctl -u librespot --no-pager -n 400</code> for the last{" "}
        <code className="font-mono">https://accounts.spotify.com/[^ ]+</code> URL, opens your browser, and tunnels the
        callback via port-forward on <code>{String(useAppStore.getState().serverIp || serverIp || "server")}:4000</code>.
      </p>
      <button
        onClick={start}
        className="rounded-lg bg-white text-zinc-900 px-4 py-2 text-sm font-medium"
      >
        Authenticate with Spotify
      </button>
      {status !== "idle" && <p className="text-xs text-zinc-400">Status: {status}</p>}
      {url && (
        <a
          href={url}
          target="_blank"
          rel="noreferrer"
          className="block text-xs text-emerald-400 underline break-all"
        >
          {url}
        </a>
      )}
      <p className="text-[11px] text-zinc-600">
        Callback is auto-tunneled via SSH local port-forward (tokio TcpListener on 127.0.0.1:4000 → device 127.0.0.1:4000) — no manual ssh -L needed.
      </p>
    </div>
  );
}
