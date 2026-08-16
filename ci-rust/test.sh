#!/usr/bin/env bash
# Smoke tests for the ci-rust image. Run against a built image before it is pushed.
#   ./ci-rust/test.sh ci-rust:test
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
check "rustc is present"           'rustc --version'
check "rustc is 1.x stable"        'rustc --version | grep -qE "^rustc 1\.[0-9]+\.[0-9]+"'
check "cargo is present"           'cargo --version'
check "rustfmt is present"         'cargo fmt --version'
check "clippy is present"          'cargo clippy --version'
check "cargo builds a program"     'cd "$(mktemp -d)" && cargo init --name smoke -q . && cargo build -q --offline'
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
# `cargo fetch` depends on this working. (The build check above deliberately
# runs --offline, so this is the only check that proves TLS.)
#
# Fetch the sparse index's config.json rather than a site root. Rust is the one
# ecosystem here with no root that answers a plain curl: both https://crates.io/
# and https://static.crates.io/ return 403 -- the former to unrecognised
# user agents, the latter because it is the crate tarball CDN and has no index
# at /. Either would fail on an image whose TLS is perfectly fine. config.json
# is the first thing cargo reads when resolving dependencies, so this checks
# the path that actually matters and returns 200.
check "CA bundle exists"           'test -s /etc/ssl/certs/ca-certificates.crt'
check "TLS verification works"     'curl -sSf --max-time 15 https://index.crates.io/config.json -o /dev/null'

check "workdir is /workspace"      '[ "$PWD" = /workspace ]'

# The image is shared across projects: crates belong in each repo's Cargo.lock,
# not baked in here.
check "no Cargo project baked in"  '! test -e /workspace/Cargo.toml'
check "no target dir baked in"     '! test -e /workspace/target'
check "no crate cache baked in"    '[ -z "$(ls -A "${CARGO_HOME:-/usr/local/cargo}/registry" 2>/dev/null)" ]'

if [ "$failed" -ne 0 ]; then
  echo "FAIL: one or more checks failed for $IMAGE" >&2
  exit 1
fi
echo "PASS: $IMAGE"
