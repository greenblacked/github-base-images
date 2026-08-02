#!/usr/bin/env bash
# Smoke tests for the ci-dotnet9 image. Run against a built image before it is pushed.
#   ./ci-dotnet9/test.sh ci-dotnet9:test
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
check "dotnet is present"          'dotnet --version'
check "dotnet sdk is 9"            'dotnet --version | grep -q "^9\."'
check "dotnet lists an sdk"        'dotnet --list-sdks | grep -q "^9\."'
# `dotnet new` uses templates shipped in the SDK, so this needs no NuGet access
# and proves the SDK is functional rather than merely present.
check "dotnet scaffolds a project" 'd="$(mktemp -d)" && dotnet new console -o "$d/app" >/dev/null && test -f "$d/app/Program.cs"'
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
# `dotnet restore` against NuGet depends on this working.
check "CA bundle exists"           'test -s /etc/ssl/certs/ca-certificates.crt'
check "TLS verification works"     'curl -sSf https://api.nuget.org/v3/index.json -o /dev/null'

check "workdir is /workspace"      '[ "$PWD" = /workspace ]'

# The image is shared across projects: packages belong in each repo's lockfile,
# not baked in here.
check "no project baked in"        '! compgen -G "/workspace/*.csproj" && ! compgen -G "/workspace/*.sln"'
check "no nuget cache baked in"    '[ -z "$(ls -A "${NUGET_PACKAGES:-${HOME:-/root}/.nuget/packages}" 2>/dev/null)" ]'
check "no global tools baked in"   '[ -z "$(ls -A "${HOME:-/root}/.dotnet/tools" 2>/dev/null)" ]'

if [ "$failed" -ne 0 ]; then
  echo "FAIL: one or more checks failed for $IMAGE" >&2
  exit 1
fi
echo "PASS: $IMAGE"
