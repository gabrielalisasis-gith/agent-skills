#!/bin/bash
set -e

# Checks a rendered video for the video-editor skill: duration against the
# EDL, audio/video length drift, black frames, unintended dead air, and
# loudness against a target. Prints a JSON report; exits 1 if any check fails.
#
# Usage: skills/video-editor/scripts/verify.sh <output> [expected_duration_s] [target_lufs] [max_gap_s]
#   expected_duration_s  sum of EDL segment lengths; skipped when omitted
#   target_lufs          integrated loudness target (default -14)
#   max_gap_s            longest silence allowed in the cut (default 1.0)

OUTPUT="$1"
EXPECTED="${2:-}"
TARGET_LUFS="${3:--14}"
MAX_GAP="${4:-1.0}"

if [ -z "$OUTPUT" ] || [ ! -f "$OUTPUT" ]; then
  echo "Usage: verify.sh <output> [expected_duration_s] [target_lufs] [max_gap_s]" >&2
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

echo "Probing render..." >&2
ffprobe -v error -show_format -show_streams -of json "$OUTPUT" > "$TMP_DIR/probe.json"

echo "Scanning for black frames, dead air, and loudness..." >&2
ffmpeg -hide_banner -nostats -i "$OUTPUT" \
  -vf "blackdetect=d=0.1:pix_th=0.10" \
  -af "silencedetect=noise=-45dB:d=${MAX_GAP},loudnorm=print_format=json" \
  -f null - 2> "$TMP_DIR/scan.log" || true

grep -o 'black_start:[0-9.]* black_end:[0-9.]*' "$TMP_DIR/scan.log" \
  | sed 's/black_start:\([0-9.]*\) black_end:\([0-9.]*\)/{"start":\1,"end":\2}/' \
  | jq -s '.' > "$TMP_DIR/black.json"
grep -o 'silence_start: [0-9.]*' "$TMP_DIR/scan.log" | awk '{print $2}' \
  | jq -R 'tonumber' | jq -s '.' > "$TMP_DIR/gaps.json"

if grep -q '"input_i"' "$TMP_DIR/scan.log"; then
  sed -n '/^{/,/^}/p' "$TMP_DIR/scan.log" \
    | jq '{integrated_lufs: (.input_i | tonumber), true_peak_dbtp: (.input_tp | tonumber)}' > "$TMP_DIR/loud.json"
else
  echo 'null' > "$TMP_DIR/loud.json"
fi

jq -n \
  --arg output "$OUTPUT" \
  --arg expected "$EXPECTED" \
  --argjson target_lufs "$TARGET_LUFS" \
  --argjson max_gap "$MAX_GAP" \
  --slurpfile probe "$TMP_DIR/probe.json" \
  --slurpfile black "$TMP_DIR/black.json" \
  --slurpfile gaps "$TMP_DIR/gaps.json" \
  --slurpfile loud "$TMP_DIR/loud.json" '
  ($probe[0]) as $p
  | ($p.format.duration | tonumber) as $dur
  | ($p.streams | map(select(.codec_type == "video")) | first) as $v
  | ($p.streams | map(select(.codec_type == "audio")) | first) as $a
  | (($v.duration // $p.format.duration) | tonumber) as $vdur
  | (if $a then (($a.duration // $p.format.duration) | tonumber) else null end) as $adur
  | ($loud[0]) as $l
  | [
      { name: "has_video", pass: ($v != null) },
      { name: "has_audio", pass: ($a != null) },
      { name: "pixel_format_yuv420p", pass: ($v.pix_fmt == "yuv420p"), detail: $v.pix_fmt },
      (if $expected == "" then empty else
        { name: "duration_matches_edl",
          pass: ((($vdur - ($expected | tonumber)) | fabs) <= 0.1),
          detail: { video: $vdur, expected: ($expected | tonumber) } } end),
      (if $adur == null then empty else
        { name: "av_length_drift_under_100ms",
          pass: ((($vdur - $adur) | fabs) <= 0.1),
          detail: { video: $vdur, audio: $adur } } end),
      { name: "no_black_frames", pass: (($black[0] | length) == 0), detail: $black[0] },
      { name: "no_dead_air_over_max_gap", pass: (($gaps[0] | length) == 0),
        detail: { max_gap_s: $max_gap, gap_starts: $gaps[0] } },
      (if $l == null then empty else
        { name: "loudness_within_1lu_of_target",
          pass: ((($l.integrated_lufs - $target_lufs) | fabs) <= 1),
          detail: { integrated_lufs: $l.integrated_lufs, target_lufs: $target_lufs } },
        { name: "true_peak_at_or_below_minus_1dbtp",
          pass: ($l.true_peak_dbtp <= -1),
          detail: $l.true_peak_dbtp } end)
    ] as $checks
  | {
      output: $output,
      duration: $dur,
      resolution: (if $v then "\($v.width)x\($v.height)" else null end),
      passed: ($checks | all(.pass)),
      checks: $checks
    }' | tee "$TMP_DIR/report.json"

if [ "$(jq -r '.passed' "$TMP_DIR/report.json")" != "true" ]; then
  echo "Verification FAILED: see checks with pass=false." >&2
  exit 1
fi
echo "Verification passed." >&2
