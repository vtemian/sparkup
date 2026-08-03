# A container that boots systemd, because the roles under test talk to it.
#
# `base` enables avahi-daemon and sets the hostname through hostnamectl. Both
# go through systemd, and a container without it can only pretend they
# succeeded. Running the real init is the honest option; a stub that reports
# success would make the test worse than no test.
#
# DGX OS is Ubuntu 24.04, so that is the base. The apt lists are deliberately
# NOT deleted: the base role installs with `cache_valid_time: 3600`, and an
# image with a fresh apt stamp but no lists makes it skip the update and then
# fail to find rsync.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        dbus \
        python3 \
        python3-apt \
        systemd \
        systemd-sysv \
        tzdata

# systemd wants SIGRTMIN+3 to shut down; the default SIGTERM leaves `docker
# stop` waiting out its full timeout on every teardown.
STOPSIGNAL SIGRTMIN+3

CMD ["/sbin/init"]
