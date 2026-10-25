#!/bin/bash
set -euo pipefail
export ERL_FLAGS='+S 2:2'
mkdir -p /bootstrap/otp /bootstrap/elixir
curl --fail --location --retry 3 https://builds.hex.pm/builds/otp/amd64/ubuntu-22.04/OTP-28.1.tar.gz -o /bootstrap/otp.tar.gz
tar -xzf /bootstrap/otp.tar.gz -C /bootstrap/otp --strip-components=1
cd /bootstrap/otp
./Install -minimal /bootstrap/otp
curl --fail --location --retry 3 https://builds.hex.pm/builds/elixir/v1.19.4-otp-28.zip -o /bootstrap/elixir.zip
unzip -q /bootstrap/elixir.zip -d /bootstrap/elixir
chmod +x /bootstrap/elixir/bin/*
export PATH=/bootstrap/elixir/bin:/bootstrap/otp/bin:$PATH
export MIX_HOME=/bootstrap/mix HEX_HOME=/bootstrap/hex
mix local.hex --force
mix archive.install hex phx_new --force
cd /target
mix phx.new release_probe --no-install
cd release_probe
mix deps.get
printf 'erlang 28.1\nelixir 1.19.4-otp-28\n' > .tool-versions
git init
git add .
git -c user.name=ReleaseProbe -c user.email=release-probe@example.invalid commit -m 'Fresh Phoenix release validation target'
service postgresql start
runuser -u postgres -- psql -c "ALTER USER postgres PASSWORD 'postgres'"
mkdir -p /private-state
python3 -c 'import json; from pathlib import Path; Path("/private-state/config.json").write_text(json.dumps(dict(target="phoenix", harness_version="2.0.700", server_url="http://127.0.0.1:9", device_id="11460000-0000-4000-8000-000000000001")))'
export CMS_HARNESS_VERSION=2.0.700 CMS_HARNESS_ARCHIVE=/artifacts/cms-linux-x64.tar.gz
export CMS_POSTGRES_MODE=existing
python3 /source/priv/dev_boxes/codex_cloud.py install --root /target/release_probe --state /private-state
echo FRESH_X64_INSTALL_PASSED
