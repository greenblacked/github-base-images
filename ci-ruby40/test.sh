#!/usr/bin/env bash
# Smoke tests for the ci-ruby40 image. Run against a built image before it is pushed.
#   ./ci-ruby40/test.sh ci-ruby40:test
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
check "ruby is present"            'ruby --version'
check "ruby is 4.0"                'ruby -e "exit(RUBY_VERSION.start_with?(\"4.0.\") ? 0 : 1)"'
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
check "TLS verification works"     'curl -sSf --max-time 15 https://rubygems.org/ -o /dev/null'

check "workdir is /workspace"      '[ "$PWD" = /workspace ]'

# The image is shared across projects: gems belong in each repo's Gemfile.lock,
# not baked in here.
check "no Gemfile baked in"        '! test -e /workspace/Gemfile'
check "no bundled gems baked in"   '! test -e /workspace/vendor/bundle'

# The global equivalent of ci-python313's "pip list is empty" and ci-go's
# "GOMODCACHE is empty". It targets GEM_HOME rather than `gem list` because Ruby
# ships default gems (bundler, json, psych, ...) as part of the runtime, so
# `gem list` can never be empty and asserting on it would fail on a stock image.
# GEM_HOME is where *installed* gems land, so it is the assertion that actually
# means "no project dependencies were baked in".
check "no gems baked in"           '[ -z "$(ls -A "${GEM_HOME:-/usr/local/bundle}/gems" 2>/dev/null)" ]'

check "no compiler baked in"       '! command -v gcc && ! command -v cc'

# json is replaced in place in the Dockerfile (CVE-2026-33210 in the default
# 2.18.0). What matters is the code that loads, and CI jobs load it through
# Bundler as well as plain require, so both are asserted -- Bundler with json
# unlisted, which resolves to the default gem, is exactly the path a
# side-by-side install would have left on 2.18.0.
check "json loads >= 2.19.2"       'ruby -rjson -e "exit(Gem::Version.new(JSON::VERSION) >= Gem::Version.new(\"2.19.2\") ? 0 : 1)"'
check "json parses via extension"  'ruby -rjson -e "exit(JSON::Parser == JSON::Ext::Parser && JSON.parse(%q({\"a\":[1]}))[\"a\"] == [1] ? 0 : 1)"'
check "json >= 2.19.2 under Bundler" 'd=$(mktemp -d) && printf "source \"https://rubygems.org\"\n" > "$d/Gemfile" && BUNDLE_GEMFILE="$d/Gemfile" ruby -rbundler/setup -rjson -e "exit(Gem::Version.new(JSON::VERSION) >= Gem::Version.new(\"2.19.2\") ? 0 : 1)"'
check "one json default gem"       '[ "$(ls "$(ruby -e "print Gem.default_specifications_dir")" | grep -c "^json-")" = 1 ]'

if [ "$failed" -ne 0 ]; then
  echo "FAIL: one or more checks failed for $IMAGE" >&2
  exit 1
fi
echo "PASS: $IMAGE"
