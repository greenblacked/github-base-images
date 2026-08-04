#!/usr/bin/env bash
# Smoke tests for the ci-php84 image. Run against a built image before it is pushed.
#   ./ci-php84/test.sh ci-php84:test
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
check "php is present"             'php --version'
check "php is 8.4"                 'php -r "exit(version_compare(PHP_VERSION, \"8.4\", \">=\") && version_compare(PHP_VERSION, \"8.5\", \"<\") ? 0 : 1);"'
check "php runs a script"          'php -r "echo 1;"'
check "composer is present"        'composer --version'
check "composer is v2"             'composer --version --no-ansi | grep -q "Composer version 2"'
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
# `composer install` against Packagist depends on this working.
check "CA bundle exists"           'test -s /etc/ssl/certs/ca-certificates.crt'
check "TLS verification works"     'curl -sSf --max-time 15 https://repo.packagist.org/packages.json -o /dev/null'

check "workdir is /workspace"      '[ "$PWD" = /workspace ]'

# The image is shared across projects: packages belong in each repo's
# composer.lock, not baked in here. Composer 2 without COMPOSER_HOME set uses
# the XDG cache path, so both the legacy and XDG locations are asserted --
# checking only ~/.composer would pass vacuously while the real cache filled
# up elsewhere.
check "no project baked in"        '! test -e /workspace/composer.json'
check "no vendor dir baked in"     '! test -e /workspace/vendor'
check "no composer cache baked in" '[ -z "$(ls -A "${HOME:-/root}/.composer/cache" 2>/dev/null)" ] && [ -z "$(ls -A "${XDG_CACHE_HOME:-${HOME:-/root}/.cache}/composer" 2>/dev/null)" ]'

if [ "$failed" -ne 0 ]; then
  echo "FAIL: one or more checks failed for $IMAGE" >&2
  exit 1
fi
echo "PASS: $IMAGE"
