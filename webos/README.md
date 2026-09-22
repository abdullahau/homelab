# webOS — LG TV

Sideload apps onto the LG TV (`Rehab-LG`, `192.168.0.196`) with the webOS CLI.

## 1. Install the CLI

Needs Node 20. Node 23 and later removed `util.isDate`, which `ares-cli` still
calls. See [Known issues](#known-issues).

```bash
npm install -g @webosose/ares-cli
ares-setup-device --list
```

## 2. Turn on Developer Mode on the TV

1. Create an LG developer account at <https://developer.lge.com>.
2. On the TV, install **Developer Mode** from the LG Content Store.
3. Open the app. Sign in with the same account.
4. Turn on **Dev Mode Status**. The TV reboots.
5. Reopen the app. Turn on **Key Server**.
6. Note the 6-character passphrase on screen.

The session lasts 1000 hours. Reopen the app and press **Extend** before it
ends. Apps stay installed but refuse to launch once it expires.

## 3. Add the device

Fetch the key. The TV serves it on port 9991:

```bash
curl -o ~/.ssh/webos_rsa http://192.168.0.196:9991/webos_rsa
chmod 600 ~/.ssh/webos_rsa
```

Register the device. The account is always `prisoner`, never `root`:

```bash
ares-setup-device -a Rehab-LG \
  -i "host=192.168.0.196" -i "port=9922" -i "username=prisoner" \
  -i "privatekey=webos_rsa" -i "passphrase=XXXXXX"
```

Test it. An empty list means the connection works:

```bash
ares-install -d Rehab-LG --list
```

Use `-m` instead of `-a` to update a device that already exists. Toggling Dev
Mode off and on makes a new key and passphrase, so repeat this step.

`ares-device -i` does not work here. A retail TV denies that Luna call.

## 4. Install Stremio

Use the repacked file in this folder:

```bash
ares-install -d Rehab-LG org.balazs.stremio-wrapper_1.0.0_nogit.ipk
ares-install -d Rehab-LG --list
ares-launch -d Rehab-LG org.balazs.stremio-wrapper
```

The app is an iframe wrapper around `https://tv.strem.io`. Nothing else.

### Repacking

The upstream release ships the author's whole `.git` directory inside the app:
308 KB of the 384 KB installed. Strip it and rebuild:

```bash
gh release download v1.0.0 -R Balazsmi/Stremio-LG-TV
ar x org.balazs.stremio-wrapper_1.0.0_all.ipk
mkdir -p d && tar xzf data.tar.gz -C d
cp -a d/usr/palm/applications/org.balazs.stremio-wrapper app
rm -rf app/.git
ares-package app -o .
```

Result: 26 KB instead of 81 KB. Installed size drops to 76 KB.

## Shell access

`ares-shell` is broken on retail TVs. It prepends `source /etc/profile`, which
the `prisoner` jail does not have. Use plain `ssh` instead:

```bash
ssh tv pwd        # /media/developer
```

The `tv` host block lives in the `dotfiles` repo at `ssh/config`. The TV offers
`ssh-rsa` host keys only, so that block sets `HostKeyAlgorithms +ssh-rsa` and
`PubkeyAcceptedKeyTypes +ssh-rsa`.

## How playback works

The TV never torrents. The `stremio` container on the homelab does.

```
TV (browser, iframe)  --HTTP-->  homelab:11470  --BitTorrent-->  swarm
```

The TV holds only HTTP connections to `192.168.0.100:11470`. A sandboxed web
page cannot open raw BitTorrent sockets. Downloaded pieces land in
`/docker/stremio/stremio-cache`, capped at 2 GB by `cacheSize`.

### Why the server re-encodes

The player is an HTML5 `<video>` tag in the TV browser, not a real media player.
It plays very little. A typical 2160p release forces a full re-encode:

| Stream | Source | Result |
| --- | --- | --- |
| Container | Matroska (`.mkv`) | repackaged to fMP4/HLS |
| Video | HEVC Main 10, 3840x1608, Dolby Vision | re-encoded to H.264 1920 wide, 8-bit, SDR |
| Audio | E-AC-3 5.1 (DD+ Atmos) | re-encoded to AAC 5.1 |
| Subtitles | PGS (bitmap) | dropped |

The live `ffmpeg` command proves it:

```
-vf scale=1920:-2:flags=lanczos,format=yuv420p,setparams=...bt709
-c:v libx264 -preset:v ultrafast
-c:a aac -ac:a 6
```

So a 4K Dolby Vision file reaches the TV as 1080p SDR H.264, encoded at the
`ultrafast` preset. It costs about 30% CPU, with `transcodeHardwareAccel: false`.

### What plays with no re-encode

An **MP4 container with H.264 video and AAC audio**. The browser plays that
natively, so the server passes the bytes through untouched.

Prefer `1080p x264 WEB-DL` releases. A `2160p x265 REMUX` gains you nothing
here: it is downscaled and tone-mapped anyway, and costs CPU to do it.

Raising `transcodeMaxWidth` to 3840 only removes the downscale. HEVC, 10-bit
and E-AC-3 still force a re-encode. The real fix for 4K HDR is a native Stremio
client with a real player, not this browser wrapper.

## Privacy note

The TV keeps a connection open to `96.47.5.165:4437`. The certificate is
`*.alphonso.tv` — Alphonso Inc., now LG Ads Solutions. This is LG's automatic
content recognition. It samples what is on screen for ad targeting.

Turn it off on the TV: **Settings → General → System → Additional Settings →
Live Plus** (off), and clear the ad agreements under **User Agreements**.
Blocking `*.alphonso.tv` in AdGuard Home also works.

## Known issues

Three bugs in `ares-cli` 2.4.0. Node 20 fixes the first. The other two need
edits inside the installed package, which `npm update` undoes.

| Symptom | Cause | Fix |
| --- | --- | --- |
| `TypeError: isDate is not a function` | `ssh2-streams` calls `util.isDate`, removed in Node 23 | Use Node 20 |
| `rm: can't remove '/media/developer/temp'` | Installer deletes a root-owned directory that `prisoner` cannot touch | In `lib/install.js`, clear the contents instead: `mkdir -p DIR && rm -rf DIR/*` |
| `can't open '/etc/profile'` | `ares-shell` assumes a login shell | Use `ssh` instead |

## References

- [Balazsmi/Stremio-LG-TV](https://github.com/Balazsmi/Stremio-LG-TV) — the Stremio `.ipk`
- [webos-tools/cli](https://github.com/webos-tools/cli) — CLI source
- [CLI user guide](https://www.webosose.org/docs/tools/sdk/cli/cli-user-guide)
