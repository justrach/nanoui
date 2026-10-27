# A Linux desktop for nanoui's tests: GTK 3 and 4, fonts, and a virtual display
# (Xvfb) so windows open without a screen. Binaries are built on the host
# (zig build test-bin -Dtarget=aarch64-linux-gnu --prefix zig-out/linux) and
# mounted in:
#   container run --rm --volume "$PWD:/work:ro" nanoui-linux \
#     xvfb-run -a /work/zig-out/linux/bin/nanoui-tests
# tini is the container's first process. xvfb-run run as process 1 waits
# forever for the signal Xvfb sends when it's ready, without printing a line.
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libgtk-3-0t64 libgtk-4-1 libegl1 libegl-mesa0 libgles2 libgl1-mesa-dri fonts-dejavu-core fonts-noto-core fonts-noto-color-emoji xvfb xauth x11-utils imagemagick xdotool zsh vim less python3 git curl ca-certificates tini \
    && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["/usr/bin/tini", "--"]
WORKDIR /work
