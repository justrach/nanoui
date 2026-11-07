#!/bin/sh
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends libgtk-3-0t64 libgtk-4-1 libegl1 libegl-mesa0 libgles2 libgl1-mesa-dri fonts-dejavu-core fonts-noto-core xvfb xauth python3 python3-venv ca-certificates git curl >/dev/null 2>&1
cp /wpt/tools/certs/cacert.pem /usr/local/share/ca-certificates/wpt.crt
update-ca-certificates >/dev/null 2>&1
cd /wpt || exit 1
python3 wpt.py --venv /tmp/venv make-hosts-file >> /etc/hosts 2>/dev/null
python3 wpt.py --venv /tmp/venv serve > /out/serve.log 2>&1 &
i=0
until curl -s -m 2 -o /dev/null http://web-platform.test:8000/resources/testharness.js; do i=$((i+1)); [ $i -gt 180 ] && { echo no serve; exit 1; }; sleep 1; done
Xvfb :9 -screen 0 1280x900x24 >/dev/null 2>&1 &
export DISPLAY=:9
sleep 1
python3 /tools/reftest.py --manifest /parity/MANIFEST.json --ladybird /parity/ladybird-summary.json.gz --bin /app/nanobrowser --out /out/ref.jsonl --sample 3000 --crash-sample 500 --jobs 20
