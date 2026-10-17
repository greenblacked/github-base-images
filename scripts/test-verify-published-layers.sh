#!/usr/bin/env bash
# Offline tests for scripts/verify-published-layers.sh, the check between
# build-image.yml's push and "Export digest" that the pushed image is the one
# that was tested. No daemon, no registry: docker is a fake on PATH that
# answers `docker image inspect` from local.json and `docker buildx imagetools
# inspect` from raw-<hex>.json / image-<hex>.json in a fixture directory, and
# sleep is a fake that only records how long it was asked to wait. Then the
# workflow itself is checked for the wiring the script relies on: the step
# sits between the push and the digest export, and the two builds get the
# same inputs.
#
#   ./scripts/test-verify-published-layers.sh   # run by scripts/lint.sh, so CI runs it too
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="$here/verify-published-layers.sh"
workflow="$here/../.github/workflows/build-image.yml"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

pass=0; failures=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { failures=$((failures + 1)); printf '  FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

mkdir -p "$work/bin"
# The fake docker. Every call is logged, one per line, to FAKE_LOG.
#   docker image inspect ... REF          -> $FAKE_DIR/local.json (FAKE_LOCAL_FAIL: fail)
#   docker buildx imagetools inspect --raw REPO@sha256:HEX
#                                         -> $FAKE_DIR/raw-HEX.json
#   docker buildx imagetools inspect --format '{{json .Image}}' REPO@sha256:HEX
#                                         -> $FAKE_DIR/image-HEX.json
# A missing fixture fails like a registry 404. While $FAKE_DIR/fails holds a
# number above 0, an imagetools call fails with a 502 and decrements it.
cat > "$work/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
ref="${*: -1}"
if [ "$1 $2" = "image inspect" ]; then
  if [ -n "${FAKE_LOCAL_FAIL:-}" ]; then echo "Error: No such image: $ref" >&2; exit 1; fi
  cat "$FAKE_DIR/local.json"; exit 0
fi
if [ "$1 $2 $3" != "buildx imagetools inspect" ]; then echo "fake docker: unexpected call: $*" >&2; exit 99; fi
n=$(cat "$FAKE_DIR/fails" 2>/dev/null || echo 0)
if [ "$n" -gt 0 ]; then
  echo $((n - 1)) > "$FAKE_DIR/fails"
  echo "ERROR: failed to do request: 502 Bad Gateway" >&2; exit 1
fi
hex="${ref##*@sha256:}"
case "$4" in
  --raw) f="$FAKE_DIR/raw-$hex.json" ;;
  --format) f="$FAKE_DIR/image-$hex.json" ;;
  *) echo "fake docker: unexpected imagetools call: $*" >&2; exit 99 ;;
esac
if [ ! -f "$f" ]; then echo "ERROR: $ref: not found" >&2; exit 1; fi
cat "$f"
EOF
cat > "$work/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SLEEP_LOG"
EOF
chmod +x "$work/bin/docker" "$work/bin/sleep"

h() { printf "$1%.0s" $(seq 64); }
L1="sha256:$(h 1)" L2="sha256:$(h 2)" L3="sha256:$(h 3)" LX="sha256:$(h e)"
INDEX="$(h a)" MANIFEST="$(h b)" ATTEST="$(h c)" OTHER="$(h d)"
REPO="ghcr.io/o/ci-test"
PUSHED="$REPO@sha256:$INDEX"
ENV='["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin","LANG=C.UTF-8"]'
LABELS='{"org.opencontainers.image.source":"https://github.com/o/r","org.opencontainers.image.licenses":"MIT"}'

# local [LAYERS-JSON] [CONFIG-JSON] -- the tested image, as `docker image
# inspect` prints it: unset fields as null and "".
local_image() {
  local layers=${1:-"[\"$L1\",\"$L2\",\"$L3\"]"}
  local config=${2:-"{\"Env\":$ENV,\"Cmd\":[\"bash\"],\"Entrypoint\":null,\"User\":\"\",\"WorkingDir\":\"\",\"Labels\":$LABELS}"}
  printf '{"Id":"sha256:%s","Os":"linux","Architecture":"amd64","Created":"2026-10-17T10:00:00Z","RootFS":{"Type":"layers","Layers":%s},"Config":%s}\n' \
    "$(h f)" "$layers" "$config" > "$fx/local.json"
}
# remote HEX [LAYERS-JSON] [CONFIG-JSON] [ARCH] -- an image config in the
# registry, as `imagetools inspect --format '{{json .Image}}'` prints it:
# unset fields simply absent, and a different created time and history.
remote_image() {
  local hex=$1
  local layers=${2:-"[\"$L1\",\"$L2\",\"$L3\"]"}
  local config=${3:-"{\"Env\":$ENV,\"Cmd\":[\"bash\"],\"Labels\":$LABELS}"}
  local arch=${4:-amd64}
  printf '{"created":"2026-10-17T10:05:00Z","architecture":"%s","os":"linux","rootfs":{"type":"layers","diff_ids":%s},"config":%s,"history":[{"created":"2026-10-17T10:05:00Z","created_by":"RUN x"}]}\n' \
    "$arch" "$layers" "$config" > "$fx/image-$hex.json"
}
# index HEX ENTRY... -- an OCI index; each ENTRY is DIGESTHEX:OS/ARCH, or
# DIGESTHEX:att for an attestation manifest (platform unknown/unknown).
index() {
  local hex=$1 e d p entries=()
  shift
  for e in "$@"; do
    d=${e%%:*} p=${e#*:}
    if [ "$p" = att ]; then
      entries+=("{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:$d\",\"size\":1,\"annotations\":{\"vnd.docker.reference.digest\":\"sha256:$MANIFEST\",\"vnd.docker.reference.type\":\"attestation-manifest\"},\"platform\":{\"architecture\":\"unknown\",\"os\":\"unknown\"}}")
    else
      entries+=("{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:$d\",\"size\":1,\"platform\":{\"architecture\":\"${p#*/}\",\"os\":\"${p%%/*}\"}}")
    fi
  done
  local IFS=,
  printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[%s]}\n' "${entries[*]}" > "$fx/raw-$hex.json"
}
# manifest HEX -- a plain image manifest (no index around it).
manifest() {
  printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%s","size":1},"layers":[]}\n' \
    "$(h 9)" > "$fx/raw-$1.json"
}

# fresh -- a new, empty fixture directory with the standard tested image.
fresh() {
  fx=$(mktemp -d "$work/fx.XXXX")
  local_image
}
# standard -- the push as buildx makes it: index -> image manifest + attestation.
standard() {
  index "$INDEX" "$MANIFEST:linux/amd64" "$ATTEST:att"
  remote_image "$MANIFEST"
}

# run [VAR=value...] -- ARGS: runs the script against the fixture directory;
# sets rc, out, calls, sleeps.
run() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  out="$work/out"; calls="$work/calls"; sleeps="$work/sleeps"
  : > "$calls"; : > "$sleeps"
  rc=0
  env ${envs[@]+"${envs[@]}"} PATH="$work/bin:$PATH" FAKE_DIR="$fx" FAKE_LOG="$calls" FAKE_SLEEP_LOG="$sleeps" \
    "$script" "$@" > "$out" 2>&1 || rc=$?
}
has()    { grep -qF -- "$1" "$out"; }
hasnt()  { ! grep -qF -- "$1" "$out"; }
ncalls() { wc -l < "$calls" | tr -d ' '; }
slept()  { paste -sd, "$sleeps"; }

echo "case 1: the push as buildx makes it (image + attestation), identical -> 0"
fresh; standard
run -- ci-test:test "$PUSHED"
check "exit 0" [ "$rc" -eq 0 ]
check "says so, with the layer count" has "the pushed image $REPO@sha256:$MANIFEST is the tested image ci-test:test: the same 3 layers"
check "no annotation" hasnt "::"
check "inspected the tested image in the daemon" grep -qx "image inspect --format {{json .}} ci-test:test" "$calls"
check "read the pushed index raw" grep -qx "buildx imagetools inspect --raw $PUSHED" "$calls"
check "read the config of the image manifest, not of the index or the attestation" \
  grep -qx "buildx imagetools inspect --format {{json .Image}} $REPO@sha256:$MANIFEST" "$calls"
check "never read the attestation manifest" bash -c "! grep -q '$ATTEST' '$calls'"
check "3 docker calls, no waits" [ "$(ncalls):$(slept)" = "3:" ]

echo "case 2: attestation first in the index -> still the image manifest, 0"
fresh; index "$INDEX" "$ATTEST:att" "$MANIFEST:linux/amd64"; remote_image "$MANIFEST"
run -- ci-test:test "$PUSHED"
check "exit 0" [ "$rc" -eq 0 ]
check "read the image manifest's config" grep -qx "buildx imagetools inspect --format {{json .Image}} $REPO@sha256:$MANIFEST" "$calls"

echo "case 3: a plain image manifest, no index -> its own config, 0"
fresh; manifest "$INDEX"; remote_image "$INDEX"
run -- ci-test:test "$PUSHED"
check "exit 0" [ "$rc" -eq 0 ]
check "read the config of the pushed digest itself" grep -qx "buildx imagetools inspect --format {{json .Image}} $PUSHED" "$calls"

echo "case 4: created and history differ, unset fields spelled differently -> 0"
# The fixtures already differ there (created 10:00 vs 10:05, a history only
# remotely, Entrypoint null / User "" / WorkingDir "" locally vs absent).
fresh; standard
run -- ci-test:test "$PUSHED"
check "exit 0" [ "$rc" -eq 0 ]
fresh; local_image "[\"$L1\",\"$L2\",\"$L3\"]" "{\"Env\":$ENV,\"Cmd\":[\"bash\"],\"Entrypoint\":[],\"Labels\":$LABELS,\"User\":null}"
index "$INDEX" "$MANIFEST:linux/amd64" "$ATTEST:att"
remote_image "$MANIFEST" "[\"$L1\",\"$L2\",\"$L3\"]" "{\"Env\":$ENV,\"Cmd\":[\"bash\"],\"Entrypoint\":null,\"User\":\"\",\"WorkingDir\":\"\",\"Labels\":$LABELS}"
run -- ci-test:test "$PUSHED"
check "[] / null / \"\" / absent are all unset -> exit 0" [ "$rc" -eq 0 ]

echo "case 5: the last layer differs (the push rebuilt a step) -> 1"
fresh; index "$INDEX" "$MANIFEST:linux/amd64" "$ATTEST:att"
remote_image "$MANIFEST" "[\"$L1\",\"$L2\",\"$LX\"]"
run -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "the error says it is not the tested image" has "::error::the pushed image $REPO@sha256:$MANIFEST is NOT the image that was tested (ci-test:test)"
check "  names the first differing layer, with both diff_ids" has "they first differ at layer 3: tested $L3, pushed $LX"
check "  and says nothing is published" has "Its digest is not exported, so it is not added to the multi-arch index, signed or attested"
check "no success line" hasnt "is the tested image"

echo "case 6: the first layer differs (a moved base tag) -> 1, at layer 1"
fresh; index "$INDEX" "$MANIFEST:linux/amd64" "$ATTEST:att"
remote_image "$MANIFEST" "[\"$LX\",\"$L2\",\"$L3\"]"
run -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "first differ at layer 1" has "they first differ at layer 1: tested $L1, pushed $LX"

echo "case 7: an extra layer pushed -> 1"
fresh; index "$INDEX" "$MANIFEST:linux/amd64" "$ATTEST:att"
remote_image "$MANIFEST" "[\"$L1\",\"$L2\",\"$L3\",\"$LX\"]"
run -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "counts both, says one is a prefix" has "layers: the tested image has 3, the pushed one 4; the shorter is a prefix of the longer"

echo "case 8: same layers in another order -> 1"
fresh; index "$INDEX" "$MANIFEST:linux/amd64" "$ATTEST:att"
remote_image "$MANIFEST" "[\"$L1\",\"$L3\",\"$L2\"]"
run -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "first differ at layer 2" has "they first differ at layer 2"

echo "case 9: same layers, different Env -> 1, naming Env"
fresh; index "$INDEX" "$MANIFEST:linux/amd64" "$ATTEST:att"
remote_image "$MANIFEST" "[\"$L1\",\"$L2\",\"$L3\"]" "{\"Env\":[\"PATH=/evil:/usr/bin\"],\"Cmd\":[\"bash\"],\"Labels\":$LABELS}"
run -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "names Env with both values" has 'Env: tested ["PATH=/usr/local/sbin'
check "  and the pushed value" has 'pushed ["PATH=/evil:/usr/bin"]'
check "no layer complaint" hasnt "layers:"

echo "case 10: Entrypoint, User and Cmd differ -> 1, all three listed"
fresh; index "$INDEX" "$MANIFEST:linux/amd64" "$ATTEST:att"
remote_image "$MANIFEST" "[\"$L1\",\"$L2\",\"$L3\"]" "{\"Env\":$ENV,\"Cmd\":[\"sh\"],\"Entrypoint\":[\"/x\"],\"User\":\"root\",\"Labels\":$LABELS}"
run -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "Entrypoint listed" has 'Entrypoint: tested null, pushed ["/x"]'
check "User listed" has 'User: tested null, pushed "root"'
check "Cmd listed" has 'Cmd: tested ["bash"], pushed ["sh"]'

echo "case 11: WorkingDir and Labels differ -> 1"
fresh; index "$INDEX" "$MANIFEST:linux/amd64" "$ATTEST:att"
remote_image "$MANIFEST" "[\"$L1\",\"$L2\",\"$L3\"]" "{\"Env\":$ENV,\"Cmd\":[\"bash\"],\"WorkingDir\":\"/w\",\"Labels\":{\"x\":\"y\"}}"
run -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "WorkingDir listed" has 'WorkingDir: tested null, pushed "/w"'
check "Labels listed" has 'Labels: tested {'

echo "case 12: the image config is for another architecture -> 1"
fresh; index "$INDEX" "$MANIFEST:linux/amd64" "$ATTEST:att"
remote_image "$MANIFEST" "[\"$L1\",\"$L2\",\"$L3\"]" "{\"Env\":$ENV,\"Cmd\":[\"bash\"],\"Labels\":$LABELS}" arm64
run -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "architecture listed" has 'architecture: tested "amd64", pushed "arm64"'

echo "case 13: the index's image is for another platform -> 1, config never read"
fresh; index "$INDEX" "$MANIFEST:linux/arm64" "$ATTEST:att"; remote_image "$MANIFEST"
run -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "says which platforms" has "its image is linux/arm64, the tested one linux/amd64"
check "no config read" bash -c "! grep -q 'json .Image' '$calls'"

echo "case 14: two images in the index -> 1"
fresh; index "$INDEX" "$MANIFEST:linux/amd64" "$OTHER:linux/arm64" "$ATTEST:att"; remote_image "$MANIFEST"
run -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "says how many" has "2 image manifests besides attestations, expected 1"

echo "case 15: only an attestation in the index -> 1"
fresh; index "$INDEX" "$ATTEST:att"
run -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "says none" has "0 image manifests besides attestations, expected 1"

echo "case 16: neither an index nor a manifest -> 1"
fresh; printf '{"schemaVersion":2}\n' > "$fx/raw-$INDEX.json"
run -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "says what it is not" has "neither an image index nor an image manifest"

echo "case 17: registry 502 twice, then fine -> 0 after 5s and 15s"
fresh; standard; echo 2 > "$fx/fails"
run -- ci-test:test "$PUSHED"
check "exit 0" [ "$rc" -eq 0 ]
check "waited 5s, 15s" [ "$(slept)" = "5,15" ]
check "each failure a warning naming the ref" has "::warning::reading $PUSHED failed (exit 1: ERROR: failed to do request: 502 Bad Gateway"
check "no error" hasnt "::error::"

echo "case 18: the registry never answers -> 1, never a pass"
fresh; standard; echo 99 > "$fx/fails"
run -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "3 attempts, waits only between them" [ "$(slept)" = "5,15" ]
check "the could-not-read error" has "::error::could not read the pushed image $PUSHED from the registry after 3 attempts"
check "  says it is not published" has "so it is not published"
check "no success line" hasnt "is the tested image"
fresh; standard; echo 1 > "$fx/fails"
run VERIFY_LAYERS_DELAYS=0 -- ci-test:test "$PUSHED"
check "VERIFY_LAYERS_DELAYS=0: one retry, one 0s wait, then 0" [ "$rc:$(slept)" = "0:0" ]

echo "case 19: the image config cannot be read -> 1"
fresh; index "$INDEX" "$MANIFEST:linux/amd64" "$ATTEST:att"
run VERIFY_LAYERS_DELAYS=0 -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "the error names the manifest" has "::error::could not read the image config of $REPO@sha256:$MANIFEST"

echo "case 20: an image config without a layer list -> 1"
fresh; index "$INDEX" "$MANIFEST:linux/amd64" "$ATTEST:att"
printf '{"os":"linux","architecture":"amd64","config":{}}\n' > "$fx/image-$MANIFEST.json"
run -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "says so" has "::error::could not read the layers of the pushed image"
fresh; index "$INDEX" "$MANIFEST:linux/amd64" "$ATTEST:att"
remote_image "$MANIFEST" '["not-a-digest"]'
run -- ci-test:test "$PUSHED"
check "a malformed diff_id is no layer list either -> 1" [ "$rc" -eq 1 ]
fresh; standard; local_image '[]'
run -- ci-test:test "$PUSHED"
check "a tested image with no layers -> 1" [ "$rc" -eq 1 ]
check "  says so" has "::error::could not read the layers of the tested image ci-test:test"

echo "case 21: the tested image is not in the daemon -> 1, registry never asked"
fresh; standard
run FAKE_LOCAL_FAIL=1 -- ci-test:test "$PUSHED"
check "exit 1" [ "$rc" -eq 1 ]
check "the error names it" has "::error::could not inspect the tested image ci-test:test in the local daemon"
check "no imagetools call" bash -c "! grep -q imagetools '$calls'"

echo "case 22: usage -> 2, no docker call"
fresh; standard
for args in "" "ci-test:test" "ci-test:test $REPO:bookworm-v1" "ci-test:test $REPO@sha256:abc" \
            "ci-test:test $REPO@sha256:$(h A)" "ci-test:test @sha256:$INDEX" "ci-test:test $PUSHED extra"; do
  # shellcheck disable=SC2086 # split on purpose: each string is an argument list
  run -- $args
  check "rejects '${args}'" [ "$rc:$(ncalls)" = "2:0" ]
done
run -- "" "$PUSHED"
check "rejects an empty local image" [ "$rc:$(ncalls)" = "2:0" ]

echo "the workflow wiring"
step_line() { grep -n -- "- name: $1" "$workflow" | head -1 | cut -d: -f1; }
push=$(step_line "Push (")
verify=$(step_line "Verify the pushed image is the tested one")
export_=$(step_line "Export digest")
check "build-image.yml has the push, verify and export steps" bash -c "[ -n '$push' ] && [ -n '$verify' ] && [ -n '$export_' ]"
check "  verify comes after the push and before the digest export" \
  bash -c "[ '${push:-0}' -lt '${verify:-0}' ] && [ '${verify:-0}' -lt '${export_:-0}' ]"
check "  verify runs the script on <image>:test and the pushed digest" \
  bash -c "sed -n '${verify:-1},${export_:-1}p' '$workflow' | grep -qF './scripts/verify-published-layers.sh \"\$IMAGE:test\" \"\$REPO@\$DIGEST\"'"
check "  with the push step's digest" \
  bash -c "sed -n '${verify:-1},${export_:-1}p' '$workflow' | grep -qF 'DIGEST: \${{ steps.push.outputs.digest }}'"
# The two docker/build-push-action steps must get the same inputs, or the
# push is a different build and the check above fails every publish.
builds=$(grep -c 'uses: docker/build-push-action@' "$workflow" || true)
check "exactly two build-push-action steps" [ "$builds" -eq 2 ]
for key in context file platforms build-args; do
  vals=$(awk -v k="$key" '
    /uses: docker\/build-push-action@/ { inb = 1; next }
    inb && /^      - name:/ { inb = 0 }
    inb && $1 == k ":" { v = $0; sub(/^[^:]*:[[:space:]]*/, "", v)
                         if (v == "|") { getline; v = $0; sub(/^[[:space:]]+/, "", v) }
                         print v }' "$workflow" | sort -u)
  check "  same $key in both builds ($(printf '%s' "$vals" | head -1))" \
    [ "$(printf '%s\n' "$vals" | grep -c .)" -eq 1 ]
done
base=$(step_line "Base image baseline")
build=$(step_line "Build \${{ inputs.image }}")
check "  the build base is pinned once, before the test build" \
  bash -c "[ -n '$base' ] && [ -n '$build' ] && [ '${base:-0}' -lt '${build:-0}' ]"
check "  and both builds take BASE_IMAGE from it" \
  bash -c "[ \"\$(grep -cF 'BASE_IMAGE=\${{ steps.upstream.outputs.ref || env.BUILD_BASE_IMAGE }}' '$workflow')\" -eq 2 ]"

echo
echo "$pass passed, $failures failed"
[ "$failures" -eq 0 ]
