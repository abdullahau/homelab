# webOS — LG TV

Sideload Stremio onto an LG TV. The host torrents. The TV decodes.

## Local values

Yours will differ.

| Name | Value |
| --- | --- |
| The TV | `192.168.0.196`, LG `55NANO86VPA`, webOS 6.5.3 |
| The host | `192.168.0.100`, the box running the Docker stack |
| Device alias | `Rehab-LG` |
| SSH alias | `tv`, a `~/.ssh/config` block; see [step 3](#3-add-the-device-and-the-ssh-alias) |

## What the TV can do

Read over SSH on 2026-09-27.

| Field | Value |
| --- | --- |
| Model | `55NANO86VPA` (2021 NanoCell) |
| webOS / kernel | 6.5.3 (`kisscurl-koli` 47) / 4.4.84 `armv7l` |
| CPU / RAM | 2 cores, 32-bit / 1.88 GB, 169–374 MB free |
| Free space | 803 MB on `/media/developer` |
| `eth0` | 100 Mbit, full duplex |
| Hardware decode | HEVC, VP9, AV1, 10-bit, Dolby Vision |
| Node on TV | v8.12.0 |

Three facts drive this setup.

1. The TV is a 2021 model. It runs the full Stremio app, not a web page.
2. The userspace is 32-bit. A 64-bit binary cannot run. See [Mod 2](#mod-2-give-the-tv-an-ffmpeg-it-can-run).
3. The TV decodes AV1 in hardware (`OMX.MS.AV1.Decoder`). Codecs are never the
   problem. The torrent swarm usually is.

## 1. Install the CLI

```bash
brew install node
npm install -g @webosose/ares-cli
```

`ares-cli` 2.4.0 works on Node 26.9.0.

## 2. Turn on Developer Mode

1. Create an LG developer account at <https://developer.lge.com>.
2. On the TV, install **Developer Mode** from the LG Content Store.
3. Open the app. Sign in.
4. Turn on **Dev Mode Status**. The TV reboots.
5. Reopen the app. Turn on **Key Server**.
6. Note the 6-character passphrase.

The session lasts 1000 hours. Apps stay installed but refuse to launch once it
expires. Press **Extend** in the app, or from a terminal:

```bash
TOKEN=$(ssh tv cat /var/luna/preferences/devmode_enabled)
curl -s "https://developer.lge.com/secure/CheckDevModeSession.dev?sessionToken=$TOKEN"
curl -s "https://developer.lge.com/secure/ResetDevModeSession.dev?sessionToken=$TOKEN"
```

`Check` returns the time left. `Reset` sets it to `999:59:59`.

## 3. Add the device and the SSH alias

```bash
curl -o ~/.ssh/webos_rsa http://192.168.0.196:9991/webos_rsa
chmod 600 ~/.ssh/webos_rsa
```

Add this to `~/.ssh/config`. Every `ssh tv` below needs it. The TV offers
`ssh-rsa` host keys only, which OpenSSH 8.8 and later refuse, so both
`+ssh-rsa` lines are required:

```sshconfig
Host tv 192.168.0.196
  HostName 192.168.0.196
  Port 9922
  User prisoner
  IdentityFile ~/.ssh/webos_rsa
  AddKeysToAgent yes
  HostKeyAlgorithms +ssh-rsa
  PubkeyAcceptedKeyTypes +ssh-rsa
  HostKeyAlias lg-tv
```

This repo keeps that block in `dotfiles/ssh/config`.

```bash
ares-setup-device -a Rehab-LG \
  -i "host=192.168.0.196" -i "port=9922" -i "username=prisoner" \
  -i "privatekey=webos_rsa" -i "passphrase=XXXXXX"
ares-install -d Rehab-LG --list
```

Use `-m` instead of `-a` for an existing device. Toggling Dev Mode makes a new
key and passphrase, so repeat this step. The CLI stores the passphrase in plain
text at `~/.webos/ose/novacom-devices.json`.

Run `ssh-add ~/.ssh/webos_rsa` once per session. The script's post-install
check needs it. The TV shell is BusyBox with no `/dev/tcp`, so probe ports with
`wget`. `ares-shell` and `ares-device -i` do not work on a retail TV.

## 4. Install Stremio

No stock release runs on this TV. `build-stremio.sh` downloads a release,
applies the mods and packages the result:

```bash
./build-stremio.sh --install              # recommended: host only
./build-stremio.sh --install --no-launch  # same, but do not open the app
./build-stremio.sh --dual                 # keep the TV server too
./build-stremio.sh --wrapper              # the fallback wrapper
./build-stremio.sh 1.2.0 --install        # another release
./build-stremio.sh --help
```

Use `--no-launch` when someone watches something else on the TV.

The script asserts every assumption and stops if upstream moved. A stop means
read the new `launch.js` before you trust the patch.

## 5. Set the Server URL

Open **Settings** → **Server** → **EDIT_URL** and enter:

```
http://127.0.0.1:11470/
```

**Do this even under Mod 1.** Playback works on either port. The app's
`/tracks` and `/opensubHash` calls do not. They pass the stream URL to the
host, and the host fetches it from inside its own container:

| Server setting | The host fetches | Result |
| --- | --- | --- |
| `127.0.0.1:11470` | its own Stremio server | correct |
| `127.0.0.1:8080` | `glance`, on the host's port 8080 | `Failed to retrieve Content-Range` |

On `8080` you lose audio-language matching and subtitle hashing, and the player
re-probes the stream, which wastes the torrent buffer.

**Never enter `http://192.168.0.100:11470`.** The core then probes the host
cross-origin, the browser blocks it on CORS, and **Server** reads **offline**.
The loopback address is correct, because the proxy forwards.

### Which build

`spcljense/stremio-webos` is a real Stremio app, not a page in a frame. It
plays through the native webOS pipeline, so nothing re-encodes.

| Build | Verdict |
| --- | --- |
| [spcljense](https://github.com/spcljense/stremio-webos) | **In use.** v1.1.5, pushed 2026-09-26 |
| [kieranbrown](https://github.com/kieranbrown/stremio-webos) | Same design, more stars, but v1.0.3 from May 2026. Ships `arm64` ffmpeg, and its `launch.js` lacks this repo's patch anchors |
| [RazaGR](https://github.com/RazaGR/stremio-lg-tv) | Points a browser at `tv.strem.io` |
| [Balazsmi](https://github.com/Balazsmi/Stremio-LG-TV) | The old wrapper. Kept as a fallback |

**Git tracks no `.ipk`.** Rebuild them, or download:

```bash
gh release download v1.1.5 -R spcljense/stremio-webos
gh release download v1.0.0 -R Balazsmi/Stremio-LG-TV
```

Downloads cache in `build/`, which is untracked.

## The mods

### Mod 1: send all traffic to the host

The default, and the one to use. Mod 1 repoints the proxy at the host, stops
the bundled server, and listens on 11470 itself. Both `127.0.0.1:8080` and
`127.0.0.1:11470` then reach the host, so the TV cannot torrent.

Use this path for 4K HDR. The host has a 1 Gbps link, a 2 GiB cache and a
100 Mbps torrent cap. The TV receives one HTTP flow at the file's bitrate, so
an 80 Mbps remux fits its 100 Mbit link.

The page stays on `8080`, so it is same-origin and CORS never applies.

### Mod 2: give the TV an ffmpeg it can run

Every community build ships `arm64` ffmpeg, which a 32-bit userspace cannot
execute. The script swaps in the `armhf` static build from
<https://johnvansickle.com/ffmpeg/>. It refuses to package unless both binaries
report 32-bit ARM. That download is slow and stalls often, so the script
resumes across five attempts and gates on the SHA-256.

Mod 1 stops the bundled server, so nothing runs these binaries. They cost about
35 MB of the TV's 803 MB free space. They matter only with `--dual`.

### Mod 3: raise the TV's download caps

Applies only when the bundled server can run, so with `--dual` or a loopback
upstream. Mod 1 skips it.

The bundled server ships a low-power profile. It caps its own download far
below 4K:

| Setting | Bundled default | Mod 3 | The host |
| --- | --- | --- | --- |
| `btDownloadSpeedSoftLimit` | 2621440 (21 Mbps) | 6291456 (50 Mbps) | 12582912 (100 Mbps) |
| `btDownloadSpeedHardLimit` | 3670016 (29 Mbps) | 8388608 (67 Mbps) | 20971520 (168 Mbps) |

A 4K HDR encode runs 25 to 50 Mbps. A remux runs 50 to 100 Mbps. At 29 Mbps the
TV can never fill one, and `cacheSize` is 0, so no buffer hides the shortfall.

Override the values, but leave headroom. `eth0` carries swarm upload too:

```bash
TV_SOFT_LIMIT=8388608 TV_HARD_LIMIT=10485760 ./build-stremio.sh --dual
```

Mod 3 changes **defaults**. A `server-settings.json` left on the TV overrides
them, so the script deletes it during `--install`. By hand:

```bash
ssh tv rm -f /media/developer/apps/usr/palm/services/io.strem.webos.server/server-settings.json
```

`cacheSize` stays 0. A real cache does not fit in 803 MB.

## The cost of --dual

`--dual` keeps the bundled server, so you choose the torrent peer:

| Server setting | Serves | Torrents on | Cache |
| --- | --- | --- | --- |
| `http://127.0.0.1:8080/` | host, 4.21.2 | the host | 2 GiB at `/docker/stremio` |
| `http://127.0.0.1:11470/` | bundled, 4.20.19 | the TV | none, `cacheSize` 0 |

Neither port is clean.

- **The core defaults to `11470`.** An unedited profile torrents on the TV, and
  the app does not say so.
- **On `11470` the host torrents too.** The `/tracks` call reaches the host,
  and `127.0.0.1:11470` inside the container is its own server. So the host
  joins every swarm you open and downloads files it never serves. Measured on
  2026-09-27: 1.7 GB in 16 minutes, including 1.2 GB of one title.
- **On `8080` track enumeration breaks.** See [step 5](#5-set-the-server-url).

Mod 1 removes the first two. It is why `--dual` is not the default.

No split is safe. `server.js` hard-codes `port = 11470` and exposes no
override, and the core's default lives in `stremio_core_web_bg.wasm`. So the
bundled server must own the very port the core defaults to.

## Diagnosing

Which server answers each port. `/config` is the host, `/media/developer` is
the TV. Under Mod 1 you want `/config` on both:

```bash
for p in 8080 11470; do
  printf "%-6s " "$p"
  ssh tv "wget -qO- http://127.0.0.1:$p/settings" | grep -o '"cacheRoot":"[^"]*"'
done
```

Which **Server** setting the app really uses. Watch the port inside the
`/tracks` URL during playback:

```bash
docker logs -f stremio 2>&1 | grep tracks
```

How the swarm is doing. Run this during playback:

```bash
curl -s http://192.168.0.100:11470/stats.json | python3 -c '
import sys,json
for h,v in json.load(sys.stdin).items():
    print("%s peers=%-3s down=%6.1f Mbps tries=%-6s %s" % (h[:12], v.get("peers",0),
        v.get("downloadSpeed",0)/125000.0, v.get("connectionTries",0), v.get("name","")[:50]))'
```

`peers` far below `connectionTries` means the swarm is unreachable, not slow.
Behind CGNAT the host takes no inbound connections, so a thinly seeded 4K
release can reach 0 peers after thousands of attempts. Pick a better-seeded
release, or raise `btMaxConnections` above 55.

Drop a stale engine, which stops it wasting connection attempts:

```bash
curl -s http://192.168.0.100:11470/<infoHash>/remove
```

`remove` leaves the pieces in `/docker/stremio/stremio-cache/<infoHash>/`.
Delete that directory to reclaim the space. Eviction only runs against the
2 GiB `cacheSize`, so finished titles can sit there for a long time.

## How playback works

The TV decodes and nothing re-encodes, so a 4K HEVC Dolby Vision file plays as
4K HEVC Dolby Vision.

```
:8080   TV app --HTTP--> proxy --HTTP--> host:11470 --BitTorrent--> swarm
:11470  TV app --HTTP--> bundled server --BitTorrent--> swarm     (--dual only)
```

`transcodeMaxWidth` on the host stays at 1920. Direct play ignores it. It
applies only on a transcode fallback, and that CPU cannot encode 4K in real
time. See [Stremio](../README.md#stremio) for the measurements.

| | Mod 1 | `--dual` on `:11470` |
| --- | --- | --- |
| Torrent peer | the host | the TV |
| Cache path | `/docker/stremio/stremio-cache` | `/media/developer/apps/...` |
| Cache size | 2 GiB | 0, no retention |

## The old wrapper

`org.balazs.stremio-wrapper` is a 26 KB frame around `https://tv.strem.io`. It
needs no host and no patching. Keep it for when a rebuild goes wrong. The
upstream release ships the author's `.git` directory, 308 KB of the 384 KB
installed. The script strips it, and that is the only change.

```bash
./build-stremio.sh --wrapper --install
ares-install -d Rehab-LG -r org.balazs.stremio-wrapper   # remove it
```

## Privacy note

The TV holds a connection open to `96.47.5.165:4437`, certificate
`*.alphonso.tv` — LG Ads Solutions. This is automatic content recognition. It
samples what is on screen for ad targeting.

Turn it off under **Settings → General → System → Additional Settings → Live
Plus**, and clear the ad agreements under **User Agreements**. Blocking
`*.alphonso.tv` at your DNS also works.

## Why not the LG Content Store app

Stremio ships an official webOS app for 2020 and later models, but you cannot
sideload it. The Content Store serves signed packages to the TV only, and
Stremio publishes no `.ipk`. Changing the TV's country switches the catalogue,
and also resets apps and logins.

## Known issues

| Symptom | Cause | Fix |
| --- | --- | --- |
| A 4K release crawls, `peers` near 0 | the swarm is unreachable, not slow. CGNAT blocks inbound peers | Pick a better-seeded release. Raise `btMaxConnections`. Drop stale engines |
| Wrong audio language; `Failed to retrieve Content-Range` | **Server** is `8080`, so `/tracks` hits `glance` | Set **Server** to `11470`; see [step 5](#5-set-the-server-url) |
| 4K HDR stutters when the TV torrents | the bundled server caps itself at 29 Mbps | Use Mod 1, or apply [Mod 3](#mod-3-raise-the-tvs-download-caps) |
| Mod 3 has no effect | a stale `server-settings.json` overrides the new defaults | Delete it; see [Mod 3](#mod-3-raise-the-tvs-download-caps) |
| The host downloads titles it never plays | `/tracks` on `11470` makes the host join the swarm | Use Mod 1 |
| `TypeError: isDate is not a function` | `ssh2-streams` calls `util.isDate`, removed in Node 23 | Use Node 20 |
| `rm: can't remove '/media/developer/temp'` | the installer deletes a root-owned directory | In `lib/install.js`, clear the contents instead. `npm update` undoes it |
| `/hlsv2/*` returns 500 `no ffmpeg found` | 64-bit ffmpeg cannot run | Repack with `armhf`. Direct play still works |
| A repacked app misbehaves | `ares-package` minifies JavaScript by default | Always pass `--no-minify` |

## References

- `build-stremio.sh` — `--help` lists the flags
- [spcljense/stremio-webos](https://github.com/spcljense/stremio-webos) — the app in use
- [webos-tools/cli](https://github.com/webos-tools/cli) — CLI source
- [CLI user guide](https://www.webosose.org/docs/tools/sdk/cli/cli-user-guide)
- [John Van Sickle ffmpeg builds](https://johnvansickle.com/ffmpeg/) — static `armhf`
