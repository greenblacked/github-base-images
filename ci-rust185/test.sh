#!/usr/bin/env bash
# Smoke tests for the ci-rust185 image. Run against a built image before it is pushed.
#   ./ci-rust185/test.sh ci-rust185:test
# SC2016: check strings are deliberately single-quoted so they expand inside
# the container (docker run bash -c), not on the host.
# shellcheck disable=SC2016
set -euo pipefail

IMAGE="${1:?usage: test.sh <image-ref>}"
failed=0

check() {
  local name="$1" script="$2"
  if docker run --rm "$IMAGE" bash -c "$script" >/dev/null 2>&1; then
    echo "ok       $name"
  else
    echo "FAILED   $name"
    failed=1
  fi
}

echo "Testing $IMAGE"

# Every tool the image promises to ship. --no-install-recommends is exactly how
# one of these silently goes missing, so assert each one individually.
check "rustc is present"           'rustc --version'
check "rustc is 1.85"              'rustc --version | grep -q "1\.85\."'
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
# cargo fetching crates depends on this working.
check "CA bundle exists"           'test -s /etc/ssl/certs/ca-certificates.crt'
check "TLS verification works"     'curl -sSf https://static.crates.io/ -o /dev/null'

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
