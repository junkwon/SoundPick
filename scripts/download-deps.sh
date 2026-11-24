#!/usr/bin/env bash
# Bundles yt-dlp and ffmpeg (plus every non-system dylib ffmpeg needs) into
# Sources/PullTube/Resources/Vendored so the app runs without Homebrew.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Sources/PullTube/Resources/Vendored"
LIB="$VENDOR/lib"
# The folder-style ("onedir") build. The single-file build unpacks itself on
# every launch, which costs about 5 seconds each time yt-dlp runs.
YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos.zip"
YTDLP_DIR="$VENDOR/yt-dlp-dist"

rm -rf "$VENDOR"
mkdir -p "$LIB"

# ---------------------------------------------------------------- yt-dlp
echo "==> Downloading yt-dlp (universal, folder build) from GitHub releases"
YTDLP_TMP="$(mktemp -d)"
curl -fL --retry 3 --progress-bar -o "$YTDLP_TMP/yt-dlp_macos.zip" "$YTDLP_URL"
mkdir -p "$YTDLP_DIR"
ditto -x -k "$YTDLP_TMP/yt-dlp_macos.zip" "$YTDLP_DIR"
rm -rf "$YTDLP_TMP"
chmod 755 "$YTDLP_DIR/yt-dlp_macos"
xattr -cr "$YTDLP_DIR" 2>/dev/null || true
echo "    yt-dlp $("$YTDLP_DIR/yt-dlp_macos" --version)"

# ---------------------------------------------------------------- deno
# yt-dlp needs a JavaScript runtime to solve YouTube's player challenges;
# without one, some formats (often the high-resolution ones) go missing.
# Deno ships per-architecture builds, so lipo them into one universal binary.
echo "==> Downloading deno (arm64 + x86_64) from GitHub releases"
DENO_TMP="$(mktemp -d)"
trap 'rm -rf "$DENO_TMP"' EXIT
for arch in aarch64 x86_64; do
  mkdir -p "$DENO_TMP/$arch"
  curl -fL --retry 3 --progress-bar -o "$DENO_TMP/$arch/deno.zip" \
    "https://github.com/denoland/deno/releases/latest/download/deno-$arch-apple-darwin.zip"
  ditto -x -k "$DENO_TMP/$arch/deno.zip" "$DENO_TMP/$arch"
done
lipo -create "$DENO_TMP/aarch64/deno" "$DENO_TMP/x86_64/deno" -output "$VENDOR/deno"
chmod 755 "$VENDOR/deno"
xattr -c "$VENDOR/deno" 2>/dev/null || true
codesign --force --sign - "$VENDOR/deno" 2>/dev/null
echo "    $("$VENDOR/deno" --version | head -1)"

# ---------------------------------------------------------------- ffmpeg
if ! command -v brew >/dev/null; then
  echo "error: Homebrew is required (brew install ffmpeg)" >&2; exit 1
fi
FFMPEG_SRC="$(brew --prefix ffmpeg)/bin/ffmpeg"
[ -x "$FFMPEG_SRC" ] || { echo "error: ffmpeg not installed (brew install ffmpeg)" >&2; exit 1; }
FFMPEG_SRC="$(realpath "$FFMPEG_SRC")"

echo "==> Bundling ffmpeg from $FFMPEG_SRC"
cp "$FFMPEG_SRC" "$VENDOR/ffmpeg"
chmod 755 "$VENDOR/ffmpeg"

is_system() {
  case "$1" in
    /usr/lib/*|/System/*) return 0 ;;
  esac
  return 1
}

# Resolve a load command reference to a real file on disk.
# $1 = reference, $2 = original (unbundled) path of the binary that references it
resolve_ref() {
  local ref="$1" owner="$2" owner_dir name rp candidate
  owner_dir="$(dirname "$owner")"
  name="$(basename "$ref")"
  case "$ref" in
    @loader_path/*)
      candidate="$owner_dir/${ref#@loader_path/}" ;;
    @rpath/*)
      candidate=""
      while read -r rp; do
        [ -z "$rp" ] && continue
        rp="${rp/@loader_path/$owner_dir}"
        if [ -e "$rp/${ref#@rpath/}" ]; then candidate="$rp/${ref#@rpath/}"; break; fi
      done < <(otool -l "$owner" | awk '/cmd LC_RPATH/{getline; getline; print $2}')
      if [ -z "$candidate" ]; then
        candidate="$(brew --prefix)/lib/$name"
      fi ;;
    *)
      candidate="$ref" ;;
  esac
  [ -e "$candidate" ] || { echo "error: cannot resolve $ref (needed by $owner)" >&2; return 1; }
  realpath "$candidate"
}

# Work queue of "bundled_path|original_path" pairs.
QUEUE=("$VENDOR/ffmpeg|$FFMPEG_SRC")
i=0
while [ $i -lt ${#QUEUE[@]} ]; do
  entry="${QUEUE[$i]}"; i=$((i + 1))
  bundled="${entry%%|*}"
  original="${entry#*|}"
  own_id="$(otool -D "$bundled" | tail -n +2 | head -1 || true)"

  if [[ "$bundled" == *.dylib ]]; then
    install_name_tool -id "@executable_path/lib/$(basename "$bundled")" "$bundled" 2>/dev/null
  fi

  while read -r ref; do
    [ -z "$ref" ] && continue
    [ "$ref" = "$own_id" ] && continue
    is_system "$ref" && continue
    [[ "$ref" == @executable_path/* ]] && continue
    name="$(basename "$ref")"
    if [ ! -e "$LIB/$name" ]; then
      src="$(resolve_ref "$ref" "$original")"
      cp "$src" "$LIB/$name"
      chmod 644 "$LIB/$name"; chmod u+w "$LIB/$name"
      QUEUE+=("$LIB/$name|$src")
      echo "    + $name"
    fi
    install_name_tool -change "$ref" "@executable_path/lib/$name" "$bundled" 2>/dev/null
  done < <(otool -L "$bundled" | tail -n +2 | awk '{print $1}')

  # Drop Homebrew rpaths; everything is now addressed via @executable_path.
  while read -r rp; do
    [ -z "$rp" ] && continue
    install_name_tool -delete_rpath "$rp" "$bundled" 2>/dev/null || true
  done < <(otool -l "$bundled" | awk '/cmd LC_RPATH/{getline; getline; print $2}')
done

# install_name_tool invalidates signatures; Apple Silicon kills unsigned code.
echo "==> Ad-hoc signing bundled binaries"
for f in "$LIB"/*.dylib "$VENDOR/ffmpeg"; do
  codesign --force --sign - "$f" 2>/dev/null
done

# ---------------------------------------------------------------- verify
echo "==> Verifying load paths"
bad="$(for f in "$VENDOR/ffmpeg" "$LIB"/*.dylib; do
  otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/|@executable_path/lib/)' | sed "s|^|$(basename "$f"): |"
done || true)"
if [ -n "$bad" ]; then
  echo "error: unbundled load paths remain:" >&2
  echo "$bad" >&2
  exit 1
fi

"$VENDOR/ffmpeg" -hide_banner -version | head -1
echo "==> Done: $(ls "$LIB" | wc -l | tr -d ' ') dylibs bundled into $LIB"
