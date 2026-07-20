#!/usr/bin/env bash
# Smoke tests for the ci-node22 image. Run against a built image before it is pushed.
#   ./ci-node22/test.sh ci-node22:test
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
check "node is present"            'node --version'
check "node is v22"                '[ "$(node -p "process.versions.node.split(\".\")[0]")" = 22 ]'
check "npm is present"             'npm --version'
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
# npm ci depends on this working.
check "CA bundle exists"           'test -s /etc/ssl/certs/ca-certificates.crt'
check "TLS verification works"     'curl -sSf https://registry.npmjs.org/ -o /dev/null'

check "workdir is /workspace"      '[ "$PWD" = /workspace ]'

# Playwright system libraries, so `npx playwright install chromium` works in a
# consuming repo without root or apt.
check "playwright libs present"    'dpkg -s libnss3 libgbm1 libatk1.0-0 libasound2 libxkbcommon0 fonts-liberation >/dev/null 2>&1'

# ...but no browser binaries. Browsers are version-locked to the consumer's
# playwright package; baking them would pin every repo to this image's version.
check "no browsers baked in"       '! test -d /ms-playwright && ! test -d /root/.cache/ms-playwright'

# The image is shared across projects: project dependencies belong in each
# repo's lockfile, not baked in here.
check "no node_modules baked in"   '! test -e /workspace/node_modules'
check "no wrangler baked in"       '! command -v wrangler'
check "no next baked in"           '! command -v next'

if [ "$failed" -ne 0 ]; then
  echo "FAIL: one or more checks failed for $IMAGE" >&2
  exit 1
fi
echo "PASS: $IMAGE"
