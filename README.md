# Homelab

Each service has its own top-level `*-docker-compose.yml`. `docker-manager.sh`
drives them all.

## Configuration and secrets

Secrets live in `.env`, which is never committed. Compose reads it automatically
for `${VAR}` interpolation.

Two ways a config file gets its values:

| Method | Used by | How |
| --- | --- | --- |
| Native `${VAR}` | Glance | Glance expands env vars itself. Pass the vars in the compose `environment:` block. |
| Template + render | MediaMTX | Track `*.template`, render the real file from `.env`. |

Render every template after changing `.env`:

```bash
./docker-manager.sh render     # or: ./scripts/render.sh
```

`scripts/render.sh` walks the repo for `*.template` and skips any directory
holding its own `render.sh`.

Rendered files (`mediamtx/mediamtx.yml`) are gitignored. Edit the template.

### First run on a new machine

```bash
cp .env.example .env    # then fill in every value
./scripts/render.sh
./scripts/install-hooks.sh
./docker-manager.sh up
```

## `/data` folder structure

```bash
data
├── books
├── downloads
│   ├── completed
│   ├── incomplete
│   └── torrents
├── movies
├── music
└── shows
```

Put media on a second disk if the root disk is small. Mount the disk on the
host, then bind-mount it into each container that needs it.

On this host, an external USB disk mounts at `/mnt/hdd`. Plex, Transmission,
MediaMTX and Beszel bind it. A USB disk can mount after Docker starts. Then
each container binds an empty folder, and writes land on the root disk. Two
things prevent this here:

- The fstab entry uses `nofail`, so the boot does not stop if the disk is
  missing.
- A guard script in the dotfiles repo restarts those containers when the disk
  mounts. Each of them needs `restart: unless-stopped`.

## Running services

```bash
./docker-manager.sh up       # start all
./docker-manager.sh down     # stop all
./docker-manager.sh pull     # pull images
./docker-manager.sh update   # pull, rebuild local images, then restart
./docker-manager.sh restart  # down, then up
./docker-manager.sh status   # ps for each file
./docker-manager.sh logs     # last 50 lines each
./docker-manager.sh render   # re-render templates
```

One service at a time:

```bash
docker compose -f plex-docker-compose.yml up -d
docker compose -f plex-docker-compose.yml down
```

`docker-manager.sh` reads top-level compose files only. Keep a service in a
subfolder if it runs on another machine, so it never starts here.

On this setup, `hysteria/` is a QUIC proxy for US internet access. It runs on
an Oracle Cloud VPS, not on this host. See [hysteria/README.md](hysteria/README.md).

## Services

| Service | URL | Purpose |
| --- | --- | --- |
| Glance | <http://homelab:8080> | Dashboard |
| AdGuard Home | <http://homelab> | DNS, ad and tracker blocking |
| Plex | <http://homelab:32400> | Media server |
| Navidrome | <http://homelab:4533> | Music |
| Transmission | <http://homelab:9091> | BitTorrent |
| MediaMTX | <http://homelab:8889/living-room/> | NVR, camera recording |
| Beszel | <http://homelab:8090> | Host and container metrics |
| speedtest-cli | Glance widget | Line speed test, 4 times a day |
| Stremio | <http://homelab:11470> | Streaming server for Stremio clients |

`homelab` is the MagicDNS name of this host. Use the name or tailnet IP of your
host. To run Jellyfin in place of Plex, see
[Jellyfin instead of Plex](#jellyfin-instead-of-plex).

### Notes

**AdGuard** uses `network_mode: host` so it sees real client IPs. It binds only
`53` (tcp+udp) and `80`. A `ports:` block would be ignored.

**Beszel's agent** needs credentials before it starts. Bring up the hub first,
create the account, click **Add System**, copy the token and key into
`BESZEL_TOKEN` / `BESZEL_KEY` in `.env`, then start the agent.

**MediaMTX** records an RTSP camera all the time and keeps 14 days. The camera
credentials come from `CAMERA_USER`, `CAMERA_PASSWORD` and `CAMERA_HOST` in
`.env`. Each camera is a path under `paths:` in
`mediamtx/mediamtx.yml.template`. The path name is also the URL:

- Live view (WebRTC): `http://<host>:8889/<path>/`
- Live view (HLS, fallback): `http://<host>:8888/<path>/`
- Recordings: the playback API at `:9996/list` and `:9996/get`
- Control API: `127.0.0.1:9997` only

To add a camera, copy the path block, give it a new name, and run
`./docker-manager.sh render`.

On this host, there is one camera, at the path `living-room`.

MediaMTX uses `network_mode: host`. On a bridge network, docker-proxy changes
every client address to the bridge gateway. Then the `ips:` allowlist in
`mediamtx.yml` cannot tell the LAN from the internet. On this host, that made
the camera and its archive readable from the internet over IPv6. Fixed and
verified on 2026-09-30: public IPv6 gets 401, the tailnet gets 200. Do not
move MediaMTX back to a bridge.

**speedtest-cli** runs an Ookla speed test 4 times a day and shows the result
in Glance. It replaced Speedtest Tracker (155 MiB idle) on 2026-10-09 and
idles at under 1 MiB.

- The schedule is `5 0,6,12,18 * * *` (in `speedtest-cli/crontab`).
- Each run tests one server from `SERVERS=` in `speedtest-cli/speedtest.sh`,
  in random order. If a server fails, the script tries the next one.
- Results are the raw Ookla JSON, one per line, in
  `speedtest-cli/data/history.jsonl`. The script deletes results older than
  30 days.
- Glance reads `glance/assets/speedtest/summary.json` (the latest result and
  the 30-day averages) from its own `/assets/` path. It needs no API token.
- Run a test now: `docker exec speedtest-cli speedtest.sh`.
- `./docker-manager.sh update` rebuilds the image with the newest Alpine and
  the newest Ookla CLI. Nothing is pinned.

Pick servers that your own ISP does not host. An ISP's own server is inside
its network, so the test skips the internet and can read much too high. To
list the servers near you:

```bash
docker exec speedtest-cli speedtest -L --accept-license --accept-gdpr
```

Change `SERVERS=`, then rebuild with
`docker compose -f speedtest-docker-compose.yml up -d --build`.

On this host, the ISP is e& (UAE). Its own servers read ~935/500, but the real
line is ~310/116. So `SERVERS=` holds the 5 du servers only. Excluded e&
servers: 17336 Dubai, 33712 Sharjah, 34238 Ajman, 34240 Fujairah, 28422 Abu
Dhabi, 34239 Al Ain. Do not add them.

## Edge stack (cloudflared + Caddy)

`edge-stack-docker-compose.yml` holds two containers:

| Container | Job |
| --- | --- |
| `cloudflared` | Outbound tunnel to Cloudflare. No inbound port. |
| `caddy` | Routes each hostname to a service. Plain HTTP only. |

Cloudflare terminates TLS at the edge, so Caddy runs with `auto_https off`.

### Test it locally

Send a Host header to pick a route without touching the tunnel:

```bash
curl -H "Host: plex.abdullah.run" http://localhost:8081/
```

An unrouted hostname returns `404` from the catch-all block. The Plex block is
commented out, so this example returns `404` until you enable it.

Host port `8081` is for local tests only. `cloudflared` reaches Caddy over the
compose network, not the host.

### Connect the tunnel

1. Put the tunnel token in `TUNNEL_TOKEN` in `.env`.
2. In the Cloudflare Zero Trust dashboard, open your tunnel.
3. Add a public hostname. Set the service to `HTTP` and `caddy:80`.
4. Start the connector:

```bash
docker compose -f edge-stack-docker-compose.yml up -d cloudflared
```

### Check the tunnel

`cloudflared` has no shell, so query it from the `caddy` container:

```bash
docker exec caddy wget -qO- http://cloudflared:20241/ready
docker exec caddy wget -qO- http://cloudflared:20241/config
```

`ready` must report four connections. In `config`, `"version":-1` and a lone
`http_status:503` rule mean the dashboard has pushed no route yet. The
connector is healthy but every request gets a 503 at the edge.

### Routes

Both routes are commented out. Cloudflare's terms restrict streaming video
through the CDN, so Plex and Jellyfin stay off the tunnel. Uncomment the
blocks in `edge-stack/Caddyfile` to re-enable them.

| Hostname | Origin | Why that address |
| --- | --- | --- |
| `plex.abdullah.run` | `${HOST_LAN_IP}:32400` | Plex uses `network_mode: host`. No container name to resolve. |
| `jellyfin.abdullah.run` | `${HOST_LAN_IP}:8096` | Only if you run Jellyfin. It is a separate compose project, so it is on another network. |

Replace `abdullah.run` with your own domain.

Every hostname needs two things: a block in `edge-stack/Caddyfile`, and a
public hostname in the dashboard pointing at `http://caddy:80`.

Caddy resolves container names only on a shared network. For anything in
another compose file, use `{$HOST_LAN_IP}:<port>` and pass `HOST_LAN_IP` in
the compose `environment:` block.

Reload Caddy after an edit:

```bash
docker compose -f edge-stack-docker-compose.yml restart caddy
```

## Stremio

`stremio-docker-compose.yml` runs the Stremio **streaming server** only. The
server fetches and remuxes streams. It holds no catalogue and no add-on. The
catalogues, the player and the add-ons all live in the Stremio client.

The server uses `network_mode: host`. It builds its HTTPS address from the IP
that it sees. In bridge mode, that is the container IP, and no client can
reach it. Docker ignores a `ports:` block in host mode. The server binds
`11470` (HTTP) and `12470` (HTTPS).

Do not mount the host `ffmpeg`. The image ships jellyfin-ffmpeg at
`/usr/lib/jellyfin-ffmpeg/`. A bind mount copies the binary without its shared
libraries, so it does not start.

### Connect a client

1. Open the Stremio desktop or Android app, or <https://web.stremio.com>.
2. Go to **Settings** → **Streaming**.
3. Set **Streaming server URL** to `http://<host>:11470`. Use the MagicDNS
   name or the tailnet IP of the server.
4. Make sure that the status shows **Connected**.

The web client loads over HTTPS, so the browser blocks a plain HTTP server.
The desktop and Android apps do not have this limit. For a browser, serve the
server over HTTPS on the tailnet. See
[HTTPS on the tailnet](#https-on-the-tailnet-with-tailscale-serve).

### Cache

The cache is in `./stremio/stremio-cache/<infoHash>/`. The default limit is
2 GiB. Change it under **Settings** → **Streaming** → **Cache size**. Make sure
that the disk has enough free space.

Two things about the cache are not obvious:

- The limit is a soft target. The server deletes old files only when a new
  stream starts. Until then, the folder can stay over the limit.
- A title keeps downloading after you stop watching. It stops when the server
  closes the idle stream. A `/<infoHash>/remove` request closes the stream, but
  it leaves the downloaded pieces on disk.

### HTTPS on the tailnet with tailscale serve

A browser client needs HTTPS. Examples are web.stremio.com on a laptop, and
an iPad or iPhone, which have no Stremio app. `tailscale serve` gives the
server a real certificate. Only devices on your tailnet can reach it.

Before you start, turn on **MagicDNS** and **HTTPS Certificates** on the
**DNS** page of the Tailscale admin console.

Run these commands once on the host. The first command lets your user run
`tailscale serve` without root:

```bash
sudo tailscale set --operator=$USER
tailscale serve --bg --https=443 http://127.0.0.1:11470
```

The server is now at `https://<host>.<tailnet>.ts.net/`. Run
`tailscale serve status` to see the exact address. Set **Streaming server
URL** to that address, with the trailing slash.

**Never use `tailscale funnel` here.** Funnel publishes the server to the
internet, and the Stremio server has no authentication. It accepts a magnet
link from anyone who reaches it, so a stranger can fill your disk.

Check or remove the setting:

```bash
tailscale serve status
tailscale serve --https=443 off
```

`tailscaled` keeps the setting, so it survives a reboot. The certificate
renews itself. The proxy passes range requests (HTTP 206), so seeking works.
In a test, it moved 135 MB/s, so it does not limit the speed.

#### HTTPS endpoint (optional)

**Settings → Streaming → HTTPS endpoint** gives the server a second HTTPS
address on port `12470`. It works on the LAN only. Use it for a LAN device that
is not on your tailnet. When it is on, every client shows the address as
**Remote URL**. On this host, it is **Disabled**.

#### Safari cannot play MKV

Safari's `<video>` element cannot play MKV files, whatever the codec. If the
server cannot transcode the file, the web player fails on most releases. This
is a Safari limit, not a network problem.

On an iPad or iPhone, copy the stream link from the web client. Open it in a
player that plays MKV, such as Infuse or VLC:

```text
https://<host>.<tailnet>.ts.net/<infoHash>/<fileIndex>
```

Infuse plays HEVC 10-bit and DTS. AV1 needs an A17 Pro or M3 chip, or newer.

### Download limits

Two server settings limit the BitTorrent download speed:

| Setting | Value in this repo |
| --- | --- |
| `btDownloadSpeedSoftLimit` | 12 MiB/s (101 Mbps) |
| `btDownloadSpeedHardLimit` | 20 MiB/s (168 Mbps) |

Set the hard limit above the bitrate of the files that you play, and below
your line speed. A 4K WEB-DL needs 15-25 Mbps. A 4K remux needs 50-100 Mbps.
If the limit is too low, 4K files stall.

Change the values without a restart. The values are in bytes per second:

```bash
curl -X POST http://<host>:11470/settings -H "Content-Type: application/json" \
  -d '{"btDownloadSpeedSoftLimit":12582912,"btDownloadSpeedHardLimit":20971520}'
```

The server writes the values to `stremio/server-settings.json`, so they
survive a restart.

### Transcoding

The server transcodes only when a client cannot play the file directly. Most
modern TVs and apps play files directly, so transcoding is rare.

`transcodeMaxWidth` sets the largest output width. On a weak CPU, keep it at
`1920`. A 4K software transcode needs about 2x the CPU of a 1080p transcode.
To test your CPU, transcode 60 seconds of a 4K file with ffmpeg. The speed
must stay above 1.0x real time.

On this host (i5-5287U, 2 cores), measured on 2026-09-22 with `libx264
-preset ultrafast`: 1920 wide ran at 1.02x, and 3840 wide ran at 0.58x and
stuttered. Keep `1920` here.

#### Hardware transcoding

The server tests `qsv`, `nvenc` and `vaapi` with an HEVC sample. If the GPU
cannot decode HEVC, every test fails and the server uses the CPU.

To check an Intel or AMD GPU, run `vainfo` from the image:

```bash
docker run --rm --device /dev/dri --entrypoint /usr/lib/jellyfin-ffmpeg/vainfo stremio/server:latest
```

If the list has a `VAProfileHEVC` entry, add `/dev/dri` under `devices:` and
the render group under `group_add:` in the compose file. If it does not, do
not add the device. It changes nothing.

On this host, the Broadwell Iris 6100 has no HEVC profile. Re-tested on
2026-09-27 with the device and the render group: still "no viable
acceleration profiles detected". Do not add `/dev/dri` again. These two
workarounds also fail:

- **Switch the test off.** Settings cannot do it. The server tests again at
  the next start.
- **Set the `vaapi` profile by hand.** The request returns an empty playlist
  and logs `ERR_STREAM_PREMATURE_CLOSE`.

The failed tests use about 1 second of CPU every few hours, so leave them.

### Add-ons

Add-ons attach to your Stremio **account**, not to this server. Install an
add-on once, and every device that signs in to the same account gets it. The
compose file does not change.

#### Torrentio without a debrid service

This is the basic setup. Torrentio sends magnet links to the streaming
server, and the server downloads from the public swarm.

1. Open <https://web.stremio.com> and sign in.
2. Open <https://torrentio.strem.fun/configure> in a second tab.
3. Select your providers. For a first run, keep the other defaults.
4. Leave **Debrid Provider** empty.
5. Click **Install** at the bottom. The browser sends the link to Stremio.
6. Stremio opens an **Install Addon** window. Click the green **Install**
   button.

If **Install** does nothing, copy the URL that it makes. Add it by hand:
**Add-ons** → **Add add-on** → paste → **Install**.

> Torrentio streams from public torrent swarms. Every peer sees your public
> IP. A debrid service hides it.

#### Torrentio with Real-Debrid

Use this setup if you have a Real-Debrid account. Real-Debrid downloads the
file, so your IP never joins the swarm.

1. Open <https://torrentio.strem.fun/configure>.
2. Near the bottom, set **Debrid Provider** to **Real Debrid**. A new text
   box opens below it.
3. Copy your API key from <https://real-debrid.com/apitoken>.
4. Paste the key into the **RealDebrid API Key** box.
5. Under **Debrid Options**, select **Don't show download to debrid links**.
   Leave the other boxes clear.
6. Click **Install**. Stremio opens an **Install Addon** window. Click the
   green **Install** button.

Torrentio is a community add-on. Install it only from the official configure
page above. Do not use mirrors.

#### Remove WatchHub (optional)

Stremio installs WatchHub by default. It adds many entries to the stream list.
To remove it:

1. Click the puzzle piece at the top right.
2. Open **My Addons**.
3. Find **WatchHub** and click **Uninstall**.

## Torrent search

- [BT4G: Torrent Search Engine](https://bt4gprx.com/)
- [Magnetz](https://magnetz.eu/)

## Jellyfin instead of Plex

This repo runs Plex. Jellyfin is a free, open-source option. Its compose file
is kept in `compose-files/jellyfin-docker-compose.yml.bak`.

1. Copy the file to the top level. `docker-manager.sh` starts every top-level
   `*-docker-compose.yml`:

   ```bash
   cp compose-files/jellyfin-docker-compose.yml.bak jellyfin-docker-compose.yml
   ```

2. Change the media bind mounts to match your folders.
3. Start it:

   ```bash
   docker compose -f jellyfin-docker-compose.yml up -d
   ```

4. Open `http://<host>:8096` and complete the setup wizard.

Notes:

- Port `8096` is the web UI. Port `7359/udp` lets LAN clients find the server.
- The file passes no `/dev/dri`, so transcodes use the CPU. Set the client
  bitrate to the maximum, so that clients play files directly.
- To show it in Glance, add a `jellyfin:` entry to the `docker-containers`
  widget in `glance/config/home.yml`.
- To publish it, uncomment the Jellyfin block in `edge-stack/Caddyfile`. See
  [Routes](#routes).
- To stop Plex, run `docker compose -f plex-docker-compose.yml down`. Then move
  the file to `compose-files/plex-docker-compose.yml.bak`.

### Samsung TV client (Tizen)

Jellyfin has no app in the Samsung store. Install it in developer mode.

1. Turn on developer mode:
   1. On the TV, open **Smart Hub**, then the **Apps** panel.
   2. Enter `12345` with the remote or the on-screen keypad.
   3. Set **Developer mode** to **On**.
   4. Enter the IP address of the computer that installs the app. Click **OK**.
   5. Restart the TV. The **Apps** panel now shows **Develop Mode** at the top.

2. Install the app. Use one of these options.

   **Option 1: TizenBrew**

   1. Download TizenBrew for your OS from the
      [releases page](https://github.com/reisxd/TizenBrew/releases).
   2. Make the script executable: `chmod +x <script>`.
   3. Run the script, then open
      `http://localhost:8091/ui/dist/index.html` in a browser.
   4. Connect to the TV with its LAN IP address.
   5. Download the Jellyfin widget package (`.wgt`) from the
      [releases page](https://github.com/jeppevinkel/jellyfin-tizen-builds/releases).
   6. Click **Select file to install**, select the package, and wait for the
      install to finish.

   For more help, see the
   [TizenBrew guide](https://app.notion.com/p/TizenBrew-Guide-30437864d8618033bb03e818e894fd5c).

   **Option 2: Docker**

   ```bash
   docker run --rm georift/install-jellyfin-tizen <samsung-tv-ip>
   # Optional arguments:
   docker run --rm georift/install-jellyfin-tizen <samsung-tv-ip> [build option] [tag url] [certificate password]
   ```

   For more help, see the
   [blog post](https://tim.wants.coffee/posts/install-jellyfin-on-a-samsung-tv/)
   and the [GitHub repo](https://github.com/Georift/install-jellyfin-tizen).
