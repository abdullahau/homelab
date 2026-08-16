# Homelab

## `/data` folder structure:

```bash
data
├── books
├── downloads
│   ├── completed
│   ├── incomplete
│   └── torrents
├── movies
├── music
└── shows
```

## Running/Stopping a Docker Compose File

```bash
docker compose -f <compose-file-name> up -d

docker compose -f <compose-file-name> down
```

```bash
docker compose -f media-docker-compose.yml up -d

docker compose -f media-docker-compose.yml down
```

## Run All Docker Compose Files Together

```bash
./docker-manager.sh pull    # Pull all
./docker-manager.sh update  # Pull & Restart all
./docker-manager.sh up      # Start all
./docker-manager.sh down    # Stop all
./docker-manager.sh restart # Restart all
./docker-manager.sh status  # Check status
```

## Monitoring

| Service | URL | Purpose |
| --- | --- | --- |
| Beszel | <http://homelab:8090> | Host + per-container CPU / memory / disk / network |
| Tautulli | <http://homelab:8181> | Plex activity, watch history, direct play vs transcode |

Beszel's **agent** needs credentials before it will start. Bring up the hub
first, create the account, click **Add System**, copy the token and public key
into `BESZEL_TOKEN` / `BESZEL_KEY` in `.env`, then:

```bash
docker compose -f beszel-docker-compose.yml up -d
```

Tautulli's setup wizard asks for the Plex server. Because Plex runs with
`network_mode: host`, enter `192.168.0.100` / port `32400` / SSL off — not
`localhost`.

## Pre-Encoded Plex Versions

`transcode/plex-versions.sh` builds an H.264 companion file next to any source
that will not Direct Play. Plex collapses multiple files in one movie folder into
a single item with several **Versions** and serves whichever suits the client, so
it never has to transcode live — which matters here because this Broadwell iGPU
cannot hardware-decode 10-bit HEVC.

A companion is built when the source trips any of:

- video codec is HEVC / AV1 / VC-1 / MPEG-2 / MPEG-4 (H.264 is the baseline that
  browsers, older smart TVs and Chromecast all decode),
- pixel format is over 8-bit (Main 10 fails on many clients that do handle HEVC),
- frame is larger than the target box.

Files that trip none of these already Direct Play and are left alone; `-f`
overrides. Output is H.264 High@4.1, 8-bit, AAC stereo, SDR.

```bash
cd transcode
./plex-versions.sh -n /data/movies /mnt/hdd/movies   # dry run: show decisions
./plex-versions.sh "/mnt/hdd/movies/Some Movie (2023) [2160p] ..."
./plex-versions.sh -p 720p /data/movies              # smaller profile
```

Throughput on this host: ~1.2x real time for SDR sources, ~0.35x for HDR ones
(the tonemap runs in software). Run it overnight.

> **Note**: Plex's own **Optimize** feature does the same job, but the server's
> `/media/subscriptions` endpoint returns 401 without a Plex Pass — this account
> has `myPlexSubscription="0"`, so that route is unavailable.

## Torrent Search Engine

[BT4G: Torrent Search Engine](https://bt4gprx.com/)

## Samsung TV Jellyfin Client

1) Enable developer mode and set the Developr's Host PC IP address to your computer's IP address.
    - On the TV, open the "Smart Hub".
    - Select the "Apps" panel.
    - In the "Apps" panel, enter "12345" using the remote control or the on-screen number keypad.
    - The developer mode configuration popup appears.
    - Switch "Developer mode" to "On".
    - Enter the IP address of the computer that you want to connect to the TV, and click "OK".
    - Reboot the TV.
    - When you open the "Apps" panel after the reboot, "Develop Mode" is marked at the top of the screen.

2) Using TizenBrew Device Manager`:
    - Download the latest TizenBrew Device Manager for your OS from the [releases page](https://github.com/reisxd/tizenbrew-device-manager/releases)
    - Install / Run TizenBrew Device Manager, go into "Connect Device" page and connect to your TV using its LAN IP address.
    - Download the right Jellyfin package from the [releases page](https://github.com/jeppevinkel/jellyfin-tizen-builds/releases)

3) Using Docker:
    - Run `docker run --rm georift/install-jellyfin-tizen <samsung tv ip>`
    - Or run with optional arguments `docker run --rm georift/install-jellyfin-tizen <samsung tv ip> [build option] [tag url] [certificate password]`
    - More installation instructions can be found on [Georift's](https://tim.wants.coffee/posts/install-jellyfin-on-a-samsung-tv/) Github [repo](https://github.com/Georift/install-jellyfin-tizen). 
