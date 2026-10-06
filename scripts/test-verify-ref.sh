#!/usr/bin/env bash
# Offline tests for scripts/verify-ref.sh, the bounded retry around
# build-image.yml's post-sign verification. No network, no registry, no
# cosign: check-published.sh is a fake (VERIFY_REF_CHECK) that exits with the
# next code of a scripted sequence, and sleep is a fake on PATH that only
# records how long it was asked to wait.
#
#   ./scripts/test-verify-ref.sh       # run by scripts/lint.sh, so CI runs it too
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
verify="$here/verify-ref.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

pass=0; failures=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { failures=$((failures + 1)); printf '  FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

mkdir -p "$work/bin"
# The fake checker: log the arguments, then exit with the first code left in
# FAKE_CODES (one per line) and drop it. An exhausted sequence is exit 99, so
# a call the case did not expect cannot pass by accident.
cat > "$work/check-published.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CHECK_LOG"
code=$(head -n1 "$FAKE_CODES")
tail -n +2 "$FAKE_CODES" > "$FAKE_CODES.next"; mv "$FAKE_CODES.next" "$FAKE_CODES"
echo "fake check-published: exit ${code:-99}"
exit "${code:-99}"
EOF
# The fake sleep: record the requested wait, do not wait.
cat > "$work/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SLEEP_LOG"
EOF
chmod +x "$work/check-published.sh" "$work/bin/sleep"

unset VERIFY_REF_DELAYS VERIFY_REF_CHECK
REF="ghcr.io/o/ci-test@sha256:$(printf 'a%.0s' $(seq 64))"

# run CODES... [-- ARGS...] -- runs verify-ref.sh against the fake with that
# exit-code sequence; sets rc, out, and the call/sleep logs.
run() {
  local codes=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do codes+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  out="$work/out"; calls="$work/calls"; sleeps="$work/sleeps"
  printf '%s\n' "${codes[@]}" > "$work/codes"
  : > "$calls"; : > "$sleeps"
  rc=0
  PATH="$work/bin:$PATH" VERIFY_REF_CHECK="$work/check-published.sh" \
    FAKE_CODES="$work/codes" FAKE_CHECK_LOG="$calls" FAKE_SLEEP_LOG="$sleeps" \
    "$verify" "$@" > "$out" 2>&1 || rc=$?
}
ncalls() { wc -l < "$calls" | tr -d ' '; }
slept()  { paste -sd, "$sleeps"; }
has()    { grep -qF -- "$1" "$out"; }

echo "case 1: 3 then 0 -> passes on the second attempt"
run 3 0 -- "$REF"
check "exit 0" [ "$rc" -eq 0 ]
check "2 attempts" [ "$(ncalls)" -eq 2 ]
check "each attempt ran check-published.sh --ref REF" [ "$(sort -u "$calls")" = "--ref $REF" ]
check "waited 10s once" [ "$(slept)" = "10" ]
check "attempt 1 logged" has "verify-ref: attempt 1 of 4: check-published.sh --ref $REF"
check "attempt 2 logged" has "verify-ref: attempt 2 of 4: check-published.sh --ref $REF"
check "the failed attempt is a warning" has "::warning::attempt 1 of 4 to verify $REF failed (check-published.sh exit 3); retrying in 10s"
check "verified, naming the attempt" has "verified: $REF is signed by the expected identity and carries SBOM and provenance attestations (attempt 2 of 4)"
check "no error" bash -c "! grep -q '::error::' '$out'"

echo "case 2: 3, 3, 3, 3 -> fails after 4 attempts with the issue error"
run 3 3 3 3 -- "$REF"
check "exit 3" [ "$rc" -eq 3 ]
check "4 attempts" [ "$(ncalls)" -eq 4 ]
check "waited 10s, 20s, 40s -- and not after the last" [ "$(slept)" = "10,20,40" ]
check "the error names the attempts" has "::error::$REF failed post-sign verification after 4 attempts: the signature does not verify under the expected identity, or an SBOM/provenance attestation is missing (see the table above)"
check "the last attempt says none are left" has "::warning::attempt 4 of 4 to verify $REF failed (check-published.sh exit 3); no attempts left"
check "not reported as verified" bash -c "! grep -q '^verified' '$out'"

echo "case 3: 1 then 0 -> a check that could not run is retried, then passes"
run 1 0 -- "$REF"
check "exit 0" [ "$rc" -eq 0 ]
check "2 attempts" [ "$(ncalls)" -eq 2 ]
check "waited 10s" [ "$(slept)" = "10" ]
check "the failed attempt is a warning with its exit" has "::warning::attempt 1 of 4 to verify $REF failed (check-published.sh exit 1); retrying in 10s"

echo "case 4: 2 (usage) -> fails at once, not retried"
run 2 0 -- "$REF"
check "exit 2" [ "$rc" -eq 2 ]
check "1 attempt" [ "$(ncalls)" -eq 1 ]
check "no wait" [ ! -s "$sleeps" ]
check "the usage error" has "::error::check-published.sh --ref exited 2 on attempt 1 (usage or unexpected error; not retried)"

echo "case 5: an unexpected code (127) -> fails at once, not retried"
run 127 0 -- "$REF"
check "exit 127" [ "$rc" -eq 127 ]
check "1 attempt" [ "$(ncalls)" -eq 1 ]
check "no wait" [ ! -s "$sleeps" ]

echo "case 6: 1, 1, 1, 1 -> fails after 4 with the could-not-check error"
run 1 1 1 1 -- "$REF"
check "exit 1" [ "$rc" -eq 1 ]
check "4 attempts" [ "$(ncalls)" -eq 4 ]
check "waited 10s, 20s, 40s" [ "$(slept)" = "10,20,40" ]
check "the could-not-check error, with the attempts" has "::error::could not verify $REF after 4 attempts: the signature or attestation check itself failed to run (see the log above) -- treated as a failure, not a pass"

echo "case 7: only the last attempt decides -- 3, 1, 3, 1 ends as could-not-check"
run 3 1 3 1 -- "$REF"
check "exit 1" [ "$rc" -eq 1 ]
check "4 attempts" [ "$(ncalls)" -eq 4 ]
check "the could-not-check error" has "::error::could not verify $REF after 4 attempts"

echo "case 8: a retry that hits a usage code stops there"
run 3 2 0 -- "$REF"
check "exit 2" [ "$rc" -eq 2 ]
check "2 attempts" [ "$(ncalls)" -eq 2 ]
check "one wait" [ "$(slept)" = "10" ]

echo "case 9: 0 at once -> one attempt, no wait"
run 0 -- "$REF"
check "exit 0" [ "$rc" -eq 0 ]
check "1 attempt" [ "$(ncalls)" -eq 1 ]
check "no wait" [ ! -s "$sleeps" ]
check "verified (attempt 1 of 4)" has "(attempt 1 of 4)"

echo "case 10: --after-attestation keeps that step's own messages"
run 3 3 3 3 -- --after-attestation "$REF"
check "exit 3" [ "$rc" -eq 3 ]
check "4 attempts" [ "$(ncalls)" -eq 4 ]
check "the re-verify issue error" has "::error::$REF passed post-sign verification before the GitHub attestation was attached and fails it now, after 4 attempts:"
check "warnings say re-verify" has "::warning::attempt 1 of 4 to re-verify $REF after attestation failed (check-published.sh exit 3); retrying in 10s"
run 1 1 1 1 -- --after-attestation "$REF"
check "could-not-check after attestation" has "::error::could not re-verify $REF after attestation, after 4 attempts:"
run 3 0 -- --after-attestation "$REF"
check "passes on retry" [ "$rc" -eq 0 ]
check "  with the after-attestation message" has "verified: $REF still verifies with the GitHub attestation attached (attempt 2 of 4)"

echo "case 11: VERIFY_REF_DELAYS sets the waits and the attempt count"
VERIFY_REF_DELAYS="0 0" run 3 3 3 3 -- "$REF"
check "exit 3" [ "$rc" -eq 3 ]
check "3 attempts" [ "$(ncalls)" -eq 3 ]
check "waits 0s, 0s" [ "$(slept)" = "0,0" ]
check "error says 3 attempts" has "after 3 attempts"
VERIFY_REF_DELAYS="" run 3 0 -- "$REF"
check "no delays -> a single attempt" [ "$rc:$(ncalls)" = "3:1" ]
check "  error says 1 attempt" has "after 1 attempt:"
VERIFY_REF_DELAYS="10 soon" run 0 -- "$REF"
check "a non-numeric delay is a usage error" [ "$rc" -eq 2 ]
check "  before any check runs" [ "$(ncalls)" -eq 0 ]

echo "case 12: usage"
run 0 --
check "no ref -> exit 2" [ "$rc" -eq 2 ]
check "  and nothing checked" [ "$(ncalls)" -eq 0 ]
run 0 -- "$REF" extra
check "two refs -> exit 2" [ "$rc" -eq 2 ]

echo
echo "$pass passed, $failures failed"
[ "$failures" -eq 0 ]
