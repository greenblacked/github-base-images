#!/usr/bin/env bash
# Smoke tests for the ci-python313 image. Run against a built image before it is pushed.
#   ./ci-python313/test.sh ci-python313:test
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
check "python is present"          'python --version'
check "python is 3.13"             '[ "$(python -c "import sys; print(\"%d.%d\" % sys.version_info[:2])")" = 3.13 ]'
check "pip is present"             'pip --version'
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
# pip install depends on this working.
check "CA bundle exists"           'test -s /etc/ssl/certs/ca-certificates.crt'
check "TLS verification works"     'curl -sSf https://pypi.org/ -o /dev/null'

check "workdir is /workspace"      '[ "$PWD" = /workspace ]'

# The image is shared across projects: project dependencies belong in each
# repo's lockfile, not baked in here. Only pip's own machinery may live in
# site-packages.
check "no project deps baked in"   '[ -z "$(pip list --format freeze --exclude pip --exclude setuptools --exclude wheel)" ]'
check "no virtualenv baked in"     '! test -e /workspace/.venv'
check "no compiler baked in"       '! command -v gcc && ! command -v cc'

if [ "$failed" -ne 0 ]; then
  echo "FAIL: one or more checks failed for $IMAGE" >&2
  exit 1
fi
echo "PASS: $IMAGE"
