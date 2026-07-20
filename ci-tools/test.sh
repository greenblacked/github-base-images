#!/usr/bin/env bash
# Smoke tests for the ci-tools image. Run against a built image before it is pushed.
#   ./ci-tools/test.sh ci-tools:test
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

# Every tool the image promises to ship. Each infra tool must not just exist
# but actually execute -- a wrong-arch binary passes `test -x` and fails here.
check "terraform is present"       'terraform version'
check "kubectl is present"         'kubectl version --client'
check "aws cli is present"         'aws --version'
check "docker cli is present"      'docker --version'
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
# every one of these tools talks to an HTTPS API.
check "CA bundle exists"           'test -s /etc/ssl/certs/ca-certificates.crt'
check "TLS verification works"     'curl -sSf https://releases.hashicorp.com/ -o /dev/null'

check "workdir is /workspace"      '[ "$PWD" = /workspace ]'

# The image is shared across projects and public: credentials, cluster access,
# and state must never be baked in.
check "no aws credentials"         '! test -e /root/.aws'
check "no kubeconfig"              '! test -e /root/.kube'
check "no docker config/creds"     '! test -e /root/.docker/config.json'
check "no terraform state/cache"   '! test -e /workspace/.terraform && ! compgen -G "/workspace/*.tfstate*"'
check "no docker daemon"           '! command -v dockerd'

if [ "$failed" -ne 0 ]; then
  echo "FAIL: one or more checks failed for $IMAGE" >&2
  exit 1
fi
echo "PASS: $IMAGE"
