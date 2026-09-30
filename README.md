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

What you'll see (a real run):

```text
AMP panel patch v1.1.0  (github.com/TheDyXer/amp-panel-patch)

[1/5] Checking this server
  ✓ running as root
  ✓ AMP instance manager: /usr/bin/ampinstmgr (v2.8.0.8)
  ✓ AMP user: amp
  ✓ cron is available
  ✓ systemd is running
  • this boot, ampinstmgr.service started normally (state: active)
  • boots in the journal where the boot timeout killed AMP: 3

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
  ✓ panel restarted (pid 2538319 → 2615275) and answers HTTP 200

[5/5] Verifying
  ✓ boot fix file: /etc/systemd/system/ampinstmgr.service.d/10-boot-timeout.conf
  ✓ systemd uses it: ampinstmgr.service start timeout is 30min
  ✓ restart script: /usr/local/sbin/amp-panel-restart
  ✓ cron entry: 15 0 * * * /usr/local/sbin/amp-panel-restart  (every day at 00:15 CEST)
  ✓ cron daemon is running
  • last panel restart: 2026-09-29 23:52:37 (done, exit 0)
  ✓ panel is up: http://127.0.0.1:8080/ answers HTTP 200

✔ Patched and verified - the panel is up.
  • At boot, AMP now gets 30min instead of 180 s before systemd gives up.
  • The panel restarts every day at 00:15 CEST.
  • Check any time:  curl -fsSL https://raw.githubusercontent.com/TheDyXer/amp-panel-patch/main/install.sh | sudo bash -s -- --status
  • Undo:            curl -fsSL https://raw.githubusercontent.com/TheDyXer/amp-panel-patch/main/install.sh | sudo bash -s -- --remove
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

Use this on a server that can't reach GitHub. Paste the whole line into the server's terminal: it contains
`install.sh` gzipped and base64 encoded, and it only runs once the whole paste has arrived. To remove the patch or
check it instead, type ` --remove` or ` --status` after the pasted line, before you press Enter. The line is made
with [mkoneliner](https://github.com/TheDyXer/mkoneliner).

<details>
<summary>Show the one-liner</summary>

<!-- mkoneliner: install.sh --sudo -->
```sh
_ol(){ _f=$(mktemp)||return 1;if echo 'H4sIAAAAAAACA81bX3PbSHJ/56fohakFaQukKK/vdinLLq+ttVWRJZck3+Yia2WIHIqISIALgKJ1klKpPOQDJFd1L3nKR9tPkl/3zAADkPJ6t3Kp2HcmCcx09/T0n1/3zD74qjvP0u55FHdVfEXnYTZuPKBwOgtmYawm+DcfjPt0qdSM8rGil/Nz9TIZqjSjF2/f0UKdkwykFr998eqIojjLw3ig2hROoivVaTwAQaJeh75PkpxG0ac+pWGUqYzZ8OjpRdrJVHoVDZSfEWanOeXRVCXznFpZngwuqfftBmVtyhN6vEHTKO7Qi5zOQW9diOPPx5KYJsFvP9JsPpmAEb0CFZVSNA0vFI2SlNSVSq/JOxJuSSzCeYXwW/wopGySLCyDSRRfQgUhZAsvIfwkiS9AEU9iLd46ZddZrqZDuoyYKStkHkc5hfFQfmhFDSNMXkT5mKK8I8Q3O3QUjlR+TbHKoRwl8mfOHC1sHF2MQS2njY1+7wm1UtbnIE3idodeh1NVSJ/p/UrncRzFF3oHdvndZNInGszTCQWj7GiPxnk+y/rdbhouOhcQaX4+x0YMkjhXcd4ZJNPu8Vi9uv5HlXZrJtGdhjCZSBPtZGO6pWw+TKwBQa35PAOzvz83CjIKAvwvE552u+RPS32C/jdom4SMGspeaJ3OZ+vUw5sYSjRv12nTGXo+z+2WJYu4DcKHappcqf/bVaXCU7bwYJZHSRzCHOKrCNs+BQM4iBL7ZWP5yNM/UhYN1TqpzkWHPhqS8NWzw52j4xeHx2cvDw/2t3340Tf0kP/6wvBjuy+qq4/kxYIXZayT+URRMhJeYoyTa2utrOyhGoXzCSzYg3VuaOJeu6D6/cHB8dnx7tudg/fHeFT1c3bJ5XBQofp4A45fkkOsOdvdh6D7L3f4kRN6KGZvmIVZhm1EzHBCQ0kOE0pi7492Dh274R2U+AYXQvTIaPWfkhg4lMT2D6wGZRRvEITILqOZ1Ra80o0I85QfGEMQMiDx8mDvwJXJkBlGWXiObRgkkyTF8qC82Txv8NtAzROaRTMIFU0ajXcvjl++OfvTzuHRLja81+l1NhqHO+8g3Isft//3rLZhreX73f1tSSaTZBBOuhnnlHKuWXlj7+D1dvcq5FEXy687eNp4v797vL1sDI1XhwfvdvfPXu0ebndVPuiacGs+u02e1xmaYdvNcni3txFwOgiMtWF98ajB1n129PLNzqv3ezvbzZu65feD0ozvGq71msHuo34g5nnXcM3SjHMf9QP8wihjc2YEf+0HWPJdA9sfFH/M7jpPGtGITijIEbpO6euv+ftfyGveWIPpB3cenW6xdcUNou8P9l5tN/0P6qQ39en14c7Ovv75eBO//7yzt3fwo3nwGA8Od8zoxzz85Z9f2NF/wM9Xu2/1r00ZebRzrH9uTP2GmmTKsvMtI7/g4GvSvqHpa2K+JeP7jVHU+PHF4f7u/uuj7Y3GDy92997jHb6eh3Gs0labbmgGN8lH5K9l7Jrad8Qk1zK6wv9pLWtpW/6sAbfXsg+xD6WxtB4+RQj+UvEYfgApywFbdNeAoc0gCznSfIjXspO17BQCrGX8VxPnhfLcXoWDZblZJZtcClGXLK/ml//6T6GqKYpSK9QeyuQoHiU1mWTyv/63M7mykmLqIkzjFVO/cibqHVyaW2xWs9Wy3+kR9dptpoucqn4f3Tts+FAro66LvzmzYU1LUwujgUj2eykSYFedLO8cyFK5aYbsQ4f2s683t0hgRI/JVN1zrCYzhsKOf47DK3VmIpNYLTx0SF0kklq8Yi+9azBAPDNhSYbrl4N8Qtk4WUAOjmoeBTM61qMEsb4/UgNwvQonc0Wbz7pDddWNAXXp9pbydK5E1PF8GsZnNnEzdbioBGea0lhyER6kKhxSkBaP6OnTp2y2eMWx5oSaU9r+F/rpZCP47vRRk4NOc7z0RGZub5Onsz6dljGICoVrGDsMrxnErm1sDvv8D/TPum+1ehsPmuN22yt+TM2PYZgrerT2T20WyoSakmoVnnhrmeeTWQCiimzZj2mUKy4thlHMSbTZo9YUVQw1N9sAT4AxkUY1JgEiy45G2NgOIF8+T4EBerTAagDZaQE4EE5Ya5g1xOAICu00FszibBTVFJ1PZ/iOf2GV00vsLHACEBXW/8xr4rFVM8CkDhYS1QfTGQNAPUKea21SOtUD+fkWtouFY8PEQskCCAqmNsIU03mfnamsFVbbGYoalZ0l8zQT4+NneXhOwaRqVHSRop4IftBuYbO951qbkBuHIDYp/PdXyP28Q37rp9uTk342Cweqf9o9bSNWo0L8AFzRKp+f3jbbvpj0KIqHZxhjdPz2NTJoC8F+yrg+uHKRnpGN1Q3txhAdo1m/eCFe+Ym6ySzvDlDRDqSi5UTRdSjIVjCLz4+DYJbZKl4IPOQ5VLneGCVzlpciXUWbjWM0x0AeTxnyqPS5WMcQ5CxIQDwq9bj57OtewUEgq18M9B0+UiIUiOMpj3wmroSSIlYobDMBpBeo1jNAX3EEFgsSZBHXwW79igr9/eFepzBwns0/8IGtsHAe1YXUHcEbCuYV+Y1qYBJP3ZW41sGo3c+6v/z137q33Qvf3UmmYxFts6XNKIEZsbi7Fv2/DeOQS/MrDlCd00e+DmksIkwWQZsDXq9k1HlIV91uhY8Niu9e7O/snWHB5tvh+31OdfSUnrbCxSVcwr/1yW9oe79E9diEN17xJ9LGRTY/b3V/OqEP+emjW/3R7K6T563TZfvz76/asHcmeylh9W3C0c1jLuEwA/3WlTwHmvSqIyGsJ1gCxstD8cHFKr/yDMaQ35DSnXaomwWeM830D8zUm/J3MXVn/5XNp9QquTwnL/Coz3za69Sq0rEvzVMI7+6PdleGYkbxHn21LTPEmYrHUsCgfult/rGzgb+9/rcb3250JbCN1eDyTHuQiRPJJXlWCoRvbpx45nHhf2w5U205fWIj1dDcWFv/ETTedB6071wK7FOYVZg5x/gyKtk4WM3T4rb2VSUqmDjOPifZzYfrDS6lcxWlWSG6JD4Ei/AK9R4XhSaZuBDEycI8xXaoMMvow5N32pe5g6JsSZ6dxcAfxQ+uTEmX7bmC75U4JcqCcJAjeBRgZQUgactkl7QTLTY36J+Rg+JwwvSCcx0zDPD5GTgnTgDd2aVXpZEBfFh38YDFQm6RCB8pjf17+GM11Wjl8v87MZc0j1LNVUI/2EC9Flxwk8pFTMQGAYVKMpA+J4lIJXEdlZPk0m0kJIvYtha5c4qdglHKZxt2JcQiHd/P57YDgYqIm7Iq05ZQwCvGE6NkhQiyXggRJ+kUeryuc9J0BJFQbcXcgHRXzFFGc2EGEE73scxmMORKlRaXW512u7i9Cv5wNvB0aVfgIdc2FYNnF7NBoMVALwT4SZ9rzRgWUAQPZTAHHCgtwEEY+7rnSwqgcJATS2XQJVkMtqGB5pvj43ekG5G2Uaa3BiELZcR0lgvUhChjiUVxtkCSRcSPkxjRnV8p7B+MTTqMUDEtLpC9UYBkedZpcNQ7YxRiAhsmuHGG55RG6tiT7leiUEmotGHgxCcULFBQ3xR07/xq8F3hyqLkKmORcSVjecNudMy8jig4cASocWI0Q5xV/S7r8UO3ezPYbm7ecZq50UlmcOdXxDB7rQbjhFiFBeYXrZ/NomEFjc+SlMEKf3AIgxEFAA/Zg59OwuAvp4+QT05+6vbx5XlLipuH7c7DBx96D0yGKqVtVwN8ltVie2EVxO+CSR7P3sAYmTHSZ795w9/6wbfsC6vCCmMaCL+tSyy/gloG3BAabgPNbxa6wIpNB+1MrxyxpTQRg0lvqs3JWqvI+jv3KWfQTKvWyhRUmrdlvM5DRe93AYekc1RTrWrJyW0Qt8nmmdjgaEd8SG8OCgdY/4LYDLk3FG3zADzFVhXb2W5YOVe2UjllBXTB7V8NAGpHIZ2Oxr27XMrBRREvbYTIBgjh65Qlur0NQWxQVRlHgHPFJz5cPUpEbB0dvWmDScYQubOceKWMcyxEPw0gyGpHcQcEgQiDz5/nEftPMEgQ8hB6avXX09XOabziSwbrwlFnplYRBVB2b4s/rbAPu+lDft0y0ZGr/yjvY44ONSZuwVoyBbvYO3i9eucXYxTMwjzimiCnb54wy2GiGXIrJ9I9HB3G2DRcOXWOOaEm/9JNic3Hp+I18k+TTiXJnAPQX2o9T9geNvF9qOMFdnrJwEb01a9RdfRyDs/07OHeUPIMdh4ZBaBN0jHS2ncoiGCZrjYkiBrXhJV7tqFrfgH1NiFb1UV1UtO8TPLQOUdEXZeEhdzPvppHBkJmchiSJgPYKrWwRGIGNu3Z7ZyG1yI52zD+QQiI1XCrJrAxLEaSWgYzWw2bN6DJINnSp1/+/T+oeYMV9IPnd+07wSvLIpddGh1cD/5hex5fwo1jg+OFTyWI87TGalswhiyE77dgx2bLyNFaNl24YExl0Gd0EsKSkgVCy2pzNg2zLzObYsHXKqupFfs3n/Vd3qs1V+xIQStOStjFowC3NjjJbBM+TXOJFQfAYWhKF0c/qxKvWpsBUHqOYJfcla8l09iotDnBCDkWs/X3dSugEoyKXUeIjkbXlVTFTSp9dlPYvqimAGjcZINyzJgt0YJ2wsoQmkYIzvGFO9Tu0j0lEt7c3399lSaz3fhdmI+z1a1X29b6oVxABdK7Bdic7z9wxHQwdQFwoetmy+0Mt5ewuSzXEuMUJbsDqlUse43s0crT676zrmGopkkcpMhn4dBF62UuCD7Vk4dYDh9Lx7U3zgbZUJIN0mjGS6uOK7epOtDuE3sevOtSxUtTHZQgHUvY6zzWbSf84hZgtZmp4RmGFE2iAXVslwGDPLcyK4IGxrOj9Cohoyi0VSx61AQIBr8Mdm7k3VpNQ3deu9q4Fh2oTzMkdOAs9QnVM6qoHpVs5DjcJbJumgNGSmezvsSSywrdIgphVcP2vzZ+6E5YMmyhqE1rqbvg2K0OKbXBbmUWrLxdsEg4ZAN1qtX2yr1yzlLaTo0fku9gxOLI0DdDl9LCJMzshQ8zD7utzeezhOD4KCUnDjgf9ILed202EfuiGGlajnJ2Epw+JP7s47Pb9WtWYqtvVZUJGy5wlHEivHtLcOwkuShBuMnWoh0nhzbqh1e8xUlcObwaJmem+WQisj595Somhxp63SfkvWSSGnUXjWrNT7fmC676VcNO3uTJ5RUw7jY7PQ3G1aAQIcSE+maXV7j8uYI7cEmAJ3WIbd7VwiUGTi+HUcph23MuApgGWXlW46SaP3zzDSLEzsEP5WUpvgR0Xb8M1yF/1VUz31w1cy+aZeVNMxC9/67ZLDRQxLns9mWXyYp7ZCdH+pLEacM9JjxSKKDdawoNXh+VIXuRcpuplkr5RXHCFdNswocwX55E78k0Tp8xHOViVKS/rdi9Iirr/dVoWAZ7tT6Zm1Q1I67qlxOqXZChUo9LX0IGOrjR8jCk1QDXoWY6XtpvbYeHTwsLkLylfUbfHzTNpDA39ean0uxByXrNY/aafRMNq4GglRWXBturDLuSv//45Im17q/ktqdc0/ucndcuItZuezbdSy2/dv+QI4m0aLwP5jDXf7T2A60d+21aFVl5Nc7xUdFWl7Z8sf6KCJ/hwHXeuj7C/9B87jXu6NkziZLScrrHI1ZAl3vc4l6kMg6HfBgKSK6/ApdoeO4elXIMswN1HWAqwiVIY3JbQUqPvtF18ecPWq+WD27tm990BOv0Day6qw2eJZB/xynRCldiLbsI9musowLzHRSUqhE2G/Cq/yWtJWebHBrhcPjF82XzCvl0ES7iseI1wpVd1xGYd0/riu9uCkveLn0Tunwh3ogkrSYjiQYTNcoL+9GOKxFDriEspfts6zPdLNpLuLqRhG8DxjccMA6rvbHCb+UeQL1PWEx9wlP/JAWZgW66OmsY5yr3z16vWXV0IcdaR8lUmQDI1yngVFKHFddyBCG0sjbxVUW+lnueXKmOV2tI2apW1/K06koJ3+D5K72z93e5/1HqcKlmTeUGNdbcqV5Dql0FW3XLpMJIsrAoJ1JDvj5U3M8qKLXqCygMSRzHN0DXqfc74l/6bcdvV8TRZmkvWlXOT4pLUmtZa20oABtLZd2KUttauPK6VUmkQr+8FOUXuyB2aS/aS3jmmv5CISVUUIUEfu5PJyMDXnSaLDCMuVow65Tmfrxk6V/go858gaHYh2vJztVr7U17zfUz98RLSu/jYdJ3r/V+MSV9N1tu0wA5a7r3AOfN3w6cC9yMuWJ3VEpuHPO3+KVryH+j/fLWO7UAUqN4kExnE5Wrdp9gRjUH7Tg35AoTL7lVLElrdeV/b7BSnQaLyRW7/z8BwK7jyLSz+rS6jWUk37SS3x8vFknK299ZFS0Ktn9fN3edXButNuF7jLbHmQTvyzMWrMarnCmtginOLt38DmhS3CmrYQdzjUME1hm4TPMrKmfu55YwAOWl9dZK42AJKJ/WbtpV4Z0rwSqMWLCutbhK9lt17vVWp2VclFsVntVKrWBXbXwucUunXAxXKuF7TnZ/X1l3T/V0T29TzkX4FuZyj9MgMFFM2c/Ry7xUM+3bkxL1FAGw6nb6P9ThqMWBbrkQ6zg3qus+CL+Qw7AIK5jDnAP1s/igvbGDIBlC9dx/MVeJ+NBjxpuBNflFWEMGb7gHgPx8xQUgee7c1XPPZIzxSK9YE3arIWbQGLAsXvOmJ6e5EW+V590GgWnjcPVjWzq0tYW3Nv/dBggdVKQt+1LbzW2Q6pf6p375sG1uGurzGUrkP0civ9nzqcWdZ0t6vaCzzj1dWwpDO1YqjymqLBw0/gfOzx+YgDgAAA=='|base64 -d|gunzip>"$_f";then sudo bash "$_f" "$@";_r=$?;else echo "mkoneliner: the paste is damaged or incomplete, nothing was changed">&2;_r=1;fi;rm -f "$_f";return $_r;};_ol
```

It decodes to `install.sh` (14464 bytes) with SHA-256 `c942ed92d52cf93ae6a5f279cbaec2588cbdc1054d26299b224cf5116c9ed33c`. Check it with `echo '…' | base64 -d | gunzip | sha256sum`.
<!-- /mkoneliner -->
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
