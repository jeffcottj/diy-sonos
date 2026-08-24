import { create } from "zustand";

type DeviceRole = "server" | "client";

type Device = {
  id: string;
  ip: string;
  hostname?: string;
  role: DeviceRole;
};

type AppState = {
  serverIp: string;
  devices: Device[];
  setServerIp: (ip: string) => void;
  addDevice: (device: Device) => void;
};

export const useAppStore = create<AppState>((set) => ({
  serverIp: "",
  devices: [],
  setServerIp: (ip) => set({ serverIp: ip }),
  addDevice: (device) => set((s) => ({ devices: [...s.devices, device] })),
}));
