# DIY Sonos Debugging Guide

If Spotify shows your DIY Sonos device and playback appears to progress, but you hear no audio, share the diagnostics below with your coding agent.

## 1) Capture deployment + config context

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

## 2) Run server-side diagnostics

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
ls -l /tmp/snapfifo

# During active Spotify playback this should show at least one writer/reader
sudo lsof /tmp/snapfifo || true

# Confirm effective units and binaries
systemctl cat librespot
systemctl cat snapserver
```

## 3) Run client-side diagnostics (each client)

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

## 4) Common failure signatures

### A) `librespot` logs show `Broken pipe (os error 32)`

This usually means the FIFO consumer is missing (snapserver not running/connected to FIFO) while librespot writes.

Check:

- `snapserver.service` is active on the server.
- Server+client hosts did **not** accidentally mask/stop snapserver while configuring client role.
- `/etc/systemd/system/librespot.service` uses `--backend pipe --device /tmp/snapfifo`.
- `/etc/snapserver.conf` uses `source = pipe:///tmp/snapfifo?...`.

### B) Client service active but silent output

Usually ALSA device mismatch.

Check:

- `--soundcard` in `snapclient.service` is a real device (`plughw:X,Y` or `hw:X,Y`), not `default`.
- `speaker-test` succeeds with that same device.
- Mixer volume is not muted (`alsamixer` / `amixer`).

### C) One client works with `speaker-test` but not Spotify

Then local audio hardware is likely okay. Focus on stream path:

- Server FIFO activity during playback (`lsof /tmp/snapfifo`).
- Server `snapserver` logs for repeated connect/disconnect errors.
- Client `snapclient` logs for stream/connect/decode errors.

## 5) Minimal bundle to share with an agent

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
