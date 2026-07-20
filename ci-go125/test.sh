#!/usr/bin/env bash
# Smoke tests for the ci-go125 image. Run against a built image before it is pushed.
#   ./ci-go125/test.sh ci-go125:test
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
check "go is present"              'go version'
check "go is 1.25"                 'go version | grep -q "go1\.25\."'
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
check "TLS verification works"     'curl -sSf https://proxy.golang.org/ -o /dev/null'

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
