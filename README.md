# amp-panel-patch

Keeps the [CubeCoders AMP](https://cubecoders.com/AMP) web panel (the ADS instance) from dying after a reboot, and
restarts it every night as a safety net.

## Install

Run this on the AMP server:

```bash
curl -fsSL https://raw.githubusercontent.com/TheDyXer/amp-panel-patch/main/install.sh | sudo bash
```

The script patches the server, **restarts the web panel** (about 10 s; game servers keep running), and checks
that everything works. You can run it again safely.

What you'll see:

```text
AMP panel patch v1.1.0  (github.com/TheDyXer/amp-panel-patch)

[1/5] Checking this server
  ✓ running as root
  ✓ AMP instance manager: /usr/bin/ampinstmgr (v2.8.0.8)
  ✓ AMP user: amp
  ✓ cron is available
  ✓ systemd is running
  ! this boot, ampinstmgr.service timed out and took the panel down with it (state: failed) - this is the bug the patch fixes

[2/5] Boot fix: give ampinstmgr.service time to finish at boot
  ✓ wrote /etc/systemd/system/ampinstmgr.service.d/10-boot-timeout.conf
  ✓ systemd reloaded - start timeout: 3min → 30min
  • nothing was restarted; this takes effect at the next boot

[3/5] Nightly panel restart (safety net)
  ✓ wrote /usr/local/sbin/amp-panel-restart
  ✓ cron entry added: every day at 00:15 CEST
  • only the panel restarts; game servers keep running. Log: /var/log/amp-panel-restart.log

[4/5] Restarting the web panel
  • restarting the panel now - game servers keep running...
  ✓ panel restarted (pid 4310 → 1748544) and answers HTTP 200

[5/5] Verifying
  ✓ boot fix file: /etc/systemd/system/ampinstmgr.service.d/10-boot-timeout.conf
  ✓ systemd uses it: ampinstmgr.service start timeout is 30min
  ✓ restart script: /usr/local/sbin/amp-panel-restart
  ✓ cron entry: 15 0 * * * /usr/local/sbin/amp-panel-restart  (every day at 00:15 CEST)
  ✓ cron daemon is running
  • last nightly restart: 2026-09-29 23:26:28 (done, exit 0)
  ✓ panel is up: http://127.0.0.1:8080/ answers HTTP 200

✔ Patched and verified - the panel is up.
```

## Check a server any time

This changes nothing:

```bash
curl -fsSL https://raw.githubusercontent.com/TheDyXer/amp-panel-patch/main/install.sh | sudo bash -s -- --status
```

It ends with one of these:

| Last line | Exit code |
|---|---|
| `✔ Patched and working.` | 0 |
| `✗ Not patched (or incomplete)` | 1 |
| `✔ Patched, but the panel is not answering right now.` | 2 |

## The problem

AMP's systemd unit `ampinstmgr.service` runs `ampinstmgr startboot`. It is a `Type=oneshot` unit with
`TimeoutSec=180`. At boot, `startboot` does two things:

1. It starts the panel (ADS) **inside that unit**.
2. It pulls the `cubecoders/ampbase` Docker image for each "Start on Boot" instance, then starts it.

On a slow or flaky internet line, the pulls take longer than 180 s. systemd then logs this and stops the whole
unit, **panel included**:

```
ampinstmgr.service: start operation timed out. Terminating.
ampinstmgr.service: Failed with result 'timeout'.
```

The panel stays down until someone restarts it by hand. From other machines it looks like
`Connection refused` on port 8080. The installer's first step tells you whether this happened on the current
boot.

## What it changes

| | |
|---|---|
| **Boot fix** | Adds the drop-in `/etc/systemd/system/ampinstmgr.service.d/10-boot-timeout.conf` with `TimeoutStartSec=30min`, so image pulls can finish. A drop-in survives AMP updates that rewrite the unit file. |
| **Nightly restart** | Adds `/usr/local/sbin/amp-panel-restart`, which runs `sudo -H -u amp ampinstmgr restart ADS` and logs to `/var/log/amp-panel-restart.log`. Root's crontab runs it daily at `15 0 * * *`. Only the panel restarts; game instances keep running. |
| **Restart now** | Restarts the panel once during install and waits for it to answer again. It runs in its own systemd scope, so the panel doesn't belong to your SSH session. |
| **Old workaround** | Replaces a hand-made `ampfix.sh` line in root's crontab, if there is one. The `ampfix.sh` file itself is left alone. |

You can restart the panel yourself any time with `sudo /usr/local/sbin/amp-panel-restart`.

## Options

Set these on the `sudo` side of the pipe, for example
`curl -fsSL …/install.sh | sudo AMP_RESTART_CRON='30 4 * * *' bash`.

| Variable | Default | Meaning |
|---|---|---|
| `AMP_RESTART_CRON` | `15 0 * * *` | When the nightly restart runs, in the server's local time |
| `AMP_NO_RESTART` | *(unset)* | Set to `1` to skip restarting the panel during install |
| `AMP_BOOT_TIMEOUT` | `30min` | Start timeout for `ampinstmgr.service` |
| `AMP_ADS_INSTANCE` | `ADS` | Name of the panel instance, as passed to `ampinstmgr restart` |
| `AMP_USER` | `amp` | The user AMP runs as |
| `NO_COLOR` | *(unset)* | Set to turn off colored output |

## Remove

```bash
curl -fsSL https://raw.githubusercontent.com/TheDyXer/amp-panel-patch/main/install.sh | sudo bash -s -- --remove
```

This removes the drop-in, the restart script and the cron line. It keeps the log and restarts nothing.

## Offline install

Use this on a server that can't reach GitHub. Paste the whole line; it contains `install.sh` gzipped and base64
encoded.

<details>
<summary>Show the one-liner</summary>

```bash
echo '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' | base64 -d | gunzip | sudo bash
```

It decodes to `install.sh` v1.1.0 with SHA-256 `41de7a54a62286889bc985e99201dea1d06fc6c9c78f79f0278e992b8da0f6d4`. Check that with
`echo '…' | base64 -d | gunzip | sha256sum`.
</details>

## Notes

- **Where the timeout was seen:** Ubuntu 24.04 with AMP instance manager 2.7.2.8 and 2.8.0.4.
  - The patch is running on Ubuntu 24.04 with instance manager 2.8.0.8.
  - The first boot with 2.8.0.8 finished in 8 s, so newer releases may do less at boot. The drop-in is harmless
    either way.
- **Why 30 minutes:** it gives slow image pulls plenty of room. If a pull hangs for longer, the old behavior
  comes back, and the nightly restart revives the panel.

## License

MIT
