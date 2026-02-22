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
