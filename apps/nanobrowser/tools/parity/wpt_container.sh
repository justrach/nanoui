#!/bin/sh
# Inside a Linux container: its own /etc/hosts for WPT's names, WPT's certificate
# authority trusted, `wpt serve`, a virtual display, then the run. Mounted:
#   /wpt   a WPT checkout   /tools  this directory   /app  the Linux nanobrowser
#   /out   results; tests.json goes here too
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends libgtk-3-0t64 libgtk-4-1 libegl1 libegl-mesa0 libgles2 \
  libgl1-mesa-dri fonts-dejavu-core fonts-noto-core xvfb xauth python3 python3-venv ca-certificates \
  git curl >/dev/null 2>&1
cp /wpt/tools/certs/cacert.pem /usr/local/share/ca-certificates/wpt.crt
update-ca-certificates >/dev/null 2>&1
cd /wpt || exit 1
python3 wpt.py --venv /tmp/venv make-hosts-file >> /etc/hosts 2>/tmp/hosts.err || cat /tmp/hosts.err
# wptrunner swaps this one file by a route of its own; here, in this checkout.
cp /tools/testharnessreport.js /wpt/resources/testharnessreport.js
python3 wpt.py --venv /tmp/venv serve > /out/serve.log 2>&1 &
i=0
until curl -s -m 2 -o /dev/null http://web-platform.test:8000/resources/testharness.js; do
  i=$((i+1)); [ $i -gt 180 ] && { echo "wpt serve didn't come up"; tail -5 /out/serve.log; exit 1; }
  sleep 1
done
curl -s -m 2 http://web-platform.test:8000/resources/testharnessreport.js | head -3 | cut -c1-60
curl -s -m 2 -o /dev/null -w "https %{http_code}\n" https://web-platform.test:8443/resources/testharness.js
Xvfb :9 -screen 0 1280x900x24 >/dev/null 2>&1 &
export DISPLAY=:9
sleep 1
python3 /tools/wpt_run.py --tests /out/tests.json --bin /app/nanobrowser --out /out/results.jsonl "$@"
