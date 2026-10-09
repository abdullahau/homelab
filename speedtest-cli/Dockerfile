FROM alpine:latest

# Ookla has no "latest" URL, so take the link from its official CLI page.
RUN apk upgrade --no-cache \
 && apk add --no-cache jq tzdata \
 && url=$(wget -qO- https://www.speedtest.net/apps/cli \
    | grep -o 'https://install.speedtest.net/app/cli/ookla-speedtest-[0-9.]*-linux-x86_64.tgz' | head -1) \
 && [ -n "$url" ] \
 && wget -qO- "$url" | tar -xz -C /usr/local/bin speedtest

COPY speedtest.sh /usr/local/bin/speedtest.sh
COPY crontab /etc/crontabs/root

CMD ["crond", "-f", "-l", "8"]
