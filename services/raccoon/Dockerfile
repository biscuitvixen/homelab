FROM alpine:3.22
# bash for the installer, rsync for the copies and the content diff,
# inotify-tools to watch the inbox, docker-cli to stop and start the
# owning containers over the mounted socket, openssh-client for the
# boot-time call-home to skypaw.
RUN apk add --no-cache bash rsync inotify-tools docker-cli openssh-client
COPY install.sh /usr/local/bin/install.sh
# The heartbeat is touched on every pass of the watch loop (at most 60 s
# apart); stale means the loop is wedged.
HEALTHCHECK --interval=60s --timeout=5s --start-period=30s --retries=3 \
    CMD find /run/heartbeat -mmin -3 | grep -q . || exit 1
ENTRYPOINT ["/usr/local/bin/install.sh"]
