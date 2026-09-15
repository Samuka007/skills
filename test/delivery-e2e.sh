#!/usr/bin/env bash
# E2E regression for `delivery` (issue #10): package OUT/keep/ + OUT/manifest.json
# into ONE platform-chosen archive, having verified every recorded sha256 first
# and read the archive back after.
#
# Fixtures are synthetic: fabricated candidates.tsv + decisions.tsv rows pointing
# at tiny .jsonl files created under $WORK. The user's real sessions are never
# read, never written, never needed.
#
# Usage: test/delivery-e2e.sh [work-dir]      (default /tmp/delivery-e2e)
# Dependencies: bash, jq, awk, cmp, and the platform's own archiver — `tar` +
# `gzip` on POSIX, `unzip` on Windows. That asymmetry is the thing under test,
# not a precondition to skip on.
#
# Rung coverage, stated because a test that silently covers two of three rungs
# reads as covering all three. The command's writer ladder is Info-ZIP `zip` ->
# bsdtar -> `tar -czf`; see PACK-SPEC § 6.
#   - WSL / Linux      : `tar -czf`. Neither `zip` nor a bsdtar exists here, so
#                        the zip rungs cannot run and the forced-format block
#                        says so in its output instead of passing quietly.
#   - Windows Git Bash : `bsdtar`, via %SYSTEMROOT%\System32\tar.exe. This Git
#                        Bash has no Info-ZIP `zip`.
#   - Info-ZIP `zip`   : NOT exercised on either platform on this machine. It
#                        is covered only by the magic-byte check every rung
#                        passes through — which is why that check is asserted
#                        on its own, not folded into "an archive was produced".
# Set FORCE_ZIP_RUNG=1 to require the Info-ZIP rung (fails instead of skipping)
# on a machine that has it.
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
C="$REPO/skills/agent-session-batch-export/scripts/curate-sessions.sh"
WORK="${1:-/tmp/delivery-e2e}"

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
no()   { fail=$((fail + 1)); echo "  FAIL $1"; }
chk()  { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else no "$1: got '$2' want '$3'"; fi; }
has()  { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1: missing '$3'"; fi; }
hasnt(){ if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1: unexpected '$3'"; fi; }
non0() { if [[ "$2" -ne 0 ]]; then ok "$1 (rc=$2)"; else no "$1: expected non-zero, got $2"; fi; }

# Same rule the command uses, derived here so the test extracts with the tool
# that actually matches what was written. A test that guessed the format and
# extracted with the other platform's tool would pass while the artifact was
# useless to the partner.
arch_fmt() {
  case "${OSTYPE:-}" in msys*|cygwin*|win32) echo zip; return ;; esac
  [[ -n "${MSYSTEM:-}" ]] && { echo zip; return; }
  echo tar.gz
}
FMT="$(arch_fmt)"

# Mirrors the command's own writer ladder: Info-ZIP zip via PATH, or Windows'
# bsdtar (the only tar that writes real zips) via SYSTEMROOT.
have_zip_writer() {
  command -v zip >/dev/null 2>&1 && return 0
  command -v bsdtar >/dev/null 2>&1 && return 0
  [[ -n "${SYSTEMROOT:-}" ]] && command -v cygpath >/dev/null 2>&1 \
    && [[ -x "$(cygpath -u "$SYSTEMROOT" 2>/dev/null)/System32/tar.exe" ]] && return 0
  return 1
}

# ---------------------------------------------------------------- fixtures
# mkfix DIR N — N fabricated candidates under DIR/src, the first N marked keep
# in a 10-column decisions.tsv. Distinct byte content per session so a swapped
# or truncated member cannot pass the cmp.
mkfix() { # $1 = dir, $2 = keep count, $3 = total count
  local dir="$1" keepn="$2" total="$3" i
  rm -rf "$dir"; mkdir -p "$dir/src"
  printf 'agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file\n' > "$dir/candidates.tsv"
  for i in $(seq 1 "$total"); do
    printf '{"type":"user","message":{"role":"user","content":"synthetic session %s"}}\n{"type":"assistant","message":{"content":[{"type":"text","text":"reply %s"}]}}\n' \
      "$i" "$i" > "$dir/src/s$i.jsonl"
    printf 'claude_code\t/home/demo/ws-%s\t2026-01-0%sT00:00:00Z\t%s\t2\tsynthetic session %s\t%s/src/s%s.jsonl\n' \
      "$i" "$i" "$(wc -c < "$dir/src/s$i.jsonl" | tr -d ' ')" "$i" "$dir" "$i" >> "$dir/candidates.tsv"
  done
  awk -F'\t' -v n="$keepn" 'BEGIN{OFS="\t"; c=0}
    NR==1 { print "decision","reason","suggested","agent","cwd","mtime","size_bytes","n_lines","first_prompt","session_file"; next }
    { c++; print (c <= n ? "keep" : "drop"), "delivery e2e", "", $1, $2, $3, $4, $5, $6, $7 }
  ' "$dir/candidates.tsv" > "$dir/decisions.tsv"
}

# ------------------------------------------------------------- assertions
# names ARCHIVE — every member, sorted, `keep/` dropped (whether a writer
# records the directory entry is a writer detail, not a property of delivery).
names() { # $1 = archive
  local arc="$1"
  [[ -f "$arc" ]] || return 0
  case "$arc" in
    *.zip) zip_names "$arc" ;;
    *)     tar -tzf "$arc" 2>/dev/null ;;
  esac | tr -d '\r' | awk 'NF && $0 !~ /\/$/' | sort
}
members() { names "$(default_archive "$1")"; }

# Listing a zip needs whichever reader this platform has: Git Bash ships unzip,
# a bare Linux box has neither unzip nor zipinfo. Extraction below uses the
# same ladder for the same reason. python3 is the universal backstop.
zip_names() { # $1 = archive
  local arc="$1"
  if command -v unzip   >/dev/null 2>&1; then unzip -Z1 "$arc" 2>/dev/null; return; fi
  if command -v zipinfo >/dev/null 2>&1; then zipinfo -1 "$arc" 2>/dev/null; return; fi
  python3 -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    print("\n".join(z.namelist()))' "$arc"
}
zip_extract() { # $1 = archive, $2 = dest
  local arc="$1" dest="$2"
  if command -v unzip >/dev/null 2>&1; then unzip -q -o "$arc" -d "$dest"; return; fi
  python3 -c 'import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$arc" "$dest"
}
# The kept filename is <agent>--<slug>--<basename>, where the slug is the cwd
# with `/` turned into `--`. Derive the names from the manifest under test
# rather than hardcoding the mangling: the point of the assertion is the member
# SET, not the slug spelling.
keep_names() { # $1 = dir -> expected archive member paths, sorted
  # jq -r emits CRLF on Windows Git Bash; a stray CR would make the expected
  # names compare unequal to the archive's, which is a test bug, not a product
  # bug. Strip it at the boundary, like every other jq read in this repo.
  { jq -r '.[].kept_as | sub(".*/"; "keep/")' "$1/manifest.json" | tr -d '\r'
    printf '%s\n' manifest.json
  } | sort
}
default_archive() { # $1 = dir -> the dated default name the command chose
  local hit
  # set -f is off but an unmatched glob still yields the pattern literally, so
  # each candidate is tested with -f; the loop simply finds nothing when the
  # command (correctly) wrote no archive at all.
  for hit in "$1"/*.zip "$1"/*.tar.gz; do
    [[ -f "$hit" ]] && { printf '%s' "$hit"; return 0; }
  done
  return 0
}
# extract ARCHIVE DEST — platform tool, matching the format under test
extract() { # $1 = archive, $2 = dest dir
  rm -rf "$2"; mkdir -p "$2"
  case "$1" in
    *.zip) zip_extract "$1" "$2" ;;
    *)     tar -xzf "$1" -C "$2" ;;
  esac
}
# cmp_bad TAG DEST — extracted members that are not byte-identical to their
# originals. Reads the manifest THAT CAME OUT OF THE ARCHIVE, not the one on
# disk: the delivered copy is what the buyer checks the batch against, so that
# is the copy the test must use. Prints the mismatch count, or a sentinel when
# nothing could be compared (a vacuous pass must not look like a clean one).
cmp_bad() { # $1 = tag (scratch name), $2 = dest
  local tag="$1" dest="$2" bad=0 n=0 s ka base
  local man="$WORK/.cmp-$tag.json" pairs="$WORK/.cmp-$tag.tsv"
  cp -f "$dest/manifest.json" "$man" || { echo "no-manifest-in-archive"; return; }
  jq -r '.[] | "\(.source)\t\(.kept_as)"' "$man" > "$pairs" 2>/dev/null \
    || { echo "unreadable-manifest"; return; }
  while IFS=$'\t' read -r s ka; do
    s="${s%$'\r'}"; ka="${ka%$'\r'}"
    n=$((n + 1))
    base="$(basename "$ka")"
    cmp -s "$s" "$dest/keep/$base" || { bad=$((bad + 1)); echo "  MISMATCH $base" >&2; }
  done < "$pairs"
  [[ "$n" -gt 0 ]] || { echo "no-pairs"; return; }
  echo "$bad"
}

echo "delivery e2e — work dir: $WORK   platform archive: $FMT"
echo "script: $(basename "$C")"
rm -rf "$WORK"; mkdir -p "$WORK"

# ------------------------------------------------------- A: the happy path
echo
echo "== A: 2 sessions -> finalize -> delivery =="
A="$WORK/a"; mkfix "$A" 2 3
bash "$C" finalize -o "$A" >/dev/null 2>&1
chk "manifest entries" "$(jq 'length' "$A/manifest.json")" "2"
aout="$(bash "$C" delivery -o "$A" < /dev/null 2>&1)"; arc=$?
chk "exit status" "$arc" "0"
has "says which format it picked" "$aout" "format:  $FMT"
has "says it verified the manifest" "$aout" "$FMT"
has "reports the session count" "$aout" "2 session(s) + manifest.json"
has "prints the archive path" "$aout" "$A/"
# The count of included files is part of the printed result.
has "prints the file count" "$aout" "files:   3 (2 sessions + manifest.json)"

AARC="$(default_archive "$A")"
chk "archive exists with the platform suffix" "$(basename "$AARC" | sed 's/.*\.//')" "${FMT##*.}"
chk "archive is non-empty" "$([[ -s "$AARC" ]] && echo y)" "y"

# The writer must be NAMED, and the name must agree with the bytes on disk.
# "some tool ran" is not the claim; "the tool that ran produces this format" is,
# and the two are checked separately so a mismatch says which half broke.
WRITER_LINE="$(printf '%s\n' "$aout" | sed -n 's/^  writer:  //p')"
if [[ -n "$WRITER_LINE" ]]; then ok "names the tool that wrote it ($WRITER_LINE)"
else no "names the tool that wrote it: no 'writer:' line"; fi
case "$WRITER_LINE" in
  *Info-ZIP*) claimed=zip ;;
  *bsdtar*)   claimed=zip ;;
  *"tar -czf"*) claimed=gzip ;;
  *) claimed=unknown ;;
esac
case "$claimed:$FMT" in
  zip:zip|gzip:tar.gz) ok "writer name agrees with the chosen format" ;;
  *) no "writer '$WRITER_LINE' does not produce $FMT" ;;
esac
# On a machine that HAS Info-ZIP zip, this turns the unexercised rung into an
# assertion instead of a comment: run the suite with FORCE_ZIP_RUNG=1 there and
# a fallback to bsdtar/tar is a failure rather than a silent substitution.
if [[ -n "${FORCE_ZIP_RUNG:-}" ]]; then
  case "$WRITER_LINE" in
    *Info-ZIP*) ok "FORCE_ZIP_RUNG: the Info-ZIP rung was used" ;;
    *) no "FORCE_ZIP_RUNG set but the writer was '$WRITER_LINE'" ;;
  esac
fi
# And the FILE agrees too. This is the check that would have caught GNU tar's
# `-a -c -f x.zip`: exit 0, correct-looking name, magic 6b 65.
chk "magic bytes match the writer's format" \
  "$(od -An -tx1 -N2 "$AARC" | tr -d ' \n')" \
  "$([[ "$FMT" == zip ]] && echo 504b || echo 1f8b)"

# The kill test for that failure class, run on any platform: a `zip` on PATH
# that exits 0 and writes a POSIX tar must be REFUSED, not shipped. This is the
# one check that distinguishes "the writer ran" from "the right format came
# out", so it is worth a stub rather than trusting the host's real tools.
# Its own directory, never the one section G prepends: on Windows the fake
# `zip` would otherwise be the writer G's run picks up and G would be asserting
# about the stub instead of about python3.
mkdir -p "$WORK/bin-lie"
cat > "$WORK/bin-lie/zip" <<'FAKEZIP'
#!/usr/bin/env bash
# Mimics GNU tar's `-a -c -f x.zip`: takes zip's argv shape, exits 0, writes a
# POSIX tar. Exactly what the real GNU tar does on Git Bash.
out=""; members=()
for a in "$@"; do
  case "$a" in -*) continue ;; esac
  if [[ -z "$out" ]]; then out="$a"; else members+=("$a"); fi
done
tar -cf "$out" "${members[@]}"
exit 0
FAKEZIP
chmod +x "$WORK/bin-lie/zip"
lies="$WORK/lies.zip"
PATH="$WORK/bin-lie:$PATH" bash "$C" delivery -o "$A" --out "$lies" >"$WORK/lies.out" 2>&1; lrc=$?
non0 "a writer that lies about the format is refused" "$lrc"
has  "says the writer produced a non-zip file" "$(cat "$WORK/lies.out")" "non-zip"
chk  "no lying archive left at the target" "$([[ -e "$lies" ]] && echo present || echo absent)" "absent"

# Exactly the corpus member set: keep/ + manifest.json, nothing else, at root.
chk "member set" "$(members "$A" | tr '\n' ' ')" "$(keep_names "$A" | tr '\n' ' ')"
chk "member set is keep/ + manifest only" "$(members "$A" | grep -vc '^keep/' )" "1"
chk "manifest at the archive root" "$(members "$A" | grep -c '^manifest\.json$')" "1"
chk "no prefixed/leading-dot members" "$(members "$A" | grep -c '^\.\./\|^/')" "0"

extract "$AARC" "$WORK/x-a"
chk "extracted copies cmp-clean" "$(cmp_bad a "$WORK/x-a")" "0"
chk "extracted member count" "$(find "$WORK/x-a/keep" -maxdepth 1 -type f | wc -l | tr -d ' ')" "2"

# ------------------------------------------------- B: re-run, same OUTDIR
echo
echo "== B: second run over the same OUTDIR — idempotent, no stale members =="
bout="$(bash "$C" delivery -o "$A" < /dev/null 2>&1)"; brc=$?
chk "exit status" "$brc" "0"
chk "same archive path (same day)" "$(default_archive "$A")" "$AARC"
chk "still exactly 2 members" "$(members "$A" | wc -l | tr -d ' ')" "3"
chk "re-run copies cmp-clean" "$(cmp_bad a "$WORK/x-a")" "0"

# Then shrink the corpus and re-run: the earlier members must NOT survive.
# This is the append trap (Info-ZIP adds to an existing archive) and the
# stale-member bug in one check.
mkfix "$A" 1 3
bash "$C" finalize -o "$A" >/dev/null 2>&1
bash "$C" delivery -o "$A" < /dev/null >/dev/null 2>&1
chk "shrunk corpus -> 1 session member" "$(members "$A" | wc -l | tr -d ' ')" "2"
chk "no stale s2 member" "$(members "$A" | grep -c 's2\.jsonl')" "0"
extract "$AARC" "$WORK/x-b"
chk "shrunk archive copies cmp-clean" "$(cmp_bad b "$WORK/x-b")" "0"

# --------------------------------------------------- C: --out FILE override
echo
echo "== C: --out FILE names the archive explicitly =="
COUT="$WORK/named.$FMT"
cout="$(bash "$C" delivery -o "$A" --out "$COUT" < /dev/null 2>&1)"; crc=$?
chk "exit status" "$crc" "0"
chk "--out path used" "$([[ -s "$COUT" ]] && echo y)" "y"
has "prints the overridden path" "$cout" "$COUT"
extract "$COUT" "$WORK/x-c"
chk "--out archive copies cmp-clean" "$(cmp_bad c "$WORK/x-c")" "0"
# The other platform's format, on this one. Two things are being pinned: the
# override actually switches the writer, and the file's MAGIC BYTES match its
# extension — a `.zip` that is really a tar (or vice versa) is the one failure
# mode that would reach the partner undetected, since both unpack "fine" with
# the tool the name implies. Verified from the bytes, never from the writer.
if [[ "$FMT" == "zip" ]]; then
  # Windows: force the POSIX format and check it is genuinely a gzip stream.
  tout="$WORK/forced.tar.gz"
  trc=0; bash "$C" delivery -o "$A" --out "$tout" < /dev/null >/dev/null 2>&1 || trc=$?
  chk "forced .tar.gz built" "$trc" "0"
  chk "forced .tar.gz is really gzip" "$(od -An -tx1 -N2 "$tout" | tr -d ' \n')" "1f8b"
  chk "forced .tar.gz members" "$(names "$tout" | tr '\n' ' ')" "$(members "$A" | tr '\n' ' ')"
  extract "$tout" "$WORK/x-ctz"
  chk "forced .tar.gz copies cmp-clean" "$(cmp_bad ctz "$WORK/x-ctz")" "0"
elif have_zip_writer; then
  zout="$WORK/forced.zip"
  zrc=0; bash "$C" delivery -o "$A" --out "$zout" < /dev/null >/dev/null 2>&1 || zrc=$?
  chk "explicit .zip built" "$zrc" "0"
  chk "explicit .zip is really a zip" "$(od -An -tx1 -N2 "$zout" | tr -d ' \n')" "504b"
  chk "explicit .zip members listed" "$(names "$zout" | tr '\n' ' ')" "$(members "$A" | tr '\n' ' ')"
  extract "$zout" "$WORK/x-cz"
  chk "explicit .zip copies cmp-clean" "$(cmp_bad cz "$WORK/x-cz")" "0"
elif [[ "$FMT" != "zip" ]]; then
  echo "  skip: Info-ZIP and bsdtar rungs absent here — only the tar rung can run"
fi

# An --out with no recognised archive suffix changes the path, not the format:
# the platform rule still decides, since a name no tool infers from cannot lie
# about its contents.
uout="$WORK/named.artifact"
urc=0; bash "$C" delivery -o "$A" --out "$uout" < /dev/null >/dev/null 2>&1 || urc=$?
chk "unknown suffix still builds" "$urc" "0"
case "$FMT" in
  zip) chk "unknown suffix kept the platform format" "$(od -An -tx1 -N2 "$uout" | tr -d ' \n')" "504b" ;;
  *)   chk "unknown suffix kept the platform format" "$(od -An -tx1 -N2 "$uout" | tr -d ' \n')" "1f8b" ;;
esac

# ------------------------------------------------- G: hostile python3
# A `python3` that exists on PATH but always fails is not hypothetical: on
# Windows that is the Microsoft Store app-execution alias, which prints
# "Python was not found" and exits 49. A presence check passes for it, so a
# reader ladder that trusted `command -v python3` would report a zip as having
# no members and refuse a perfectly good archive. A stub that mimics it is put
# first on PATH here, and the command must still succeed on the real tools.
echo
echo "== G: a failing python3 on PATH must not break delivery =="
mkdir -p "$WORK/bin"
cat > "$WORK/bin/python3" <<'PYSTUB'
#!/usr/bin/env bash
echo "Python was not found; run without arguments to install from the Microsoft Store." >&2
exit 49
PYSTUB
chmod +x "$WORK/bin/python3"
PATH="$WORK/bin:$PATH" bash "$C" delivery -o "$A" --out "$WORK/stubbed.$FMT" < /dev/null >/dev/null 2>&1
grc=$?
chk "succeeds with a failing python3 on PATH" "$grc" "0"
extract "$WORK/stubbed.$FMT" "$WORK/x-g"
chk "stubbed archive members" "$(names "$WORK/stubbed.$FMT" | tr '\n' ' ')" "$(members "$A" | tr '\n' ' ')"
chk "stubbed archive copies cmp-clean" "$(cmp_bad g "$WORK/x-g")" "0"

# ----------------------------------------------------------- D: refusals
echo
echo "== D: refusal paths (non-zero, naming what is missing) =="
D="$WORK/d"; mkfix "$D" 2 3
bash "$C" finalize -o "$D" >/dev/null 2>&1

# keep/ deleted
rm -rf "$D/keep"
d1="$(bash "$C" delivery -o "$D" < /dev/null 2>&1)"; d1rc=$?
non0 "missing keep/ refused" "$d1rc"
has  "names keep/" "$d1" "keep/"
has  "says why it refuses" "$d1" "nothing to package"
chk  "no archive written" "$(default_archive "$D")" ""

# manifest deleted
bash "$C" finalize -o "$D" >/dev/null 2>&1
rm -f "$D/manifest.json"
d2="$(bash "$C" delivery -o "$D" < /dev/null 2>&1)"; d2rc=$?
non0 "missing manifest refused" "$d2rc"
has  "names manifest.json" "$d2" "manifest.json"
chk  "no archive written" "$(default_archive "$D")" ""

# keep/ present but empty
bash "$C" finalize -o "$D" >/dev/null 2>&1
find "$D/keep" -maxdepth 1 -type f -delete
d3="$(bash "$C" delivery -o "$D" < /dev/null 2>&1)"; d3rc=$?
non0 "empty keep/ refused" "$d3rc"
has  "names keep/ as empty" "$d3" "contains no files"
chk  "no archive written" "$(default_archive "$D")" ""

# keep/ populated but the manifest emptied: `finalize` never produces this, but
# a hand-edited manifest does, and it is the case where a naive implementation
# would pack the whole corpus against a manifest listing nothing.
E="$WORK/e"; mkfix "$E" 2 3
bash "$C" finalize -o "$E" >/dev/null 2>&1
printf '[]\n' > "$E/manifest.json"
d4="$(bash "$C" delivery -o "$E" < /dev/null 2>&1)"; d4rc=$?
non0 "empty manifest refused" "$d4rc"
has  "says the manifest lists nothing" "$d4" "lists 0 sessions"
chk  "no archive written" "$(default_archive "$E")" ""

# A file added to keep/ that the manifest does not know about would ship as a
# corpus member nobody can check, so it is refused the same way.
H="$WORK/h"; mkfix "$H" 2 3
bash "$C" finalize -o "$H" >/dev/null 2>&1
printf '{"type":"user","message":{"role":"user","content":"stray"}}\n' > "$H/keep/claude_code--stray--nobody.jsonl"
d5="$(bash "$C" delivery -o "$H" < /dev/null 2>&1)"; d5rc=$?
non0 "unlisted keep/ file refused" "$d5rc"
has  "names the unlisted file" "$d5" "not in the manifest"
chk  "no archive written" "$(default_archive "$H")" ""

# -------------------------------------------------- E: tampered corpus
echo
echo "== E: a corpus that no longer matches the manifest is refused =="
F="$WORK/f"; mkfix "$F" 2 3
bash "$C" finalize -o "$F" >/dev/null 2>&1
# Flip one recorded copy without touching the manifest: the sha256 must catch it.
tgt="$(jq -r '.[0].kept_as' "$F/manifest.json")"
printf '\n{"tampered":true}\n' >> "$tgt"
fout="$(bash "$C" delivery -o "$F" < /dev/null 2>&1)"; frc=$?
non0 "sha256 mismatch refused" "$frc"
has  "names the file whose hash moved" "$fout" "sha256 mismatch"
chk  "no archive written" "$(default_archive "$F")" ""
# And a file dropped from keep/ is caught too.
rm -f "$tgt"
f2out="$(bash "$C" delivery -o "$F" < /dev/null 2>&1)"; f2rc=$?
non0 "missing member refused" "$f2rc"
has  "names the missing copy" "$f2out" "missing from keep/"

# ---------------------------------------------- F: package is not delivery
echo
echo "== F: package keeps its own job (open-review.sh) =="
G="$WORK/g"; mkfix "$G" 2 3
bash "$C" finalize -o "$G" >/dev/null 2>&1
bash "$C" package -o "$G" >/dev/null 2>&1
chk "package still writes open-review.sh" "$([[ -x "$G/open-review.sh" ]] && echo y)" "y"
gout="$(bash "$C" delivery -o "$G" < /dev/null 2>&1)"
hasnt "delivery does not write a launcher" "$gout" "open-review.sh"
chk "delivery wrote no launcher of its own" "$([[ -f "$G/open-review.sh" ]] && echo y)" "y"

printf '\n=====================\n'
if [[ $fail -eq 0 ]]; then
  echo "RESULT: ALL CHECKS PASSED ($pass)"
else
  echo "RESULT: $fail FAILURE(S) ($pass passed)"
fi
printf '=====================\n'
exit "$fail"
