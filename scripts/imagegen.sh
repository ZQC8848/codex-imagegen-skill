#!/usr/bin/env bash
# Generate (or edit) images with Codex CLI's built-in image generation, then collect the files.
#
# Usage:
#   imagegen.sh -p "prompt" [-o OUT_DIR] [-n NAME] [-c COUNT] [-s SIZE]
#               [-r REF.png]... [-t [-k green|magenta|blue|#RRGGBB]] [--trim] [--timeout SEC]
#
#   -p  prompt (English, already refined). Use "-" to read it from stdin.
#   -o  output directory (default: <git root>/assets/generated, else ~/Assets/generated)
#   -n  base file name (default: image-<timestamp>)
#   -c  number of images (default 1)
#   -s  size hint: square | landscape | portrait | WxH (default square)
#   -r  reference image for edits / style consistency (repeatable)
#   -t  transparent output: generate on a solid key-color background, then chroma-key it
#   -k  key color for -t (default green; pick magenta/blue when the subject is green)
#   --trim     crop transparent output to its opaque bounding box
#   --timeout  seconds before giving up (default 300)
#
# Prints one absolute path per generated file on stdout. Logs go to stderr.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

prompt="" out="" name="" count=1 size="square" transparent=0 key="green" trim=0 timeout=300
refs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -n) name="$2"; shift 2 ;;
    -c) count="$2"; shift 2 ;;
    -s) size="$2"; shift 2 ;;
    -r) refs+=("$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"); shift 2 ;;
    -t) transparent=1; shift ;;
    -k) key="$2"; shift 2 ;;
    --trim) trim=1; shift ;;
    --timeout) timeout="$2"; shift 2 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$prompt" == "-" ]] && prompt="$(cat)"
[[ -n "$prompt" ]] || { echo "error: -p prompt is required" >&2; exit 2; }

command -v codex >/dev/null || { echo "error: codex CLI not found (brew install codex)" >&2; exit 3; }
if ! codex login status >/dev/null 2>&1 || codex login status 2>&1 | grep -qi "not logged in"; then
  echo "error: codex is not logged in. Run: codex login" >&2; exit 3
fi
[[ $transparent -eq 0 ]] || command -v uv >/dev/null || { echo "error: uv not found (brew install uv)" >&2; exit 3; }

if [[ -z "$out" ]]; then
  if root=$(git rev-parse --show-toplevel 2>/dev/null); then out="$root/assets/generated"; else out="$HOME/Assets/generated"; fi
fi
mkdir -p "$out"; out="$(cd "$out" && pwd)"
name="${name:-image-$(date +%Y%m%d-%H%M%S)}"

case "$size" in
  square) size_txt="square 1:1 (1024x1024)" ;;
  landscape) size_txt="landscape 3:2 (1536x1024)" ;;
  portrait) size_txt="portrait 2:3 (1024x1536)" ;;
  *) size_txt="$size" ;;
esac

case "$key" in
  green) key_hex="#00FF00"; key_name="pure chroma green" ;;
  magenta) key_hex="#FF00FF"; key_name="pure magenta" ;;
  blue) key_hex="#0000FF"; key_name="pure blue" ;;
  \#*) key_hex="$key"; key_name="solid $key" ;;
  *) echo "error: bad -k $key" >&2; exit 2 ;;
esac

bg_rule=""
if [[ $transparent -eq 1 ]]; then
  bg_rule="
BACKGROUND (required, it will be chroma-keyed out later): a perfectly flat, uniform ${key_name} (${key_hex}) background filling the whole canvas.
No gradient, no texture, no vignette, no floor, no cast shadow or reflection on the background.
Do not use ${key_name} or similar hues anywhere in the subject. Keep the subject fully inside the frame with a clean, crisp silhouette and margin on all sides."
fi

ref_rule=""
[[ ${#refs[@]} -gt 0 ]] && ref_rule="
Use the attached image(s) as the reference: edit them or keep their style/character consistent, as the prompt describes."

work="$(mktemp -d "${TMPDIR:-/tmp}/codex-imagegen.XXXXXX")"
mkdir -p "$work/out"
marker="$work/.start"; touch "$marker"
codex_home="${CODEX_HOME:-$HOME/.codex}"

task="Use \$imagegen to generate exactly ${count} image(s). Do nothing else: no code, no extra files, no follow-up questions.
Size/aspect: ${size_txt}.
Save every final image as PNG into this directory: ${work}/out/
${ref_rule}${bg_rule}

PROMPT:
${prompt}"

img_args=()
for r in ${refs[@]+"${refs[@]}"}; do img_args+=(-i "$r"); done

echo "[imagegen] running codex (count=$count, size=$size, transparent=$transparent) ..." >&2
run_codex() {
  codex exec --skip-git-repo-check --ephemeral --enable image_generation \
    -s workspace-write -C "$work" -o "$work/last.txt" \
    ${img_args[@]+"${img_args[@]}"} - <<<"$task" >"$work/codex.log" 2>&1
}
run_codex & pid=$!
( sleep "$timeout"; kill "$pid" 2>/dev/null ) 2>/dev/null & watchdog=$!
wait "$pid" || rc=$?
kill "$watchdog" 2>/dev/null || true
wait "$watchdog" 2>/dev/null || true
if [[ "${rc:-0}" -ne 0 ]]; then
  echo "error: codex exited with ${rc} (log: $work/codex.log)" >&2
  tail -20 "$work/codex.log" >&2
  exit 4
fi

# Collect: files Codex saved where we asked, else whatever it wrote to its own image store.
files=()
while IFS= read -r f; do files+=("$f"); done < <(find "$work/out" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) | sort)
if [[ ${#files[@]} -eq 0 && -d "$codex_home/generated_images" ]]; then
  while IFS= read -r f; do files+=("$f"); done < <(find "$codex_home/generated_images" -type f -newer "$marker" \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) | sort)
fi
if [[ ${#files[@]} -eq 0 ]]; then
  echo "error: no image produced (log: $work/codex.log)" >&2
  tail -20 "$work/codex.log" >&2
  exit 5
fi

i=0
for f in "${files[@]}"; do
  i=$((i + 1))
  suffix=""; [[ ${#files[@]} -gt 1 ]] && suffix="-$(printf %02d $i)"
  ext="${f##*.}"; ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
  if [[ $transparent -eq 1 ]]; then
    raw="$out/${name}${suffix}-keyed-source.${ext}"
    dst="$out/${name}${suffix}.png"
    cp "$f" "$raw"
    trim_arg=(); [[ $trim -eq 1 ]] && trim_arg=(--trim)
    uv run --quiet "$SKILL_DIR/scripts/chroma_key.py" "$raw" "$dst" --key auto ${trim_arg[@]+"${trim_arg[@]}"} >&2
  else
    dst="$out/${name}${suffix}.${ext}"
    cp "$f" "$dst"
  fi
  echo "$dst"
done
rm -rf "$work"
