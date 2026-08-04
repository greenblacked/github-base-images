#!/usr/bin/env bash
# Smoke tests for the ci-cloud image. Run against a built image before it is pushed.
#   ./ci-cloud/test.sh ci-cloud:test
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

# Every tool the image promises to ship. Each cloud CLI must actually execute,
# not just exist -- a wrong-arch binary passes `test -x` and fails here, and
# gcloud additionally fails if its Python interpreter is missing.
check "gcloud is present"          'gcloud version'
check "gsutil is present"          'gsutil version'
check "az is present"              'az version'
check "kubectl is present"         'kubectl version --client'
check "python3 is present"         'python3 --version'
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
# every one of these CLIs talks to an HTTPS API and nothing else.
check "CA bundle exists"           'test -s /etc/ssl/certs/ca-certificates.crt'
check "TLS verification works"     'curl -sSf --max-time 15 https://packages.microsoft.com/repos/azure-cli/ -o /dev/null'

check "workdir is /workspace"      '[ "$PWD" = /workspace ]'

# The Microsoft keyring must survive into the final image -- without it apt
# cannot verify azure-cli updates, and the signed-by pin silently stops
# meaning anything.
check "microsoft keyring present"  'test -s /usr/share/keyrings/microsoft.gpg'

# The image is shared across projects and public: cloud credentials, cluster
# access and account state must never be baked in.
check "no gcloud credentials"      '! test -e /root/.config/gcloud'
check "no azure credentials"       '! test -e /root/.azure'
check "no kubeconfig"              '! test -e /root/.kube'
check "no aws credentials"         '! test -e /root/.aws'
check "no active gcloud account"   '! gcloud auth list --format="value(account)" 2>/dev/null | grep -q .'

# The AWS CLI lives in ci-tools. Shipping a second copy here would mean two
# images to bump whenever it moves.
check "no aws cli baked in"        '! command -v aws'

if [ "$failed" -ne 0 ]; then
  echo "FAIL: one or more checks failed for $IMAGE" >&2
  exit 1
fi
echo "PASS: $IMAGE"
