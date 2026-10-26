#!/bin/bash
set -e

# Analyzes a source video for the video-editor skill: container/stream info,
# silence map, scene changes, and integrated loudness, as one JSON document.
#
# Usage: skills/video-editor/scripts/analyze.sh <input> [noise_db] [min_silence_s] [scene_threshold]
#   noise_db         silence floor in dB (default -35)
#   min_silence_s    shortest pause reported (default 0.4)
#   scene_threshold  0-1 scene-change sensitivity (default 0.3)

INPUT="$1"
NOISE_DB="${2:--35}"
MIN_SILENCE="${3:-0.4}"
SCENE_THRESHOLD="${4:-0.3}"

if [ -z "$INPUT" ] || [ ! -f "$INPUT" ]; then
  echo "Usage: analyze.sh <input> [noise_db] [min_silence_s] [scene_threshold]" >&2
  exit 2
fi

for tool in ffmpeg ffprobe jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 2
  fi
done

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Probing streams..." >&2
ffprobe -v error -show_format -show_streams -of json "$INPUT" > "$TMP_DIR/probe.json"

HAS_AUDIO=$(jq '[.streams[] | select(.codec_type == "audio")] | length > 0' "$TMP_DIR/probe.json")
HAS_VIDEO=$(jq '[.streams[] | select(.codec_type == "video")] | length > 0' "$TMP_DIR/probe.json")

echo '[]' > "$TMP_DIR/silences.json"
echo 'null' > "$TMP_DIR/loudness.json"
if [ "$HAS_AUDIO" = "true" ]; then
  echo "Mapping silences and measuring loudness..." >&2
  ffmpeg -hide_banner -nostats -i "$INPUT" -vn \
    -af "silencedetect=noise=${NOISE_DB}dB:d=${MIN_SILENCE},loudnorm=print_format=json" \
    -f null - 2> "$TMP_DIR/audio.log"

  # silencedetect logs start and end on separate lines; pair them up.
  # A trailing silence that runs to EOF has no end line and closes at the duration.
  DURATION=$(jq -r '.format.duration' "$TMP_DIR/probe.json")
  awk -v dur="$DURATION" '
    /silence_start:/ { s = $NF }
    /silence_end:/   { for (i = 1; i <= NF; i++) if ($i == "silence_end:") e = $(i + 1);
                       printf "{\"start\":%s,\"end\":%s,\"duration\":%.3f}\n", s, e, e - s; s = "" }
    END              { if (s != "") printf "{\"start\":%s,\"end\":%s,\"duration\":%.3f}\n", s, dur, dur - s }
  ' "$TMP_DIR/audio.log" | jq -s '.' > "$TMP_DIR/silences.json"

  # loudnorm prints its measurement as the last {...} block in the log.
  sed -n '/^{/,/^}/p' "$TMP_DIR/audio.log" | jq '{
    integrated_lufs: (.input_i | tonumber),
    true_peak_dbtp: (.input_tp | tonumber),
    loudness_range_lu: (.input_lra | tonumber)
  }' > "$TMP_DIR/loudness.json"
fi

echo '[]' > "$TMP_DIR/scenes.json"
if [ "$HAS_VIDEO" = "true" ]; then
  echo "Detecting scene changes..." >&2
  ffmpeg -hide_banner -nostats -i "$INPUT" -an \
    -vf "scale=320:-2,select='gt(scene,${SCENE_THRESHOLD})',showinfo" \
    -f null - 2> "$TMP_DIR/video.log"
  grep -o 'pts_time:[0-9.]*' "$TMP_DIR/video.log" | cut -d: -f2 \
    | jq -R 'tonumber' | jq -s '.' > "$TMP_DIR/scenes.json"
fi

jq -n \
  --arg input "$INPUT" \
  --slurpfile probe "$TMP_DIR/probe.json" \
  --slurpfile silences "$TMP_DIR/silences.json" \
  --slurpfile scenes "$TMP_DIR/scenes.json" \
  --slurpfile loudness "$TMP_DIR/loudness.json" \
  --argjson noise_db "$NOISE_DB" \
  --argjson min_silence "$MIN_SILENCE" '
  ($probe[0]) as $p
  | ($p.streams | map(select(.codec_type == "video")) | first) as $v
  | ($p.streams | map(select(.codec_type == "audio")) | first) as $a
  | {
      input: $input,
      duration: ($p.format.duration | tonumber),
      video: (if $v then {
        codec: $v.codec_name,
        width: $v.width,
        height: $v.height,
        fps: ($v.avg_frame_rate | split("/") | if (.[1] | tonumber) == 0 then null else ((.[0] | tonumber) / (.[1] | tonumber)) end),
        rotation: ([$v.side_data_list[]? | .rotation? // empty] | first // 0)
      } else null end),
      audio: (if $a then {
        codec: $a.codec_name,
        sample_rate: ($a.sample_rate | tonumber),
        channels: $a.channels
      } else null end),
      loudness: $loudness[0],
      silence_settings: { noise_db: $noise_db, min_silence_s: $min_silence },
      silences: $silences[0],
      scene_changes: $scenes[0]
    }'

echo "Analysis complete." >&2
