#!/bin/sh
# patch-mediastream.sh <file> — pure-POSIX sh/awk reimplementation of patch-mediastream.py.
# Some devices don't have python3 at all (confirmed on a real device: postinst's python3 call
# just silently failed, leaving the framework genuinely unpatched) — this has no dependency
# beyond sh/grep/awk, which every webOS device has.
#
# Same logic as the .py version: find a UNIQUE `this.player.src=url;` (minified) or
# `this.player.src = url;` (pretty, tab-indented) occurrence and splice in the webm/mkv reroute.
# Idempotent (skips if already patched). The two source files are confirmed single-line-embedded
# substrings (minified bundles average ~500 bytes/line), so this uses awk index()/substr() to
# splice the match within its line rather than replacing the whole line.
set -e
FILE="$1"
[ -f "$FILE" ] || { echo "  ERROR: $FILE not found" >&2; exit 1; }

if grep -q "video/ogg" "$FILE" && grep -q "_msrc" "$FILE"; then
  echo "  already patched: $FILE"
  exit 0
fi

MIN_OLD='this.player.src=url;'
MIN_NEW=$(cat <<'EOF'
if(/\.(webm|mkv)(\?|#|$)/i.test(url)){this.player.removeAttribute("src");while(this.player.firstChild){this.player.removeChild(this.player.firstChild);}var _msrc=this.player.ownerDocument.createElement("source");_msrc.setAttribute("src",url);_msrc.setAttribute("type","video/ogg");this.player.appendChild(_msrc);this.player.load();}else{this.player.src=url;}
EOF
)

TAB="$(printf '\t')"
PRETTY_OLD="${TAB}${TAB}this.player.src = url;"
PRETTY_NEW=$(cat <<EOF
${TAB}${TAB}// WebKit's supportsType() rejects video/webm; hand it a <source> mime it accepts
${TAB}${TAB}// (video/ogg) so its engine loads, then the media server typefinds and decodes the
${TAB}${TAB}// real WebM. Only webm/mkv are rerouted; every other format keeps its direct src.
${TAB}${TAB}if (/\.(webm|mkv)(\?|#|\$)/i.test(url)) {
${TAB}${TAB}${TAB}this.player.removeAttribute('src');
${TAB}${TAB}${TAB}while (this.player.firstChild) { this.player.removeChild(this.player.firstChild); }
${TAB}${TAB}${TAB}var _msrc = this.player.ownerDocument.createElement('source');
${TAB}${TAB}${TAB}_msrc.setAttribute('src', url);
${TAB}${TAB}${TAB}_msrc.setAttribute('type', 'video/ogg');
${TAB}${TAB}${TAB}this.player.appendChild(_msrc);
${TAB}${TAB}${TAB}this.player.load();
${TAB}${TAB}} else {
${TAB}${TAB}${TAB}this.player.src = url;
${TAB}${TAB}}
EOF
)

# `|| true` matters: grep exits 1 on zero matches, and under `set -e` that would otherwise abort
# the script right here -- a zero count on either pattern is an expected, handled outcome, not a
# script-ending error.
min_count=$(grep -Fc "$MIN_OLD" "$FILE" || true)
pretty_count=$(grep -Fc "$PRETTY_OLD" "$FILE" || true)

if [ "$min_count" = "1" ]; then
  OLD="$MIN_OLD"; NEW="$MIN_NEW"
elif [ "$pretty_count" = "1" ]; then
  OLD="$PRETTY_OLD"; NEW="$PRETTY_NEW"
else
  echo "  ERROR: could not find a unique target in $FILE (min=$min_count pretty=$pretty_count)" >&2
  exit 1
fi

TMP="$FILE.patchtmp.$$"
# Pass OLD/NEW via ENVIRON, not -v: POSIX awk's -v assignment processes C-style backslash escapes
# in the value (confirmed on a real device: \. and \? were silently stripped to . and ? this way,
# corrupting the regex -- an unescaped ? in a JS regex is a quantifier, not a literal, and would
# likely throw a syntax error). Environment variable values aren't subject to that reinterpretation.
export PATCH_MEDIASTREAM_OLD="$OLD" PATCH_MEDIASTREAM_NEW="$NEW"
awk '
BEGIN { old = ENVIRON["PATCH_MEDIASTREAM_OLD"]; new = ENVIRON["PATCH_MEDIASTREAM_NEW"] }
{
  idx = index($0, old)
  if (idx > 0 && !done) {
    printf "%s%s%s\n", substr($0, 1, idx-1), new, substr($0, idx+length(old))
    done = 1
  } else {
    print
  }
}
' "$FILE" > "$TMP" && mv "$TMP" "$FILE"
unset PATCH_MEDIASTREAM_OLD PATCH_MEDIASTREAM_NEW

echo "  patched: $FILE"
exit 0
