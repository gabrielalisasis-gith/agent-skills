# ffmpeg Recipes for video-editor

Tested commands for each render step. Replace times, sizes, and paths with values from `edl.json`. All times are seconds; snap cut points to frame boundaries (multiples of `1/fps`).

## Contact sheet and cut-point frames

```bash
# One frame every 5 s, 160 px wide, tiled 6x4 per sheet
ffmpeg -i source/raw.mp4 -vf "fps=1/5,scale=160:-2,tile=6x4" analysis/frames/sheet_%02d.png

# One frame at each scene change from analyze.json
jq -r '.scene_changes[]' analysis/analyze.json | while read -r t; do
  ffmpeg -loglevel error -ss "$t" -i source/raw.mp4 -frames:v 1 "analysis/frames/scene_${t}.png"
done

# Frames either side of an output cut at 12.40 s (one frame at 30 fps = 0.033 s)
ffmpeg -loglevel error -ss 12.36 -i out/final.mp4 -frames:v 1 out/check/cut_12.40_before.png
ffmpeg -loglevel error -ss 12.41 -i out/final.mp4 -frames:v 1 out/check/cut_12.40_after.png
```

## Frame-accurate cuts with de-click fades

Each segment is trimmed, reset to start at zero, and given 10 ms fade-in and 20 ms fade-out so cuts don't click. Every video branch ends with `setsar=1` (and the same size and fps) because `concat` rejects inputs whose parameters differ.

```bash
ffmpeg -i source/raw.mp4 -filter_complex "
[0:v]trim=start=0:end=2.033,setpts=PTS-STARTPTS,setsar=1[v0];
[0:a]atrim=start=0:end=2.033,asetpts=PTS-STARTPTS,afade=t=in:d=0.01,afade=t=out:st=2.013:d=0.02[a0];
[0:v]trim=start=4.0:end=7.0,setpts=PTS-STARTPTS,setsar=1[v1];
[0:a]atrim=start=4.0:end=7.0,asetpts=PTS-STARTPTS,afade=t=in:d=0.01,afade=t=out:st=2.98:d=0.02[a1];
[v0][a0][v1][a1]concat=n=2:v=1:a=1[v][a]" \
  -map "[v]" -map "[a]" -c:v libx264 -crf 18 -preset medium -pix_fmt yuv420p \
  -c:a aac -b:a 192k -ar 48000 -movflags +faststart out/cut.mp4
```

The `afade=t=out` start is the segment length minus the fade duration. Generate this graph from `edl.json` in `render.sh` rather than writing it by hand.

## Punch-in on a segment (jump-cut cover)

Scale up, crop back to the output size from the center, reset SAR:

```
[0:v]trim=start=4.0:end=7.0,setpts=PTS-STARTPTS,scale=iw*1.12:-2,crop=1920:1080,setsar=1[v1];
```

Center crop can cut off a face that sits off-center; add `crop=1920:1080:x:y` offsets from the contact sheet when needed.

## Reframe 16:9 to 9:16

Center crop (subject stays centered):

```bash
ffmpeg -i in.mp4 -vf "crop=ih*9/16:ih,scale=1080:1920,setsar=1" -c:a copy out_9x16.mp4
```

Blurred-background fill (keeps the whole frame, e.g. for screen recordings):

```bash
ffmpeg -i in.mp4 -vf "split[a][b];
[a]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=20[bg];
[b]scale=1080:-2[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,setsar=1" -c:a copy out_9x16.mp4
```

## Burned-in captions

Requires an ffmpeg built with libass (`ffmpeg -filters | grep subtitles`).

```bash
ffmpeg -i out/cut.mp4 -vf "subtitles=captions.srt:force_style='FontName=Inter,Fontsize=18,Bold=1,Outline=2,MarginV=60'" \
  -c:v libx264 -crf 18 -pix_fmt yuv420p -c:a copy out/captioned.mp4
```

`MarginV` lifts captions above platform UI. For word-by-word highlight styles, write an `.ass` file with per-word `\k` karaoke tags from the word timestamps instead of an `.srt`.

## Overlay a graphic for a time range

Graphics rendered with alpha (ProRes 4444 `.mov`, VP9 `.webm`, or a PNG sequence). `setpts=PTS+START/TB` delays the graphic so its first frame lands at `START`.

```bash
ffmpeg -i out/cut.mp4 -i assets/graphics/steps.mov -filter_complex "
[1:v]setpts=PTS+2.1/TB[g];
[0:v][g]overlay=x=(W-w)/2:y=H*0.12:enable='between(t,2.1,5.0)'[v]" \
  -map "[v]" -map 0:a -c:v libx264 -crf 18 -pix_fmt yuv420p -c:a copy out/with_graphics.mp4
```

Simple text without a graphics pipeline:

```
drawtext=fontfile=/path/Inter-Bold.ttf:text='9 steps → 2':fontsize=72:fontcolor=white:borderw=4:x=(w-tw)/2:y=h*0.15:enable='between(t,2.1,5.0)'
```

## Music under speech with ducking

The voice drives a sidechain compressor on the music, so the music drops whenever someone speaks.

```bash
ffmpeg -i out/cut.mp4 -i assets/music/track.mp3 -filter_complex "
[1:a]volume=0.5,afade=t=in:d=1,afade=t=out:st=58:d=2[m];
[0:a]asplit=2[voice][key];
[m][key]sidechaincompress=threshold=0.05:ratio=8:attack=20:release=400[duck];
[voice][duck]amix=inputs=2:duration=first:normalize=0[a]" \
  -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k out/with_music.mp4
```

Set the music fade-out start to the output duration minus the fade length.

## Loudness normalization (last audio step)

Single pass is fine for previews:

```
loudnorm=I=-14:TP=-1.5:LRA=11
```

For finals, measure first, then feed the measurement back in for an accurate linear pass:

```bash
ffmpeg -i out/mix.mp4 -af loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json -f null - 2> loud.log
# read input_i, input_tp, input_lra, input_thresh, target_offset from loud.log, then:
ffmpeg -i out/mix.mp4 -af "loudnorm=I=-14:TP=-1.5:LRA=11:measured_I=<input_i>:measured_TP=<input_tp>:measured_LRA=<input_lra>:measured_thresh=<input_thresh>:offset=<target_offset>:linear=true,aresample=48000" \
  -c:v copy -c:a aac -b:a 192k out/final.mp4
```

## Proxy render for review

```bash
ffmpeg -i out/final_candidate.mp4 -vf "scale=-2:540" -c:v libx264 -preset veryfast -crf 28 -c:a aac -b:a 96k out/proxy.mp4
```

## Source quirks to handle before cutting

- **Variable frame rate** (phone and screen recordings; `analyze.json` fps looks odd, or `r_frame_rate` differs from `avg_frame_rate` in ffprobe): convert to constant first with `-vf fps=30` on an intermediate, or cut points drift.
- **Rotation metadata** (`rotation` non-zero): ffmpeg auto-rotates on decode; set output size from the rotated dimensions.
- **Multiple audio tracks or mics:** pick or mix tracks explicitly with `-map`; check which track has the speech.
