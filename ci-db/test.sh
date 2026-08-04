#!/usr/bin/env bash
# Smoke tests for the ci-db image. Run against a built image before it is pushed.
#   ./ci-db/test.sh ci-db:test
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
check "psql is present"            'psql --version'
check "mysql is present"           'mysql --version'
check "redis-cli is present"       'redis-cli --version'
check "migrate is present"         'migrate -version'
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

# The CA bundle is what lets psql and mysql verify the certificate a managed
# database presents (RDS, Cloud SQL and Azure Database all chain to public
# CAs), so `sslmode=verify-full` fails without it. The HTTPS canary proves the
# bundle is present and functional.
check "CA bundle exists"           'test -s /etc/ssl/certs/ca-certificates.crt'
check "TLS verification works"     'curl -sSf --max-time 15 "https://ghcr.io/token?service=ghcr.io&scope=repository:greenblacked/ci-tools:pull" -o /dev/null'

check "workdir is /workspace"      '[ "$PWD" = /workspace ]'

# Clients only. A server here would be a second, unsupervised copy competing
# with the `services:` container that Actions actually health-checks.
check "no postgres server"         '! command -v postgres && ! command -v pg_ctl'
check "no mysql server"            '! command -v mysqld'
check "no redis server"            '! command -v redis-server'

# The image is shared across projects and public: connection strings,
# credentials and migration state must never be baked in.
check "no pgpass baked in"         '! test -e /root/.pgpass'
check "no my.cnf baked in"         '! test -e /root/.my.cnf'
check "no migrations baked in"     '! test -e /workspace/migrations'

if [ "$failed" -ne 0 ]; then
  echo "FAIL: one or more checks failed for $IMAGE" >&2
  exit 1
fi
echo "PASS: $IMAGE"
