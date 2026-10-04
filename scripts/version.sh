#!/usr/bin/env bash
# The version, from git — the same answer mix.exs's version/0 gives, for CI
# steps with no Elixir (the fly image build, the MSI). Keep the two in step.
#
#   on a vX.Y.Z tag:  X.Y.Z
#   N commits past:   X.Y.Z+N.gSHA
#   no tag reachable: 0.0.0+gSHA   (mix.exs says 0.0.0-dev: it may have no git at all)
set -euo pipefail

if described=$(git describe --tags --long --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null); then
  if [[ $described =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)-(g[0-9a-f]+)$ ]]; then
    if [ "${BASH_REMATCH[2]}" = "0" ]; then
      echo "${BASH_REMATCH[1]}"
    else
      echo "${BASH_REMATCH[1]}+${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
    fi
    exit 0
  fi
fi

echo "0.0.0+g$(git rev-parse --short HEAD)"
