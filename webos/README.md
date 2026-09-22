# webOS — LG TV

Sideload apps onto the LG TV with the webOS CLI.

## The TV

Read from `/var/run/nyx/` over SSH on 2026-09-22:

| Field | Value |
| --- | --- |
| Model | `55NANO86VPA` (2021 NanoCell) |
| Device alias | `Rehab-LG`, `192.168.0.196` |
| webOS | 6.5.3 (`kisscurl-koli`, build 47) |
| Kernel | 4.4.84, `armv7l` |
| CPU | 2 cores, ARMv8 core in 32-bit mode |
| RAM | 2 GB |
| Free space | ~900 MB on `/media/developer` |
| Node on TV | v8.12.0 |

Two points drive everything below.

The TV is a **2021** model, so webOS 6.5 runs a modern browser engine. It can
run the full Stremio app, not just a web page in a frame.

The userspace is **32-bit** (`armv7l`), not `aarch64`. A 64-bit binary does
not run here. Every community Stremio build ships `arm64` ffmpeg, so each one
needs a repack. See [Mod 1](#mod-1-swap-ffmpeg-for-armhf).

## 1. Install the CLI

```bash
brew install node
npm install -g @webosose/ares-cli
ares-setup-device --list
```

`ares-cli` 2.4.0 works on Node 26.9.0 here. Older notes say to pin Node 20,
because `ssh2-streams` called `util.isDate`, which Node 23 removed. That fault
no longer appears. Drop back to Node 20 only if it returns.

## 2. Turn on Developer Mode on the TV

1. Create an LG developer account at <https://developer.lge.com>.
2. On the TV, install **Developer Mode** from the LG Content Store.
3. Open the app. Sign in with the same account.
4. Turn on **Dev Mode Status**. The TV reboots.
5. Reopen the app. Turn on **Key Server**.
6. Note the 6-character passphrase on screen.

The session lasts 1000 hours. Apps stay installed but refuse to launch once
it expires.

Extend it from the TV: reopen the Developer Mode app and press **Extend**.

Extend it from here, with no remote: the TV keeps its session token in
`/var/luna/preferences/devmode_enabled`.

```bash
TOKEN=$(ssh tv cat /var/luna/preferences/devmode_enabled)
curl -s "https://developer.lge.com/secure/CheckDevModeSession.dev?sessionToken=$TOKEN"
curl -s "https://developer.lge.com/secure/ResetDevModeSession.dev?sessionToken=$TOKEN"
```

`Check` returns the time left in `errorMsg`, as `HHH:MM:SS`. `Reset` returns
`GNL` and puts the clock back to `999:59:59`. Extended on 2026-09-22.

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

`ares-device -i` does not work here. A retail TV denies that Luna call.

The CLI stores the passphrase in plain text at
`~/.webos/ose/novacom-devices.json`.

## 4. Install Stremio

No stock release runs on this TV as published. `build-stremio.sh` downloads a
release, applies all three mods and packages the result:

```bash
./build-stremio.sh --dual --install  # what this TV runs
./build-stremio.sh --install         # homelab only, TV cannot torrent
./build-stremio.sh --wrapper         # the fallback wrapper instead
./build-stremio.sh --help
```

This TV runs the `--dual` build, so set the server by hand:

**Settings** → **Server** → **EDIT_URL** → `http://127.0.0.1:8080/`

Leave it on the default `11470` and the **TV** torrents instead of the
homelab. See [The dual layout](#the-dual-layout).

To install a package you already built:

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
not fully verify.

### Why this build

It is a real Stremio app, not a page in a frame. Three things matter:

- It plays through the **native webOS media pipeline**. The TV decodes HEVC,
  10-bit and Dolby Vision in hardware. Nothing re-encodes.
- It ships its own **Stremio streaming server**, so it needs nothing else to
  work. We repoint it at the homelab instead. See
  [Mod 2](#mod-2-point-it-at-the-homelab).
- It picks the **audio track that matches your language**. Stock Stremio
  always takes the first track.

Verified on the TV after install:

```
frontend on 127.0.0.1:8080
proxy :8080 -> 192.168.0.100:11470, server 4.21.2, cache 2 GiB
ffmpeg 7.0.2-static, armhf, runs
```

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

The wrapper is the fallback. Keep it. It needs no homelab server and no
patching, so it is the thing to reach for when a rebuild goes wrong.

`build-stremio.sh` caches downloads in `build/`, which is also untracked.
Delete that directory to force a clean fetch.

### Mod 1: swap ffmpeg for armhf

Every community build ships `arm64` ffmpeg. This TV runs a 32-bit userspace,
so those binaries cannot execute. `build-stremio.sh` swaps in the `armhf`
static build from <https://johnvansickle.com/ffmpeg/> and refuses to package
unless both binaries report 32-bit ARM.

To check a package by hand, before or after:

```bash
ar x io.strem.webos_1.1.5_all.ipk && tar xzf data.tar.gz
file usr/palm/services/io.strem.webos.server/bin/ffmpeg
# want: ELF 32-bit LSB executable, ARM
# wrong: ELF 64-bit LSB executable, ARM aarch64
```

Confirm it on the TV after you install:

```bash
ssh tv '/media/developer/apps/usr/palm/services/io.strem.webos.server/bin/ffmpeg -version'
```

The download host throttles to around 10 KB/s. The script caches the tarball
in `build/` and checks its SHA-256, so it fetches it once.

### Mod 2: point it at the homelab

By default the app talks to the server it bundles, so the **TV** joins the
torrent swarm and caches to its own 900 MB of free space.

You cannot fix this in **Settings**. `www/index.html` sets

```js
window.__STREMIO_SERVER_URL__ = 'http://127.0.0.1:8080';
```

and every webOS call reads `window.__STREMIO_SERVER_URL__ ||
settings.streamingServerUrl`. The global always wins, so the app skips the URL
you type. The core still honours it when it builds stream URLs, so you end up
with streams aimed at one server and `/heartbeat` and `/tracks/` aimed at the
other. That split is why it fails.

Pointing the app straight at `http://192.168.0.100:11470` also trips CORS. The
Stremio server sends `Access-Control-Allow-Origin` on `/stats.json` only, not
on `/heartbeat`, `/settings` or the `OPTIONS` preflight.

Fix it in the proxy instead. `launch.js` already forwards everything that is
not a static file. Repoint that forward and the page stays on
`127.0.0.1:8080`, so it is same-origin and CORS never applies.

`build-stremio.sh` does this. It inserts, after `var streamingReady = false;`:

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

Keep the server on the TV instead with `UPSTREAM_HOST=127.0.0.1
./build-stremio.sh`.

### Mod 3: never let the TV serve

Mod 2 alone is not enough, and this cost a real evening of confusion.

The core builds stream URLs from **Settings** → **Server**, which defaults to
`http://127.0.0.1:11470` — the bundled server. Leave that untouched and the
app bypasses the proxy completely: the **TV** joins the swarm while the
homelab sits idle. It looks like it works, because it does work. It just
works on the wrong machine.

Setting it to `http://127.0.0.1:8080/` by hand fixes it. Pointing it at
`192.168.0.100:11470` does not: the core then probes the homelab
cross-origin, the browser blocks it on CORS, and **Server** reads
**offline**.

**Not in use here.** See [The dual layout](#the-dual-layout) for what is
installed and why.

Mod 3 removes the choice. When the upstream is remote it never starts the
bundled server, and it listens on `11470` itself, proxying to the upstream:

```js
shadow = http.createServer(function(req, res) {
    proxyToStreaming(req, res);
});
shadow.listen(11470, '127.0.0.1');
```

Both addresses now reach the homelab, so the **Server** setting cannot be
wrong. The TV cannot torrent even by accident, and the idle bundled server
no longer costs about 100 MB of RAM.

### The dual layout

`--dual` is what runs on this TV. It keeps the upstream remote but leaves the
bundled server alone, so both servers exist and you pick between them:

```bash
./build-stremio.sh --dual --install
```

| Port | Server | Torrents on | Cache |
| --- | --- | --- | --- |
| `127.0.0.1:8080` | 4.21.2 | homelab | 2 GiB at `/docker/stremio` |
| `127.0.0.1:11470` | 4.20.19 | the TV | none, `cacheSize` 0 |

Choose under **Settings** → **Server** → **EDIT_URL**. Use
`http://127.0.0.1:8080/` for the homelab.

The catch is unchanged, and it is the reason Mod 3 exists: the core
**defaults to 11470**, so a profile nobody has edited torrents on the TV
without saying so. Verified on 2026-09-22 — the TV had pulled a whole season
while the homelab sat idle.

`UPSTREAM_HOST=127.0.0.1 ./build-stremio.sh` is a different thing again. It
points the proxy at the TV as well, so both ports serve the TV and the
homelab is unreachable. Use it only to reproduce stock upstream behaviour.

### Which server is actually working

Neither the app nor **Settings** tells you reliably. Check during playback.
The machine with a non-empty `selections` is doing the work:

```bash
curl -s http://192.168.0.100:11470/stats.json | grep -o '"selections":\[[^]]*'
ssh tv 'wget -qO- http://127.0.0.1:11470/stats.json' | grep -o '"selections":\[[^]]*'
```

Check which server answers after you install. With Mod 3, **both** ports must
report the homelab:

```bash
for p in 8080 11470; do
  ssh tv "wget -qO- http://127.0.0.1:$p/settings" \
    | grep -o '"serverVersion":"[^"]*"\|"cacheRoot":"[^"]*"'
done
```

The homelab runs 4.21.2 with `cacheRoot` `/config`. The bundled server runs
4.20.19 with a path under `/media/developer`. Seeing `/media/developer` on
either port means the TV is serving, and it will torrent.

The decisive check is which machine holds the stream while you watch:

```bash
curl -s http://192.168.0.100:11470/stats.json | grep -o '"selections":\[[^]]*'
ssh tv 'wget -qO- http://127.0.0.1:11470/stats.json' | grep -o '"selections":\[[^]]*'
```

A non-empty `selections` is the machine doing the work. It must be the
homelab.

Under Mod 3 the bundled server never starts, which frees about 100 MB of RAM
but leaves no local fallback. Under `--dual` it does start, so the TV can
still serve if the homelab is down. That is the trade you are making.

## The old wrapper

`org.balazs.stremio-wrapper` is still installed. It is a 26 KB frame around
`https://tv.strem.io`. It needs no homelab server and no patching, so keep
it as the fallback when a rebuild goes wrong.

The upstream release ships the author's whole `.git` directory inside the
app: 308 KB of the 384 KB installed. Build it with that stripped:

```bash
./build-stremio.sh --wrapper            # 81 KB -> 26 KB, 76 KB installed
./build-stremio.sh --wrapper --install
```

The script counts the `.git` files it removes and stops if any survive. It
also handles upstream fixing this one day: no `.git` means it packages the
release as-is instead of failing.

Stripping `.git` is the **only** change to this package. The app itself is
untouched: an iframe on `https://tv.strem.io`, nothing more.

It packages with `--no-minify`, so `main.js` stays byte-identical to
upstream. Built without that flag, `ares-package` runs its own minifier and
rewrites the back-button handler from `return void` to `if/else`. That runs
the same, but it is a needless difference. Reproduced both ways on
2026-09-22.

Remove it with:

```bash
ares-install -d Rehab-LG -r org.balazs.stremio-wrapper
```

## Shell access

`ares-shell` is broken on retail TVs. It prepends `source /etc/profile`, which
the `prisoner` jail does not have. Use plain `ssh` instead:

```bash
ssh tv pwd        # /media/developer
```

The `tv` host block lives in the `dotfiles` repo at `ssh/config`. The TV offers
`ssh-rsa` host keys only, so that block sets `HostKeyAlgorithms +ssh-rsa` and
`PubkeyAcceptedKeyTypes +ssh-rsa`.

The key is passphrase-protected, so `ssh` asks for the 6 characters. The shell
is BusyBox. It has no `/dev/tcp`, so probe ports with `wget` instead.

## How playback works

The homelab fetches. The TV decodes.

```
TV: app + proxy (:8080)  --HTTP-->  homelab:11470  --BitTorrent-->  swarm
TV: player  <--direct file--  proxy
```

The player hands the file to the native webOS pipeline, so the TV decodes it
as-is. A 4K HEVC Dolby Vision file plays as 4K HEVC Dolby Vision.

Every call rides the proxy, so the page never leaves its own origin. That is
what keeps CORS out of the picture.

The old wrapper could not do this. It used an HTML5 `<video>` tag in the TV
browser, so the homelab server re-encoded every 4K release down to 1080p SDR
H.264 and dropped bitmap subtitles.

The homelab server used to throttle itself to 3.5 MiB/s, about 29 Mbps. That
carried 1080p but stalled a 4K remux. It now allows 20 MiB/s. See
[Stremio](../README.md#stremio) in the homelab README.

`transcodeMaxWidth` stays at 1920, and that is the right value. Direct play
ignores it. It applies only when a file falls back to transcoding, and the
homelab CPU cannot encode 4K in real time. Measured there.

### Where the cache goes

| | Old wrapper | This build, stock | This build, repointed |
| --- | --- | --- | --- |
| Torrent peer | homelab | the TV | homelab |
| Cache path | `/docker/stremio/stremio-cache` | `/media/developer/apps/...` | `/docker/stremio/stremio-cache` |
| Cache size | 2 GiB | 0, no retention | 2 GiB |

## Privacy note

The TV keeps a connection open to `96.47.5.165:4437`. The certificate is
`*.alphonso.tv` — Alphonso Inc., now LG Ads Solutions. This is LG's automatic
content recognition. It samples what is on screen for ad targeting.

Turn it off on the TV: **Settings → General → System → Additional Settings →
Live Plus** (off), and clear the ad agreements under **User Agreements**.
Blocking `*.alphonso.tv` in AdGuard Home also works.

## Why not the LG Content Store app

Stremio ships an official webOS app for 2020 and later models, so this TV
qualifies. Some stores list it, such as Israel:
<https://il.lgappstv.com/main/tvapp/detail?appId=1214520>. This region does
not.

You cannot sideload it. The Content Store serves signed packages to the TV
only, and Stremio publishes no `.ipk`: their GitHub holds `stremio-web`,
`stremio-core` and the desktop shells, and no webOS repo.

Changing the TV's country under **Settings → General → System → Location**
switches the store catalogue. It also resets apps and logins. The sideloaded
build above avoids that.

## Known issues

| Symptom | Cause | Fix |
| --- | --- | --- |
| `TypeError: isDate is not a function` | `ssh2-streams` calls `util.isDate`, removed in Node 23 | Use Node 20. Not seen on Node 26 with `ares-cli` 2.4.0 |
| `rm: can't remove '/media/developer/temp'` | Installer deletes a root-owned directory that `prisoner` cannot touch | In `lib/install.js`, clear the contents instead: `mkdir -p DIR && rm -rf DIR/*`. Already applied here; `npm update` undoes it |
| `can't open '/etc/profile'` | `ares-shell` assumes a login shell | Use `ssh` instead |
| `/hlsv2/*` returns 500 `no ffmpeg found` | 64-bit ffmpeg in the package cannot run | Repack with `armhf`. See above. Direct play still works; only the transcode fallback breaks |
| A repacked app misbehaves, or its files differ from upstream for no reason | `ares-package` minifies JavaScript by default | Always pass `--no-minify`. It matters most for a hand-patched bundle, where re-minifying can undo the patch |

## References

- `build-stremio.sh` — builds either package; `--wrapper` for the fallback
- [spcljense/stremio-webos](https://github.com/spcljense/stremio-webos) — the app in use
- [webos-tools/cli](https://github.com/webos-tools/cli) — CLI source
- [CLI user guide](https://www.webosose.org/docs/tools/sdk/cli/cli-user-guide)
- [John Van Sickle ffmpeg builds](https://johnvansickle.com/ffmpeg/) — static `armhf`
