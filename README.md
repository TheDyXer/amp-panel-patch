# amp-panel-patch

Keeps the [CubeCoders AMP](https://cubecoders.com/AMP) web panel (the ADS instance) from dying after a reboot, and
restarts it every night as a safety net.

## Install

Run this on the AMP server:

```bash
curl -fsSL https://raw.githubusercontent.com/TheDyXer/amp-panel-patch/main/install.sh | sudo bash
```

You can run it again safely. Installing doesn't restart AMP or your game servers.

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
`Connection refused` on port 8080.

Check whether you're affected:

```bash
journalctl -u ampinstmgr.service -b | grep -E 'timed out|Failed with result'
```

## What it changes

| | |
|---|---|
| **Boot fix** | Adds the drop-in `/etc/systemd/system/ampinstmgr.service.d/10-boot-timeout.conf` with `TimeoutStartSec=30min`, so image pulls can finish. A drop-in survives AMP updates that rewrite the unit file. |
| **Nightly restart** | Adds `/usr/local/sbin/amp-panel-restart`, which runs `sudo -H -u amp ampinstmgr restart ADS` and logs to `/var/log/amp-panel-restart.log`. Root's crontab runs it daily at `15 0 * * *`. Only the panel restarts; game instances keep running. |
| **Old workaround** | Replaces a hand-made `ampfix.sh` line in root's crontab, if there is one. The `ampfix.sh` file itself is left alone. |

## Check that it worked

```bash
systemctl show ampinstmgr.service -p TimeoutStartUSec   # expect: TimeoutStartUSec=30min
sudo crontab -l | grep amp-panel-restart                 # expect: 15 0 * * * /usr/local/sbin/amp-panel-restart
sudo /usr/local/sbin/amp-panel-restart && tail -2 /var/log/amp-panel-restart.log   # optional: restart the panel now
```

After the next reboot, `journalctl -u ampinstmgr.service -b` should end with
`Finished ampinstmgr.service`, not `timed out`.

## Options

Set these on the `sudo` side of the pipe, for example
`curl -fsSL …/install.sh | sudo AMP_RESTART_CRON='30 4 * * *' bash`.

| Variable | Default | Meaning |
|---|---|---|
| `AMP_RESTART_CRON` | `15 0 * * *` | When the nightly restart runs |
| `AMP_BOOT_TIMEOUT` | `30min` | Start timeout for `ampinstmgr.service` |
| `AMP_ADS_INSTANCE` | `ADS` | Name of the panel instance, as passed to `ampinstmgr restart` |
| `AMP_USER` | `amp` | The user AMP runs as |

## Remove

```bash
curl -fsSL https://raw.githubusercontent.com/TheDyXer/amp-panel-patch/main/install.sh | sudo bash -s -- --remove
```

This removes the drop-in, the restart script and the cron line. It keeps the log.

## Offline install

Use this on a server that can't reach GitHub. Paste the whole line; it contains `install.sh` gzipped and base64
encoded.

<details>
<summary>Show the one-liner</summary>

```bash
echo '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' | base64 -d | gunzip | sudo bash
```

It decodes to `install.sh` with SHA-256 `f14bbac51ddcaeaeb77f05c5a9c7476f35b044830d57e15eb1556d015d3f7f16`. Check that with
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
