# A Linux desktop for nanoui's tests: GTK 3, fonts, and a virtual display
# (Xvfb) so windows open without a screen. Binaries are built on the host
# (zig build -Dtarget=aarch64-linux-gnu) and mounted in.
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libgtk-3-0t64 libegl1 libegl-mesa0 libgl1-mesa-dri fonts-dejavu-core fonts-noto-core xvfb xauth x11-utils imagemagick xdotool zsh vim less python3 git curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
