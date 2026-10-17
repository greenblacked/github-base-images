#!/usr/bin/env bash
# Prove that the image just pushed is the image that was tested. Run by
# build-image.yml's "Verify the pushed image is the tested one" step, between
# the push and "Export digest", so a mismatch fails the job before its digest
# can reach the merge job -- nothing is added to the multi-arch index, signed
# or attested.
#
#   ./scripts/verify-published-layers.sh <local-image> <repo>@sha256:<digest>
#
# <local-image> is the image the smoke tests, the vulnerability gate and the
# secret gate ran on (`<image>:test`, loaded into the daemon by the first
# build). <repo>@sha256:<digest> is what the push step reported: the digest of
# the index buildx pushed, which holds the image manifest for the one platform
# built plus its attestation manifest (SBOM and provenance, platform
# unknown/unknown). The attestation manifest is not the image and is ignored
# here: it has no image config, and what it records is the build, not what
# the image contains. A plain image manifest (no attestations) is accepted
# too.
#
# Why there are two builds at all: the test build has to `load:` into the
# daemon to be run and scanned, and the docker exporter that does that cannot
# carry attestations or push; the push build is the same build again with the
# image exporter. Same builder, context, Dockerfile, platform and build args,
# so every step is a cache hit on the builder's own local cache and the push
# re-exports the very layers the test build produced. This script is what
# turns "should be identical" into "is identical, or nothing is published":
# a step that rebuilt instead of hitting the cache (a moved base tag, a
# changed build arg, an evicted cache record) yields a layer with a different
# diff_id, and the job fails here.
#
# What is compared, after normalising empty values (null, "", [] and {}) to
# null on both sides, since the daemon and the registry spell "unset"
# differently:
#   - rootfs.diff_ids, in order -- the uncompressed digest of every layer, so
#     the same file system bit for bit. (Not the layer blob digests: the
#     daemon stores layers uncompressed, the registry gzip-compressed; the
#     diff_id is the one both agree on.)
#   - os and architecture;
#   - config Env, Entrypoint, Cmd, User, WorkingDir and Labels -- what decides
#     how the image runs.
# Not compared: `created` and `history`, which are timestamps and comments
# written at export time, and the attestations, which are not part of the
# image.
#
# Registry reads are retried, 5s and 15s apart (VERIFY_LAYERS_DELAYS
# overrides; the offline tests use 0s), because the image was pushed seconds
# ago and one hiccup should not throw away a good build. A read that never
# succeeds is a failure, never a pass: an image that could not be compared has
# not been shown to be the tested one.
#
# Credentials: none of its own. The Docker CLI config the workflow's "Login"
# step wrote is what `docker buildx imagetools inspect` reads the package with.
#
# Exit: 0 identical; 1 different, or could not be compared; 2 usage.
# Requires docker (with buildx) and jq.
set -euo pipefail

usage() {
  echo "usage: verify-published-layers.sh <local-image> <repo>@sha256:<digest>" >&2
  exit 2
}
[ $# -eq 2 ] || usage
local_ref=$1 pushed=$2
[ -n "$local_ref" ] || usage
[[ "$pushed" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] || usage
repo=${pushed%@*}
read -r -a delays <<< "${VERIFY_LAYERS_DELAYS:-5 15}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
  echo "::error::$*"
  exit 1
}
oneline() { tr '\n' ' ' < "$1" | cut -c1-300; }

# inspect OUT ARGS... -- `docker buildx imagetools inspect ARGS...` into OUT,
# retried; returns non-zero when every attempt failed (the error is in
# $tmp/err).
inspect() {
  local out=$1 i rc attempts=$(( ${#delays[@]} + 1 ))
  shift
  for ((i = 0; i < attempts; i++)); do
    rc=0
    docker buildx imagetools inspect "$@" > "$out" 2> "$tmp/err" || rc=$?
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    if [ "$i" -lt "${#delays[@]}" ]; then
      echo "::warning::reading ${*: -1} failed (exit $rc: $(oneline "$tmp/err")); retrying in ${delays[$i]}s"
      sleep "${delays[$i]}"
    fi
  done
  return 1
}

# The fields compared, from either side, as one normalised object.
jq_norm='def norm: if . == null or . == "" or . == [] or . == {} then null else . end;'

# --- The tested image, from the daemon.
rc=0
docker image inspect --format '{{json .}}' "$local_ref" > "$tmp/local-raw.json" 2> "$tmp/err" || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "could not inspect the tested image $local_ref in the local daemon (exit $rc: $(oneline "$tmp/err")) -- the pushed image cannot be shown to be the tested one, so it is not published"
fi
rc=0
jq -e "$jq_norm"'
  {os: (.Os | norm), architecture: (.Architecture | norm),
   diff_ids: (.RootFS.Layers | norm),
   Env: (.Config.Env | norm), Entrypoint: (.Config.Entrypoint | norm), Cmd: (.Config.Cmd | norm),
   User: (.Config.User | norm), WorkingDir: (.Config.WorkingDir | norm), Labels: (.Config.Labels | norm)}
  | if (.diff_ids | type) == "array" and all(.diff_ids[]; type == "string" and test("^sha256:[0-9a-f]{64}$"))
    then . else error("no layer list") end' "$tmp/local-raw.json" > "$tmp/local.json" 2> "$tmp/err" || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "could not read the layers of the tested image $local_ref ($(oneline "$tmp/err"))"
fi

# --- The pushed image: the index (or manifest) the push reported, then the
# --- one image manifest in it, then that manifest's config.
if ! inspect "$tmp/top.json" --raw "$pushed"; then
  fail "could not read the pushed image $pushed from the registry after $(( ${#delays[@]} + 1 )) attempts ($(oneline "$tmp/err")) -- it cannot be shown to be the tested one, so it is not published"
fi
rc=0
manifest=$(jq -r --slurpfile l "$tmp/local.json" '
  if (.manifests | type) == "array" then
    [.manifests[]
     | select((.annotations["vnd.docker.reference.type"] // "") != "attestation-manifest"
              and (.platform.os // "") != "unknown")] as $images
    | if ($images | length) != 1 then error("\($images | length) image manifests besides attestations, expected 1")
      elif ($images[0].platform.os != $l[0].os or $images[0].platform.architecture != $l[0].architecture)
      then error("its image is \($images[0].platform.os)/\($images[0].platform.architecture), the tested one \($l[0].os)/\($l[0].architecture)")
      else $images[0].digest end
  elif (.config | type) == "object" then "self"
  else error("neither an image index nor an image manifest") end' "$tmp/top.json" 2> "$tmp/err") || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "the pushed $pushed is not one image for one platform: $(oneline "$tmp/err")"
fi
if [ "$manifest" = self ]; then
  manifest_ref=$pushed
elif [[ "$manifest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  manifest_ref="$repo@$manifest"
else
  fail "the pushed $pushed names an image manifest digest that is not a sha256 digest: $manifest"
fi

if ! inspect "$tmp/remote-raw.json" --format '{{json .Image}}' "$manifest_ref"; then
  fail "could not read the image config of $manifest_ref after $(( ${#delays[@]} + 1 )) attempts ($(oneline "$tmp/err")) -- it cannot be shown to be the tested one, so it is not published"
fi
rc=0
jq -e "$jq_norm"'
  {os: (.os | norm), architecture: (.architecture | norm),
   diff_ids: (.rootfs.diff_ids | norm),
   Env: (.config.Env | norm), Entrypoint: (.config.Entrypoint | norm), Cmd: (.config.Cmd | norm),
   User: (.config.User | norm), WorkingDir: (.config.WorkingDir | norm), Labels: (.config.Labels | norm)}
  | if (.diff_ids | type) == "array" and all(.diff_ids[]; type == "string" and test("^sha256:[0-9a-f]{64}$"))
    then . else error("no layer list") end' "$tmp/remote-raw.json" > "$tmp/remote.json" 2> "$tmp/err" || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "could not read the layers of the pushed image $manifest_ref ($(oneline "$tmp/err"))"
fi

# --- The comparison. Every difference is listed before failing, so one run
# --- says everything that is wrong.
rc=0
diffs=$(jq -r --slurpfile r "$tmp/remote.json" '
  . as $l | $r[0] as $r
  | ( if $l.diff_ids == $r.diff_ids then empty
      else
        ([$l.diff_ids, $r.diff_ids] | map(length) | min) as $n
        | ([range(0; $n) | select($l.diff_ids[.] != $r.diff_ids[.])] | first) as $at
        | "layers: the tested image has \($l.diff_ids | length), the pushed one \($r.diff_ids | length)"
          + (if $at == null then "; the shorter is a prefix of the longer"
             else "; they first differ at layer \($at + 1): tested \($l.diff_ids[$at]), pushed \($r.diff_ids[$at])" end)
      end ),
    ( ["os", "architecture", "Env", "Entrypoint", "Cmd", "User", "WorkingDir", "Labels"][] as $k
      | select($l[$k] != $r[$k])
      | "\($k): tested \($l[$k] | tojson | .[0:200]), pushed \($r[$k] | tojson | .[0:200])" )
  ' "$tmp/local.json" 2> "$tmp/err") || rc=$?
if [ "$rc" -ne 0 ]; then
  fail "could not compare $local_ref with $manifest_ref ($(oneline "$tmp/err"))"
fi
if [ -n "$diffs" ]; then
  while IFS= read -r line; do
    echo "  $line"
  done <<< "$diffs"
  fail "the pushed image $manifest_ref is NOT the image that was tested ($local_ref): $(printf '%s' "$diffs" | paste -sd ';' - | cut -c1-500). Its digest is not exported, so it is not added to the multi-arch index, signed or attested. The push build must re-export the test build's layers from the cache; see the Push step in build-image.yml"
fi

layers=$(jq '.diff_ids | length' "$tmp/local.json")
echo "the pushed image $manifest_ref is the tested image $local_ref: the same $layers layers (diff_ids), platform, Env, Entrypoint, Cmd, User, WorkingDir and Labels"
