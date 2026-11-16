#!/usr/bin/env bash
# Tests tool/make_icon_pngs.py, each case on a copy of the icon's files in a
# folder of its own. Needs Python 3 with Pillow, like the tool.
#
#   tool/test/make_icon_pngs_test.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
python3 -c 'import PIL' 2>/dev/null || {
  echo "tool/test/make_icon_pngs_test.sh needs Python 3 with Pillow (on Debian or Ubuntu: python3-pil)." >&2
  exit 1
}
readonly RES=android/app/src/main/res
readonly FOREGROUND=$RES/drawable/ic_launcher_foreground.xml
readonly BACKGROUND=$RES/values/ic_launcher_background.xml
# The PNGs the tool writes, from its own list.
mapfile -t PNGS < <(python3 - <<'EOF'
import importlib.util
spec = importlib.util.spec_from_file_location('make_icon_pngs', 'tool/make_icon_pngs.py')
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
for path, _ in tool.PNGS:
    print(path.relative_to(tool.ROOT))
EOF
)
readonly PNGS
[[ "${#PNGS[@]}" == 6 && "${PNGS[0]}" == "$RES/mipmap-mdpi/ic_launcher.png" &&
  "${PNGS[5]}" == fastlane/metadata/android/en-US/images/icon.png ]] || {
  echo "unexpected list of PNGs from tool/make_icon_pngs.py: ${PNGS[*]}" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Without symlinks in it: the tool names files by their real paths.
tmp="$(realpath -e "$tmp")"

failures=0
case_number=0

# A fresh copy of the tool and the files it reads and writes, in $tmp/<n>;
# prints its path.
copy() {
  local dir="$tmp/$case_number"
  mkdir -p "$dir/tool"
  cp tool/make_icon_pngs.py "$dir/tool/"
  local file
  for file in "$FOREGROUND" "$BACKGROUND" "${PNGS[@]}"; do
    mkdir -p "$dir/$(dirname "$file")"
    cp "$file" "$dir/$file"
  done
  echo "$dir"
}

# Replaces OLD with NEW in FILE (once; fails the test if it isn't there).
replace() {
  python3 - "$1" "$2" "$3" <<'EOF'
import sys
path, old, new = sys.argv[1:]
text = open(path).read()
assert text.count(old) == 1, f'{old!r} in {path}'
open(path, 'w').write(text.replace(old, new))
EOF
}

# The SHA-256 of each PNG in DIR, a line each ("missing" for one that isn't
# there).
png_hashes() {
  local png
  for png in "${PNGS[@]}"; do
    if [[ -e "$1/$png" ]]; then sha256sum "$1/$png"; else echo "missing $png"; fi
  done
}

# expect NAME STATUS OUTPUT PNGS -- ARGS...: runs the tool in the case's copy
# with ARGS and checks its exit status, that its output (stdout and stderr)
# contains each line of OUTPUT, and whether its PNGs are still the ones it
# had before (PNGS "same") or were changed ("changed").
expect() {
  local name="$1" status="$2" output="$3" pngs="$4"
  shift 5
  local before actual_status=0 out
  before="$(png_hashes "$dir")"
  out="$(python3 "$dir/tool/make_icon_pngs.py" "$@" 2>&1)" || actual_status=$?
  local problems=()
  [[ "$actual_status" == "$status" ]] || problems+=("exit status $actual_status, not $status")
  local line
  while IFS= read -r line; do
    [[ -z "$line" || "$out" == *"$line"* ]] || problems+=("no \"$line\" in the output")
  done <<<"$output"
  if [[ "$pngs" == same && "$(png_hashes "$dir")" != "$before" ]]; then
    problems+=("the PNGs changed")
  elif [[ "$pngs" == changed && "$(png_hashes "$dir")" == "$before" ]]; then
    problems+=("the PNGs didn't change")
  fi
  if ((${#problems[@]})); then
    failures=$((failures + 1))
    echo "FAIL $case_number: $name" >&2
    printf '  %s\n' "${problems[@]}" >&2
    while IFS= read -r line; do echo "  | $line"; done <<<"$out" >&2
  else
    echo "ok $case_number: $name"
  fi
}

# Starts the next case with a fresh copy in $dir.
next() {
  case_number=$((case_number + 1))
  dir="$(copy)"
}

next
expect "--check passes on the repository's PNGs" 0 "The icon PNGs match the vector icon." same -- --check

next
expect "writing keeps PNGs that already show the picture" 0 \
  "Kept $RES/mipmap-mdpi/ic_launcher.png (the same picture)
Kept fastlane/metadata/android/en-US/images/icon.png (the same picture)" same --

next
python3 - "$dir/${PNGS[1]}" <<'EOF'
import sys
from PIL import Image
path = sys.argv[1]
image = Image.open(path).convert('RGBA')
r, g, b, a = image.getpixel((36, 36))
image.putpixel((36, 36), (r, g, b ^ 1, a))
image.save(path)
EOF
expect "--check names a PNG one pixel off" 1 \
  "The icon PNGs differ from the vector icon (run tool/make_icon_pngs.py):
  $RES/mipmap-hdpi/ic_launcher.png: differs by up to 1 in a colour channel" same -- --check
expect "...and writing puts it right" 0 "Wrote $RES/mipmap-hdpi/ic_launcher.png (72 x 72)
Kept $RES/mipmap-mdpi/ic_launcher.png (the same picture)" changed --
expect "...after which --check passes" 0 "The icon PNGs match the vector icon." same -- --check

next
rm "$dir/${PNGS[5]}"
expect "--check names a missing PNG" 1 "fastlane/metadata/android/en-US/images/icon.png: missing" same -- --check

next
python3 -c 'import sys; from PIL import Image; Image.open(sys.argv[1]).resize((50, 50)).save(sys.argv[1])' "$dir/${PNGS[0]}"
expect "--check names a PNG of another size" 1 "$RES/mipmap-mdpi/ic_launcher.png: 50 x 50, not 48 x 48" same -- --check

next
echo "<<<<<<< HEAD" >"$dir/${PNGS[2]}"
rm "$dir/${PNGS[4]}"
expect "--check names a file that isn't a PNG, and goes on to the others" 1 \
  "$RES/mipmap-xhdpi/ic_launcher.png: not a PNG file
$RES/mipmap-xxxhdpi/ic_launcher.png: missing" same -- --check

next
# A whole PNG whose header says 60000 x 60000: Pillow refuses to open it.
python3 - "$dir/${PNGS[2]}" <<'EOF'
import sys, zlib
path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
data[16:24] = (60000).to_bytes(4, 'big') * 2
data[29:33] = zlib.crc32(bytes(data[12:29])).to_bytes(4, 'big')
open(path, 'wb').write(data)
EOF
expect "--check names a PNG Pillow can't open, and goes on to the others" 1 \
  "$RES/mipmap-xhdpi/ic_launcher.png: can't be read" same -- --check
expect "...and writing writes it again" 0 "Wrote $RES/mipmap-xhdpi/ic_launcher.png (96 x 96)
Kept $RES/mipmap-xxhdpi/ic_launcher.png (the same picture)" changed --

# A PNG that shows the right picture but isn't written as the tool writes
# it: named by --check, and written again. CHANGE is Python that changes
# the file sys.argv[1].
rewritten() {
  local name="$1" problem="$2" change="$3"
  next
  python3 -c "$change" "$dir/${PNGS[0]}"
  expect "--check names a PNG $name" 1 "$RES/mipmap-mdpi/ic_launcher.png: $problem" same -- --check
  expect "...and writing writes it again" 0 "Wrote $RES/mipmap-mdpi/ic_launcher.png (48 x 48)" changed --
  expect "...after which --check passes" 0 "The icon PNGs match the vector icon." same -- --check
}
rewritten "with a palette" "not 8-bit RGBA without interlacing" '
import sys
from PIL import Image
path = sys.argv[1]
Image.open(path).quantize(colors=256, method=Image.Quantize.FASTOCTREE).save(path)'
rewritten "with metadata" "has more than the image: pHYs, tEXt" '
import sys
from PIL import Image, PngImagePlugin
path = sys.argv[1]
info = PngImagePlugin.PngInfo()
info.add_text("Author", "someone")
Image.open(path).save(path, pnginfo=info, dpi=(72, 72))'
rewritten "with a damaged chunk" "chunk IDAT is damaged" '
import sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
data[data.index(b"IDAT") + 4] ^= 1
open(path, "wb").write(data)'
rewritten "with bytes after its end" "not one whole PNG image" '
import sys
open(sys.argv[1], "ab").write(b"junk")'

next
replace "$dir/$FOREGROUND" '#FFF2A33A' '#FFF2A33B'
expect "--check sees a colour changed in the foreground" 1 \
  "$RES/mipmap-xxxhdpi/ic_launcher.png: differs" same -- --check
expect "...and writing draws all the PNGs again" 0 "Wrote $RES/mipmap-mdpi/ic_launcher.png (48 x 48)
Wrote fastlane/metadata/android/en-US/images/icon.png (512 x 512)" changed --

next
replace "$dir/$BACKGROUND" '#FF36618E' '#FF36618F'
expect "--check sees the background colour changed" 1 "differs" same -- --check

# What the tool can't draw stops it, and it writes nothing.
cant_draw() {
  local name="$1" old="$2" new="$3" message="$4"
  next
  replace "$dir/$FOREGROUND" "$old" "$new"
  expect "$name" 1 "Can't draw the icon: $dir/$FOREGROUND: $message" same --
}
cant_draw "a relative path command" 'M75,41.5 C79,41.1' 'M75,41.5 c4,-0.4' \
  "path command 'c' (only absolute M, L, C, Z)"
cant_draw "a path command it doesn't draw" 'M75,41.5 C79,41.1 82.4,42.2 84.2,44.5' \
  'M75,41.5 Q79,41.1 84.2,44.5' "path command 'Q'"
cant_draw "a stroke" '<path
        android:fillColor="#FFF2A33A"' '<path
        android:strokeWidth="1"
        android:fillColor="#FFF2A33A"' "<path> attribute android:strokeWidth"
cant_draw "a group that moves what is in it" '    <!-- The bill, under the head. -->' \
  '    <group android:translateX="1" />' "<group> attribute android:translateX"
cant_draw "a path that crosses itself" \
  'M75,41.5 C79,41.1 82.4,42.2 84.2,44.5 C82,46.1 78,46.5 74.4,45.7 Z' \
  'M54,36 L60,54 L44,43 L64,43 L48,54 Z' "a subpath crosses or touches itself"
cant_draw "a path with no area" \
  'M75,41.5 C79,41.1 82.4,42.2 84.2,44.5 C82,46.1 78,46.5 74.4,45.7 Z' \
  'M70,40 L80,40 Z' "a subpath with no area"
cant_draw "a path without a fill colour" '<path
        android:fillColor="#FFF2A33A"
' '<path
' "<path> without android:fillColor"
cant_draw "a fill given by an element (a gradient)" \
  ' 74.4,45.7 Z" />' ' 74.4,45.7 Z"><gradient /></path>' "<path> with <gradient> in it"
cant_draw "a colour from a resource" '#FFF2A33A' '@color/ic_launcher_background' \
  "colour '@color/ic_launcher_background'"
cant_draw "a vector of another size" 'android:viewportWidth="108"' 'android:viewportWidth="24"' \
  "viewportWidth is not 108"

next
replace "$dir/$FOREGROUND" '</vector>' ''
expect "a foreground that isn't whole XML stops it" 1 "Can't draw the icon:" same --

next
expect "an unknown argument shows how to use it" 1 "tool/make_icon_pngs.py --check" same -- --chek

if ((failures)); then
  echo "$failures of $case_number cases failed" >&2
  exit 1
fi
echo "All $case_number cases passed"
