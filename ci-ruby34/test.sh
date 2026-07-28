#!/usr/bin/env bash
# Smoke tests for the ci-ruby34 image. Run against a built image before it is pushed.
#   ./ci-ruby34/test.sh ci-ruby34:test
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
check "ruby is present"            'ruby --version'
check "ruby is 3.4"                'ruby -e "exit(RUBY_VERSION.start_with?(\"3.4\") ? 0 : 1)"'
check "gem is present"             'gem --version'
check "bundler is present"         'bundler --version'
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
# bundle install depends on this working.
check "CA bundle exists"           'test -s /etc/ssl/certs/ca-certificates.crt'
check "TLS verification works"     'curl -sSf https://rubygems.org/ -o /dev/null'

check "workdir is /workspace"      '[ "$PWD" = /workspace ]'

# The image is shared across projects: gems belong in each repo's Gemfile.lock,
# not baked in here.
check "no Gemfile baked in"        '! test -e /workspace/Gemfile'
check "no bundled gems baked in"   '! test -e /workspace/vendor/bundle'

# The global equivalent of ci-python313's "pip list is empty" and ci-go125's
# "GOMODCACHE is empty". It targets GEM_HOME rather than `gem list` because Ruby
# ships default gems (bundler, json, psych, ...) as part of the runtime, so
# `gem list` can never be empty and asserting on it would fail on a stock image.
# GEM_HOME is where *installed* gems land, so it is the assertion that actually
# means "no project dependencies were baked in".
check "no gems baked in"           '[ -z "$(ls -A "${GEM_HOME:-/usr/local/bundle}/gems" 2>/dev/null)" ]'

check "no compiler baked in"       '! command -v gcc && ! command -v cc'

if [ "$failed" -ne 0 ]; then
  echo "FAIL: one or more checks failed for $IMAGE" >&2
  exit 1
fi
echo "PASS: $IMAGE"
