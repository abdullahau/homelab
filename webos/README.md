# webOS — LG TV

Sideload Stremio onto an LG TV with the webOS CLI, and choose which machine
does the torrenting.

## Local values

Everything below uses these. Yours will differ.

| Name | Value | What it is |
| --- | --- | --- |
| The TV | `192.168.0.196` | LG `55NANO86VPA`, webOS 6.5.3 |
| The host | `192.168.0.100` | the Linux box running the Docker stack |
| Device alias | `Rehab-LG` | any label; `ares-setup-device` sets it |
| SSH alias | `tv` | a `Host` block in `dotfiles/ssh/config` |

"The host" means the Docker host: the machine running the Stremio streaming
server container, the one this repo configures.

## The TV

Read from `/var/run/nyx/` over SSH on 2026-09-22:

| Field | Value |
| --- | --- |
| Model | `55NANO86VPA` (2021 NanoCell) |
| webOS | 6.5.3 (`kisscurl-koli`, build 47) |
| Kernel | 4.4.84, `armv7l` |
| CPU | 2 cores, ARMv8 core in 32-bit mode |
| RAM | 2 GB |
| Free space | ~900 MB on `/media/developer` |
| Node on TV | v8.12.0 |

Two facts drive everything below.

The TV is a **2021** model, so webOS 6.5 runs a modern browser engine. It runs
the full Stremio app, not a web page in a frame.

The userspace is **32-bit** (`armv7l`), not `aarch64`. A 64-bit binary cannot
run. Every community Stremio build ships `arm64` ffmpeg, so each one needs a
repack. See [Mod 1](#mod-1-swap-ffmpeg-for-armhf).

## 1. Install the CLI

```bash
brew install node
npm install -g @webosose/ares-cli
ares-setup-device --list
```

`ares-cli` 2.4.0 works on Node 26.9.0. Older notes say to pin Node 20, because
`ssh2-streams` called `util.isDate`, which Node 23 removed. That fault no
longer appears. Drop back to Node 20 only if it returns.

## 2. Turn on Developer Mode

1. Create an LG developer account at <https://developer.lge.com>.
2. On the TV, install **Developer Mode** from the LG Content Store.
3. Open the app. Sign in with the same account.
4. Turn on **Dev Mode Status**. The TV reboots.
5. Reopen the app. Turn on **Key Server**.
6. Note the 6-character passphrase on screen.

The session lasts 1000 hours. Apps stay installed but refuse to launch once it
expires.

Extend it on the TV: reopen the Developer Mode app and press **Extend**.

Extend it from a terminal, with no remote. The TV keeps its session token in
`/var/luna/preferences/devmode_enabled`:

```bash
TOKEN=$(ssh tv cat /var/luna/preferences/devmode_enabled)
curl -s "https://developer.lge.com/secure/CheckDevModeSession.dev?sessionToken=$TOKEN"
curl -s "https://developer.lge.com/secure/ResetDevModeSession.dev?sessionToken=$TOKEN"
```

`Check` returns the time left in `errorMsg`, as `HHH:MM:SS`. `Reset` returns
`GNL` and sets the clock back to `999:59:59`.

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

Test it:

```bash
ares-install -d Rehab-LG --list
```

Use `-m` instead of `-a` to update a device that already exists. Toggling Dev
Mode off and on makes a new key and passphrase, so repeat this step.

`ares-device -i` does not work. A retail TV denies that Luna call.

The CLI stores the passphrase in plain text at
`~/.webos/ose/novacom-devices.json`.

## 4. Install Stremio

No stock release runs on this TV as published. `build-stremio.sh` downloads a
release, applies the mods and packages the result:

```bash
./build-stremio.sh --dual --install  # both servers, you choose in the app
./build-stremio.sh --install         # host only, the TV cannot torrent
./build-stremio.sh --wrapper         # the fallback wrapper instead
./build-stremio.sh --help
```

Install a package you already built:

```bash
ares-install -d Rehab-LG io.strem.webos_1.1.5_all.ipk
ares-launch -d Rehab-LG io.strem.webos
```

### Updating to a new release

```bash
./build-stremio.sh 1.2.0 --install
```

The script asserts every assumption and stops if upstream moved: a missing
service directory, an ffmpeg that is not 32-bit ARM, a changed `launch.js`
anchor, or a leftover hard-coded `127.0.0.1:11470`. A stop means read the new
`launch.js` before you trust the patch. It never installs a package it could
not verify.

### Why this build

It is a real Stremio app, not a page in a frame.

- It plays through the **native webOS media pipeline**. The TV decodes HEVC,
  10-bit and Dolby Vision in hardware. Nothing re-encodes.
- It ships its own **streaming server**, so the TV can serve alone if it has
  to. The build adds the host as a second option on another port.
- It picks the **audio track that matches your language**. Stock Stremio
  always takes the first track.

### Other builds considered

| Build | Verdict |
| --- | --- |
| [spcljense/stremio-webos](https://github.com/spcljense/stremio-webos) | **In use.** Native player, bundled server, active (1.1.5, Sep 2026). |
| [kieranbrown/stremio-webos](https://github.com/kieranbrown/stremio-webos) | Same idea, fewer fixes, last release May 2026. |
| [RazaGR/stremio-lg-tv](https://github.com/RazaGR/stremio-lg-tv) | Points the browser at `tv.strem.io`. No gain over the old wrapper. |
| [Balazsmi/Stremio-LG-TV](https://github.com/Balazsmi/Stremio-LG-TV) | The old wrapper. Kept as a fallback. |

### Packages

**Git tracks no `.ipk`.** `.gitignore` denies `*.ipk` outright. Download or
rebuild them instead.

| Package | Source | Rebuild with |
| --- | --- | --- |
| `io.strem.webos_1.1.5_all.ipk` | `gh release download v1.1.5 -R spcljense/stremio-webos` | `./build-stremio.sh` |
| `org.balazs.stremio-wrapper_1.0.0_nogit.ipk` | `gh release download v1.0.0 -R Balazsmi/Stremio-LG-TV` | `./build-stremio.sh --wrapper` |

The first **must** be rebuilt: the upstream release ships `arm64` ffmpeg and
points at its own server. The second installs as published; the repack only
strips 308 KB of the author's `.git` directory.

`build-stremio.sh` caches downloads in `build/`, which is also untracked.
Delete that directory to force a clean fetch.

## Two servers, two ports

`--dual` keeps the proxy aimed at the host **and** leaves the bundled server
running. Both are live, and you switch between them in the app:

| **Settings** → **Server** | Serves | Torrents on | Cache |
| --- | --- | --- | --- |
| `http://127.0.0.1:8080/` | host, 4.21.2 | **the host** | 2 GiB at `/docker/stremio` |
| `http://127.0.0.1:11470/` | bundled, 4.20.19 | **the TV** | none, `cacheSize` 0 |

Switch under **Settings** → **Server** → **EDIT_URL**. It takes effect at
once: no reinstall, no restart.

**Use the host (`8080`)** by default. It has the CPU, a 2 GiB cache that
survives a re-watch, and a wired link. The TV only decodes.

**Use the TV (`11470`)** when the host is down or rebooting, or to keep the
host off the swarm. It keeps no cache, so a re-watch downloads again, and the
TV's two ARM cores do the work.

Both direct-play. The choice only moves which machine talks to the swarm.

### Two things that catch you out

**The core defaults to `11470`.** A profile nobody has edited torrents on the
TV, and the app does not say so. Set the URL again after any profile reset, or
build with [Mod 3](#mod-3-optional-never-let-the-tv-serve), which removes the
choice and the trap together.

**Never enter `http://192.168.0.100:11470` directly.** The core then probes
the host cross-origin, the browser blocks it on CORS, and **Server** reads
**offline**. The loopback address is correct, because the proxy forwards.

### Which server is actually working

Neither the app nor **Settings** tells you reliably.

Which server answers each port:

```bash
for p in 8080 11470; do
  printf "%-6s " "$p"
  ssh tv "wget -qO- http://127.0.0.1:$p/settings" | grep -o '"cacheRoot":"[^"]*"'
done
```

`/config` is the host. A path under `/media/developer` is the TV.

Which machine holds the stream. Run this during playback. It is the decisive
check: a non-empty `selections` is the machine doing the work.

```bash
curl -s http://192.168.0.100:11470/stats.json | grep -o '"selections":\[[^]]*'
ssh tv 'wget -qO- http://127.0.0.1:11470/stats.json' | grep -o '"selections":\[[^]]*'
```

### Housekeeping

List what the host holds, and drop one:

```bash
curl -s http://192.168.0.100:11470/stats.json \
  | python3 -c 'import sys,json;[print(h[:12],len(v["selections"]),v["name"][:50]) for h,v in json.load(sys.stdin).items()]'

curl -s http://192.168.0.100:11470/<infoHash>/remove
```

`remove` drops the engine but leaves its pieces in
`/docker/stremio/stremio-cache/<infoHash>/`. Delete that directory to reclaim
the space. Eviction only runs against the 2 GiB `cacheSize`, so a finished
title can sit there for a long time.

## The mods

### Mod 1: swap ffmpeg for armhf

Every community build ships `arm64` ffmpeg, which a 32-bit userspace cannot
execute. `build-stremio.sh` swaps in the `armhf` static build from
<https://johnvansickle.com/ffmpeg/> and refuses to package unless both
binaries report 32-bit ARM.

Check a package by hand:

```bash
ar x io.strem.webos_1.1.5_all.ipk && tar xzf data.tar.gz
file usr/palm/services/io.strem.webos.server/bin/ffmpeg
# want:  ELF 32-bit LSB executable, ARM
# wrong: ELF 64-bit LSB executable, ARM aarch64
```

Confirm it on the TV after you install:

```bash
ssh tv '/media/developer/apps/usr/palm/services/io.strem.webos.server/bin/ffmpeg -version'
```

The download host throttles to around 10 KB/s. The script caches the tarball
in `build/` and checks its SHA-256, so it fetches it once.

### Mod 2: proxy to the host

`launch.js` serves the app on `127.0.0.1:8080` and forwards everything that is
not a static file. Mod 2 repoints that forward at the host. The page stays on
`8080`, so it is same-origin and CORS never applies.

The script inserts, after `var streamingReady = false;`:

```js
var UPSTREAM_HOST = '192.168.0.100';
var UPSTREAM_PORT = 11470;
```

and rewrites both proxy blocks, at about line 117 and line 179:

```js
forwardHeaders.host = UPSTREAM_HOST + ':' + UPSTREAM_PORT;
hostname: UPSTREAM_HOST,
port: UPSTREAM_PORT,
```

This moves the **proxy** only. It does not decide which server the app asks
for. That is the **Server** setting, above.

Editing the URL in **Settings** alone cannot fix the routing either.
`www/index.html` sets

```js
window.__STREMIO_SERVER_URL__ = 'http://127.0.0.1:8080';
```

and every webOS call reads `window.__STREMIO_SERVER_URL__ ||
settings.streamingServerUrl`. The global always wins, so those calls ignore
what you type, while the core still honours it for stream URLs. Aim the two
halves at different servers and playback breaks.

### Mod 3: optional, never let the TV serve

Not in use here. `--dual` is.

When the upstream is remote, Mod 3 never starts the bundled server, and
listens on `11470` itself:

```js
shadow = http.createServer(function(req, res) {
    proxyToStreaming(req, res);
});
shadow.listen(11470, '127.0.0.1');
```

Both ports then reach the host, so the **Server** setting cannot be wrong, and
about 100 MB of TV RAM is freed. The cost is that no local server remains.

### Why the split cannot be made safe

No layout gives both a correct default and a local fallback.

`server.js` hard-codes `port = 11470`, exposes no override, and calls itself
on that address. The core's default lives in `stremio_core_web_bg.wasm`. So
the bundled server must own the very port the core defaults to.

`UPSTREAM_HOST=127.0.0.1 ./build-stremio.sh` is a third case: it aims the
proxy at the TV as well, so both ports serve the TV and the host is
unreachable. Use it only to reproduce stock upstream behaviour.

## The old wrapper

`org.balazs.stremio-wrapper` is a 26 KB frame around `https://tv.strem.io`. It
needs no host and no patching, so keep it for when a rebuild goes wrong.

The upstream release ships the author's whole `.git` directory inside the app:
308 KB of the 384 KB installed. Build it stripped:

```bash
./build-stremio.sh --wrapper            # 81 KB -> 26 KB, 76 KB installed
./build-stremio.sh --wrapper --install
```

The script counts the `.git` files it removes and stops if any survive. If
upstream ever ships a clean release, it packages that as-is instead of
failing.

Stripping `.git` is the **only** change. The app itself is untouched.

It packages with `--no-minify`, so `main.js` stays byte-identical to upstream.
Without that flag `ares-package` runs its own minifier and rewrites the
back-button handler from `return void` to `if/else`. That runs the same, but
it is a needless difference.

Remove it with:

```bash
ares-install -d Rehab-LG -r org.balazs.stremio-wrapper
```

## Shell access

`ares-shell` is broken on retail TVs. It prepends `source /etc/profile`, which
the `prisoner` jail does not have. Use plain `ssh`:

```bash
ssh tv pwd        # /media/developer
```

The `tv` host block lives in the `dotfiles` repo at `ssh/config`. The TV offers
`ssh-rsa` host keys only, so that block sets `HostKeyAlgorithms +ssh-rsa` and
`PubkeyAcceptedKeyTypes +ssh-rsa`.

The key is passphrase-protected, so `ssh` asks for the 6 characters. Run
`ssh-add ~/.ssh/webos_rsa` to script against it. The shell is BusyBox: it has
no `/dev/tcp`, so probe ports with `wget`.

## How playback works

Whichever server you pick, the TV decodes and nothing re-encodes.

```
:8080   TV app --HTTP--> proxy --HTTP--> host:11470 --BitTorrent--> swarm
:11470  TV app --HTTP--> bundled server --BitTorrent--> swarm
```

The player hands the bytes to the native webOS pipeline either way, so a 4K
HEVC Dolby Vision file plays as 4K HEVC Dolby Vision.

The old wrapper could not do this. It used an HTML5 `<video>` tag in the TV
browser, so the host re-encoded every 4K release down to 1080p SDR H.264 and
dropped bitmap subtitles.

`transcodeMaxWidth` on the host stays at 1920. Direct play ignores it. It
applies only on a transcode fallback, and that CPU cannot encode 4K in real
time. See [Stremio](../README.md#stremio) for the measurements and the
download limits.

### Where the cache goes

| | Old wrapper | `--dual` on `:11470` | `--dual` on `:8080` |
| --- | --- | --- | --- |
| Torrent peer | the host | the TV | the host |
| Cache path | `/docker/stremio/stremio-cache` | `/media/developer/apps/...` | `/docker/stremio/stremio-cache` |
| Cache size | 2 GiB | 0, no retention | 2 GiB |

The TV keeps nothing, so a re-watch there downloads again. The host keeps
2 GiB, and a title stays cached until eviction needs the room.

## Privacy note

The TV holds a connection open to `96.47.5.165:4437`. The certificate is
`*.alphonso.tv` — Alphonso Inc., now LG Ads Solutions. This is LG's automatic
content recognition. It samples what is on screen for ad targeting.

Turn it off: **Settings → General → System → Additional Settings → Live Plus**
(off), and clear the ad agreements under **User Agreements**. Blocking
`*.alphonso.tv` at your DNS also works.

## Why not the LG Content Store app

Stremio ships an official webOS app for 2020 and later models, so this TV
qualifies. Some stores list it, such as Israel:
<https://il.lgappstv.com/main/tvapp/detail?appId=1214520>. Others do not.

You cannot sideload it. The Content Store serves signed packages to the TV
only, and Stremio publishes no `.ipk`: their GitHub holds `stremio-web`,
`stremio-core` and the desktop shells, and no webOS repo.

Changing the TV's country under **Settings → General → System → Location**
switches the store catalogue. It also resets apps and logins.

## Known issues

| Symptom | Cause | Fix |
| --- | --- | --- |
| `TypeError: isDate is not a function` | `ssh2-streams` calls `util.isDate`, removed in Node 23 | Use Node 20. Not seen on Node 26 with `ares-cli` 2.4.0 |
| `rm: can't remove '/media/developer/temp'` | Installer deletes a root-owned directory that `prisoner` cannot touch | In `lib/install.js`, clear the contents instead: `mkdir -p DIR && rm -rf DIR/*`. `npm update` undoes it |
| `can't open '/etc/profile'` | `ares-shell` assumes a login shell | Use `ssh` instead |
| `/hlsv2/*` returns 500 `no ffmpeg found` | 64-bit ffmpeg in the package cannot run | Repack with `armhf`. Direct play still works; only the transcode fallback breaks |
| A repacked app misbehaves, or its files differ from upstream for no reason | `ares-package` minifies JavaScript by default | Always pass `--no-minify`. It matters most for a hand-patched bundle, where re-minifying can undo the patch |
| Playback works, but the wrong machine is downloading | The **Server** setting points at the other port | See [Which server is actually working](#which-server-is-actually-working) |

## References

- `build-stremio.sh` — `--dual` for both servers, `--wrapper` for the fallback
- [spcljense/stremio-webos](https://github.com/spcljense/stremio-webos) — the app in use
- [webos-tools/cli](https://github.com/webos-tools/cli) — CLI source
- [CLI user guide](https://www.webosose.org/docs/tools/sdk/cli/cli-user-guide)
- [John Van Sickle ffmpeg builds](https://johnvansickle.com/ffmpeg/) — static `armhf`
