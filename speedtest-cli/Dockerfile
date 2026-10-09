FROM alpine:3

# Same Ookla CLI build as Speedtest Tracker, so old and new results compare.
ARG OOKLA_VERSION=1.2.0

RUN apk add --no-cache jq tzdata \
 && wget -qO- "https://install.speedtest.net/app/cli/ookla-speedtest-${OOKLA_VERSION}-linux-x86_64.tgz" \
    | tar -xz -C /usr/local/bin speedtest

COPY speedtest.sh /usr/local/bin/speedtest.sh
COPY crontab /etc/crontabs/root

CMD ["crond", "-f", "-l", "8"]
