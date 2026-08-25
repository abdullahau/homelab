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

Bulk media also lives on the external USB disk at `/mnt/hdd`.

## Running services

```bash
./docker-manager.sh up       # start all
./docker-manager.sh down     # stop all
./docker-manager.sh pull     # pull images
./docker-manager.sh update   # pull, then restart
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

> `hysteria/hysteria-docker-compose.yml` runs on the Oracle VPS, not here.
> `docker-manager.sh` globs top level only, so it never starts.

## Services

| Service | URL | Purpose |
| --- | --- | --- |
| Glance | <http://homelab:8080> | Dashboard |
| AdGuard Home | <http://homelab> | DNS, ad and tracker blocking |
| Plex | <http://homelab:32400> | Media server |
| Jellyfin | <http://homelab:8096> | Media server |
| Navidrome | <http://homelab:4533> | Music |
| Transmission | <http://homelab:9091> | BitTorrent |
| MediaMTX | <http://homelab:3000> | NVR, camera recording |
| Beszel | <http://homelab:8090> | Host and container metrics |
| Tautulli | <http://homelab:8181> | Plex activity and history |
| Speedtest Tracker | <http://homelab:9080/admin> | Line speed history |

### Notes

**AdGuard** uses `network_mode: host` so it sees real client IPs. It binds only
`53` (tcp+udp) and `80`. A `ports:` block would be ignored.

**Beszel's agent** needs credentials before it starts. Bring up the hub first,
create the account, click **Add System**, copy the token and key into
`BESZEL_TOKEN` / `BESZEL_KEY` in `.env`, then start the agent.

**Tautulli** asks for the Plex server during setup. Plex runs with
`network_mode: host`, so enter the value of `HOST_LAN_IP`, port `32400`, SSL
off. Do not use `localhost`.

**MediaMTX** records continuously and keeps 14 days. Camera credentials come
from `CAMERA_USER` / `CAMERA_PASSWORD` / `CAMERA_HOST` in `.env`. Viewing is
restricted to the LAN, the tailnet, and the `mediamtx-connect` container.

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
curl -H "Host: jellyfin.abdullah.diy" http://localhost:8081/
```

An unrouted hostname returns `404` from the catch-all block.

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
| `plex.abdullah.diy` | `${HOST_LAN_IP}:32400` | Plex uses `network_mode: host`. No container name to resolve. |
| `jellyfin.abdullah.diy` | `${HOST_LAN_IP}:8096` | Jellyfin is a separate compose project, so it is on another network. |

Every hostname needs two things: a block in `edge-stack/Caddyfile`, and a
public hostname in the dashboard pointing at `http://caddy:80`.

Caddy resolves container names only on a shared network. For anything in
another compose file, use `{$HOST_LAN_IP}:<port>` and pass `HOST_LAN_IP` in
the compose `environment:` block.

Reload Caddy after an edit:

```bash
docker compose -f edge-stack-docker-compose.yml restart caddy
```

## Torrent search

- [BT4G: Torrent Search Engine](https://bt4gprx.com/)
- [Magnetz](https://magnetz.eu/)

## Samsung TV Jellyfin client

1) Enable developer mode and set the Developer's Host PC IP address to your computer's IP address.
    - On the TV, open the "Smart Hub".
    - Select the "Apps" panel.
    - In the "Apps" panel, enter "12345" using the remote control or the on-screen number keypad.
    - The developer mode configuration popup appears.
    - Switch "Developer mode" to "On".
    - Enter the IP address of the computer that you want to connect to the TV, and click "OK".
    - Reboot the TV.
    - When you open the "Apps" panel after the reboot, "Develop Mode" is marked at the top of the screen.

2) Using TizenBrew Device Manager:
    - Download the latest TizenBrew Device Manager for your OS from the [releases page](https://github.com/reisxd/tizenbrew-device-manager/releases)
    - Install / Run TizenBrew Device Manager, go into "Connect Device" page and connect to your TV using its LAN IP address.
    - Download the right Jellyfin package from the [releases page](https://github.com/jeppevinkel/jellyfin-tizen-builds/releases)

3) Using Docker:
    - Run `docker run --rm georift/install-jellyfin-tizen <samsung tv ip>`
    - Or run with optional arguments `docker run --rm georift/install-jellyfin-tizen <samsung tv ip> [build option] [tag url] [certificate password]`
    - More installation instructions can be found on [Georift's](https://tim.wants.coffee/posts/install-jellyfin-on-a-samsung-tv/) Github [repo](https://github.com/Georift/install-jellyfin-tizen).
