#!/usr/bin/env bash
# Smoke tests for the ci-java21 image. Run against a built image before it is pushed.
#   ./ci-java21/test.sh ci-java21:test
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
check "java is present"            'java --version'
check "java is 21"                 'java --version | head -1 | grep -q " 21\."'
check "javac is present"           'javac --version'
check "jar is present"             'jar --version'
check "javac compiles a program"   'cd "$(mktemp -d)" && printf "public class S{public static void main(String[] a){}}\n" > S.java && javac S.java && test -f S.class'
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
# resolving dependencies from Maven Central depends on this working.
check "CA bundle exists"           'test -s /etc/ssl/certs/ca-certificates.crt'
check "TLS verification works"     'curl -sSf https://repo1.maven.org/maven2/ -o /dev/null'

check "workdir is /workspace"      '[ "$PWD" = /workspace ]'

# The image is shared across projects: dependencies belong in each repo's build
# file, not baked in here. Maven and Gradle are deliberately absent -- projects
# bring their own via mvnw/gradlew.
check "no maven baked in"          '! command -v mvn'
check "no gradle baked in"         '! command -v gradle'
check "no project baked in"        '! test -e /workspace/pom.xml && ! test -e /workspace/build.gradle'
check "no maven cache baked in"    '[ -z "$(ls -A "${HOME:-/root}/.m2" 2>/dev/null)" ]'
check "no gradle cache baked in"   '[ -z "$(ls -A "${HOME:-/root}/.gradle" 2>/dev/null)" ]'

if [ "$failed" -ne 0 ]; then
  echo "FAIL: one or more checks failed for $IMAGE" >&2
  exit 1
fi
echo "PASS: $IMAGE"
