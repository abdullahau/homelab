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