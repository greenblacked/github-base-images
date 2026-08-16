#!/usr/bin/env bash
# Smoke tests for the ci-go image. Run against a built image before it is pushed.
#   ./ci-go/test.sh ci-go:test
#
# Exit codes: 0 all checks passed, 1 one or more checks failed, 2 bad usage.
# SC2016: check strings are deliberately single-quoted so they expand inside
# the container (docker run bash -c), not on the host.
# shellcheck disable=SC2016
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: test.sh <image-ref>" >&2
  exit 2
fi
IMAGE="$1"
failed=0

# On failure, print what the container actually said. Discarding it means an
# arm64 machine is needed to reproduce what the log could have shown: a
# wrong-arch binary says "exec format error", a missing library names the .so,
# a TLS failure names the certificate problem.
check() {
  local name="$1" script="$2" out
  if out=$(docker run --rm "$IMAGE" bash -c "$script" 2>&1); then
    echo "ok       $name"
  else
    echo "FAILED   $name"
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | sed 's/^/         | /' >&2
    fi
    failed=1
  fi
}

echo "Testing $IMAGE"

# Every tool the image promises to ship. --no-install-recommends is exactly how
# one of these silently goes missing, so assert each one individually.
check "go is present"              'go version'
check "go is 1.x"                  'go version | grep -qE "go1\.[0-9]+"'
# A rolling tag has its own failure mode: if upstream ever stops republishing
# `1-bookworm`, this pipeline keeps rebuilding a frozen toolchain and every
# "is 1.x" assertion still passes -- the exact staleness this image was renamed
# to prevent, but now invisible. The floor below turns that into a red build.
# It is not a pin: it only has to stay at or below current stable, so it never
# blocks an upgrade and moves rarely.
# Go supports the newest two minors, so the floor tracks that window.
GO_MIN_MINOR=25
check "go >= 1.$GO_MIN_MINOR (not frozen)" \
  "test \"\$(go version | cut -d' ' -f3 | sed 's/^go//' | cut -d. -f2)\" -ge $GO_MIN_MINOR"
check "go builds a program"        'cd $(mktemp -d) && printf "package main\nfunc main(){}\n" > main.go && go mod init smoke && go build .'
check "bash is present"            'bash --version'
check "git is present"             'git --version'
check "curl is present"            'curl --version'
check "jq is present"              'jq --version'
check "ssh client is present"      'ssh -V'
check "tar is present"             'tar --version'
check "gzip is present"            'gzip --version'
check "unzip is present"           'unzip -v'
check "xz is present"              'xz --version'
check "zstd is present"            'zstd --version'

# ca-certificates is only meaningfully installed if TLS actually verifies;
# go mod download depends on this working.
check "CA bundle exists"           'test -s /etc/ssl/certs/ca-certificates.crt'
check "TLS verification works"     'curl -sSf --max-time 15 https://proxy.golang.org/ -o /dev/null'

check "workdir is /workspace"      '[ "$PWD" = /workspace ]'

# The image is shared across projects: modules belong in each repo's go.mod,
# not baked in here.
check "no go.mod baked in"         '! test -e /workspace/go.mod'
check "no module cache baked in"   '[ -z "$(ls -A "$(go env GOMODCACHE)" 2>/dev/null)" ]'

if [ "$failed" -ne 0 ]; then
  echo "FAIL: one or more checks failed for $IMAGE" >&2
  exit 1
fi
echo "PASS: $IMAGE"
