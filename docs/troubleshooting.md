# Troubleshooting (`setup.sh doctor`)

Use this guide with:

```bash
sudo ./setup.sh doctor server
sudo ./setup.sh doctor client
```

Doctor output includes severity labels:

- **must-fix**: blocks normal playback; fix before continuing.
- **optional**: does not always block playback, but can cause degraded behavior or missing diagnostics.

## Network / DNS failures

### Symptoms

- Preflight fails with DNS lookup errors (e.g., `Cannot resolve github.com`).
- Preflight fails HTTPS reachability checks.

### Why it matters

Package installs, Spotify auth, and GitHub download/update paths all require working network and DNS.

### Suggested command

```bash
resolvectl status
```

If DNS is broken, set a known resolver (example):

```bash
sudo resolvectl dns eth0 1.1.1.1 8.8.8.8
```

## Service not running

### Symptoms

Doctor shows one of these as **must-fix**:

- `librespot.service is not active`
- `snapserver.service is not active`
- `snapclient.service is not active`
- service not enabled/installed

### Why it matters

If the relevant service is stopped, that part of the audio pipeline is down.

### Suggested command

```bash
sudo systemctl restart <service>
```

Then inspect errors:

```bash
sudo journalctl -u <service>.service -p err -n 50 --no-pager
```

## Audio device mismatch

### Symptoms

Doctor client run shows:

- `Resolved audio device was not matched exactly in 'aplay -L'` (**optional**)
- or playback is silent / comes from unexpected output

### Why it matters

Your configured `snapclient.audio_device` may not match an actual ALSA output on that host.

### Suggested command

```bash
aplay -l && aplay -L
```

Use the output to pick a valid device, then update config and redeploy/restart.

## Snapserver connectivity

### Symptoms

Doctor client run shows **must-fix**:

- `Cannot connect to snapserver at <server_ip>:1704`

### Why it matters

Client cannot receive the synchronized audio stream from the server.

### Suggested command

```bash
nc -vz <server_ip> 1704
```

If it fails, verify server is up, `snapserver` is active, and no firewall blocks TCP/1704.

## Device not visible in Spotify

### Symptoms

- Spotify Connect app does not show your DIY Sonos device name.
- Server appears healthy otherwise, but discovery is intermittent or absent.

### Why it matters

Spotify Connect discovery on local networks depends on mDNS/zeroconf advertisements. If `avahi-daemon` is not active, the device may not be discoverable by Spotify clients.

### Suggested command

```bash
sudo systemctl status avahi-daemon --no-pager
```

If inactive, fix as **must-fix** before retrying Spotify discovery:

```bash
sudo systemctl enable avahi-daemon
sudo systemctl restart avahi-daemon
sudo journalctl -u avahi-daemon -n 50 --no-pager
```


## Volume controls: Spotify vs client hardware

If volume behavior is confusing, verify both settings:

- `spotify.initial_volume` sets the starting playback volume for librespot (server-side stream volume).
- `snapclient.output_volume` sets each client's ALSA hardware mixer output percent during `setup.sh client`.

A practical pattern is to keep `snapclient.output_volume` at a safe fixed baseline per speaker, then adjust `spotify.initial_volume` for how loud playback starts in Spotify Connect.

## ALSA mixer state not persisting across reboot

### Symptoms

- `setup.sh client` sets expected volume, but after reboot speaker volume returns to an unexpected level.
- `setup.sh doctor client` warns that `alsa-restore.service` / `alsa-state.service` is not enabled or active.

### Why it matters

ALSA mixer persistence depends on both `alsactl store` writing state and a restore unit loading that state at boot.

### Suggested commands

```bash
sudo alsactl store
sudo systemctl enable --now alsa-restore.service
```

If your distro ships `alsa-state.service` instead:

```bash
sudo systemctl enable --now alsa-state.service
```

### USB card renumbering caveat

Even with persistence enabled, USB sound devices can still be renumbered (for example, `card 1` becoming `card 2`) after hardware changes or boot-order differences. If your playback config references numeric cards (like `hw:1,0`), mixer state may apply to the wrong device.

Prefer stable ALSA card names when possible (for example `plughw:Device,0`), and if needed create ALSA aliases / udev-based naming so your target USB DAC keeps a consistent logical name across reboots.

## Collecting diagnostics to share

If Spotify shows your DIY Sonos device and playback appears to progress, but you hear no audio, collect the following diagnostics.

### 1. Deployment and config context (laptop)

Run from your laptop in the repo:

```bash
./setup.sh version
./setup.sh preflight server --advisory
./setup.sh preflight client --advisory
sed -n '1,220p' config.yml
test -f .diy-sonos.generated.yml && sed -n '1,260p' .diy-sonos.generated.yml
```

If you used guided setup, also share the terminal output from:

```bash
./first-run.sh
```

### 2. Server-side diagnostics

SSH into the server and run:

```bash
sudo systemctl status librespot snapserver avahi-daemon --no-pager -l
sudo journalctl -u librespot -n 200 --no-pager
sudo journalctl -u snapserver -n 200 --no-pager
sudo ./setup.sh doctor server
sudo ss -ltnp | rg ':(1704|1780)\b'
```

Then verify the Spotify audio path:

```bash
# FIFO should exist
ls -l /run/diy-sonos/snapfifo

# During active Spotify playback this should show at least one writer/reader
sudo lsof /run/diy-sonos/snapfifo || true

# Confirm effective units and binaries
systemctl cat librespot
systemctl cat snapserver
```

### 3. Client-side diagnostics (each client)

On each client:

```bash
sudo systemctl status snapclient --no-pager -l
sudo journalctl -u snapclient -n 200 --no-pager
sudo ./setup.sh doctor client
systemctl cat snapclient
```

Audio device checks:

```bash
aplay -l
aplay -L | head -n 80
speaker-test -t wav -c 2 -D "$(awk '/--soundcard/{print $2; exit}' /etc/systemd/system/snapclient.service)" || true
```

If `speaker-test -D default` fails, retry with a concrete ALSA device shown by `aplay -l`, for example `plughw:1,0`.

### Minimal bundle to share with an agent

Please paste or attach:

1. `config.yml` and `.diy-sonos.generated.yml` (if present)
2. Output of:
   - `sudo ./setup.sh doctor server`
   - `sudo ./setup.sh doctor client` (from each client)
   - `sudo systemctl status librespot snapserver snapclient --no-pager -l`
   - `sudo journalctl -u librespot -u snapserver -u snapclient -n 200 --no-pager`
3. `systemctl cat librespot`, `systemctl cat snapserver`, and `systemctl cat snapclient`
4. `aplay -l` and `speaker-test` command/results per client
5. Exact timestamp when you started Spotify playback and for how long (e.g., "played from 20:14:10 to 20:14:45")

That timestamp helps correlate journal logs quickly.

## Common failure signatures

### A) `librespot` logs show `Broken pipe (os error 32)`

This usually means the FIFO consumer is missing (snapserver not running/connected to FIFO) while librespot writes.

Check:

- `snapserver.service` is active on the server.
- Server+client hosts did **not** accidentally mask/stop snapserver while configuring client role.
- `/etc/systemd/system/librespot.service` uses `--backend pipe --device /run/diy-sonos/snapfifo`.
- `/etc/snapserver.conf` uses `source = pipe:///run/diy-sonos/snapfifo?...`.

> **Note on `fs.protected_fifos`:** The default FIFO path `/run/diy-sonos/snapfifo` needs no sysctl change. Only a user-overridden `fifo_path` under `/tmp` or `/var/tmp` triggers the `fs.protected_fifos=0` sysctl via `/etc/sysctl.d/99-snapfifo.conf`.

### B) Client service active but silent output

Usually ALSA device mismatch.

Check:

- `--soundcard` in `snapclient.service` is a real device (`plughw:X,Y` or `hw:X,Y`), not `default`.
- `speaker-test` succeeds with that same device.
- Mixer volume is not muted (`alsamixer` / `amixer`).

### C) One client works with `speaker-test` but not Spotify

Then local audio hardware is likely okay. Focus on stream path:

- Server FIFO activity during playback (`lsof /run/diy-sonos/snapfifo`).
- Server `snapserver` logs for repeated connect/disconnect errors.
- Client `snapclient` logs for stream/connect/decode errors.
