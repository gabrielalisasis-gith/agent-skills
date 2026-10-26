---
name: video-editor
description: Edits raw footage into a finished, publish-ready cut, deciding which takes and moments to keep, what to cut, and which captions, graphics, b-roll and music add context, then rendering and verifying the result. Use when asked to edit, cut, trim or tighten a video or recording, turn a talking-head, podcast, interview, screen recording or demo into a polished edit, add subtitles or captions, remove silences, dead air or filler words, or make shorts, reels, TikToks or a highlight reel from existing footage.
---

# Video Editor

## Overview

Editing is a sequence of decisions about time: what to keep, in what order, and what to lay on top. An agent cannot watch footage the way a person does, so it edits from evidence instead: a word-timed transcript, a silence map, scene changes, loudness, and sampled frames it actually looks at. Every decision goes into an **edit decision list (EDL)** that can be reviewed before anything is rendered, and the render is a script that turns source + EDL into the output. The source is never modified, every cut has a stated reason, and the finished file is measured, not assumed.

## When to Use

- The user hands over footage and wants an edited video ("edit this", "make this punchier", "cut this down to 60 seconds")
- Talking-head, vlog, podcast, interview, webinar, screen recording, or product demo cleanup
- Removing silences, filler words, flubs, and retakes
- Adding captions/subtitles, lower thirds, explanatory graphics, b-roll, or music to existing footage
- Cutting shorts, reels, TikToks, or a highlight reel out of a longer recording
- Reformatting an edit for another platform (16:9 to 9:16, new length, new loudness target)

**NOT for:**
- Videos generated entirely from code with no source footage (motion-graphics explainers, animated promos). There is nothing to cut; build the animation as a frontend project (see `frontend-ui-engineering`), then reuse this skill's audio, caption, render, and verification steps.
- Generating footage with AI video models. This skill edits what exists.
- Color grading, rotoscoping, or VFX compositing beyond simple overlays. Say so and suggest a dedicated tool.

## Tooling

Required: `ffmpeg`, `ffprobe`, `jq`. Needed for speech: a transcriber that emits **word-level timestamps** (faster-whisper, whisper.cpp, WhisperX, or a transcription API the user has access to). Optional: a beat tracker (aubio, librosa) for music-driven edits; a browser renderer (Playwright, Remotion, HyperFrames) for code-built graphics.

Check what is installed before planning. If no transcriber is available and the footage has speech, stop and ask: do not infer what was said from silence gaps.

## Workflow

```
BRIEF ──→ ANALYZE ──→ STORY ──→ EDL ──→ CONTEXT ──→ PREVIEW ──→ RENDER ──→ VERIFY
  │          │          │        │          │           │           │          │
 goal,     probe,     hook,    every      captions,   proxy +     script    measure,
 format,   words,     outline, cut has    graphics,   contact     from EDL  re-check
 limits    frames     ranked   a reason   music       sheet                 cut points
```

### 1. Brief

Pin down what "good" means before touching the footage. Ask only for what you cannot infer; otherwise state your assumption.

- **Goal and audience:** what should a viewer know, feel, or do at the end?
- **Destination:** platform, aspect ratio, target length
- **Tone:** calm and natural, or fast and punchy
- **Must keep / must cut:** names, claims, sponsor reads, anything off-limits
- **Assets:** logo, fonts, brand colors, music, b-roll, and their licenses
- **Constraints:** "no punch-ins", "no music", caption style, PiP rules
- **Autonomy:** review the plan first (default), or run end to end and report decisions

Common targets when the user does not specify (confirm the platform's current spec if exact compliance matters):

| Destination | Aspect | Frame | Typical length | Loudness |
|---|---|---|---|---|
| YouTube / long-form | 16:9 | 1920x1080 | As long as it earns | -14 LUFS, true peak ≤ -1 dBTP |
| Shorts / Reels / TikTok | 9:16 | 1080x1920 | 15–60 s | -14 LUFS, true peak ≤ -1 dBTP |
| Feed (LinkedIn, X) | 1:1, 4:5, or 16:9 | 1080 wide | 30–90 s | -14 LUFS, true peak ≤ -1 dBTP |
| Podcast video | 16:9 | 1920x1080 | Full episode | -16 LUFS, true peak ≤ -1 dBTP |

### 2. Set up the project and analyze

Work in a project folder; never write into the source location.

```
edit/
  source/      original files, read-only (symlink or copy, never re-encode in place)
  analysis/    analyze.json, transcript.json, frames/, contact sheets
  assets/      graphics, music, b-roll, plus LICENSES.md naming where each came from
  edl.json     the edit, the single source of truth
  captions.srt
  render.sh    source + edl.json → out/
  out/
```

Then gather evidence:

1. **Probe, silences, scenes, loudness:** `skills/video-editor/scripts/analyze.sh source/raw.mp4 > analysis/analyze.json`. Note fps, rotation, variable frame rate, and audio channels; a phone clip with rotation metadata or VFR will misalign cuts if ignored.
2. **Transcribe with word timestamps** to `analysis/transcript.json`. Correct proper nouns and jargon from the brief; do not "improve" what people said.
3. **Look at the footage.** Extract one frame per scene change plus one every 5–10 s, tile them into contact sheets (see [ffmpeg-recipes.md](ffmpeg-recipes.md)), and view them. Note framing, who is on screen, slides or screens worth showing, and visual problems (out of focus, someone walking through, a frozen screen share).

### 3. Find the story

Read the full transcript before choosing a single cut.

- Write the **throughline** in one or two sentences. Everything kept must serve it.
- Pick the **hook**: the strongest claim, result, or visual, placed in the first 1–3 seconds. Moving a later line to the front (a cold open) is fine; mark it as reordered in the EDL.
- Outline the beats in order and rank candidate moments: clarity, energy, novelty, and whether it pays off the hook.
- For a target length, cut whole ideas that do not serve the throughline before shaving words. Trimming pauses alone rarely turns 10 minutes into 60 seconds.

### 4. Pick the cuts and write the EDL

Cut rules:

- **Cut on word boundaries** from the transcript, never mid-word. Start about 0.08–0.15 s before the first word and end about 0.15–0.25 s after the last, then snap to the nearest frame (multiple of `1/fps`).
- **Retakes:** when a line is repeated, keep the cleanest complete take (usually the last), judged by stumbles, fillers, and energy, not by position alone.
- **Dead air:** tighten pauses longer than ~0.5 s. Punchy social edits go down to 0.15–0.3 s; long-form and podcasts keep natural 0.4–0.6 s pauses. Leave breaths at sentence starts, or the speech sounds spliced.
- **Fillers** ("um", "uh", filler "like", "you know"): remove when they sit in their own gap; leave them when removal would clip the next word or jump the speaker's pitch.
- **Preserve meaning.** Never splice fragments into a sentence the speaker did not say, drop a "not" or a qualifier, or move an answer under a different question. Read every kept segment's text in sequence and confirm it says what the speaker meant.
- **Jump cuts** on a locked-off talking head: alternate framing (100% / ~110–115% punch-in) across cuts, or cover the cut with b-roll or a graphic, unless the brief rules punch-ins out.
- **Visual sense:** avoid cutting mid-gesture or during a camera move; prefer cutting at a scene change when one is near.
- **Music-driven edits:** detect beats and snap cut points to the nearest beat within one frame; scale intensity to the section (quieter in verses, full energy at the drop).

Write `edl.json`. Segment times are **source** seconds; overlay times are **output** seconds, so compute the output timeline after the cuts are fixed.

```json
{
  "source": "source/raw.mp4",
  "output": { "width": 1080, "height": 1920, "fps": 30, "loudness_lufs": -14 },
  "segments": [
    { "id": 1, "in": 84.20, "out": 89.47, "text": "We cut onboarding from nine steps to two.", "reason": "hook, reordered from 1:24", "zoom": 1.0 },
    { "id": 2, "in": 3.10, "out": 11.83, "text": "...", "reason": "setup", "zoom": 1.12 }
  ],
  "removed": [
    { "in": 0.00, "out": 3.10, "reason": "mic check" },
    { "in": 41.02, "out": 49.90, "reason": "retake of 49.90-57.10; second take has no stumble" }
  ],
  "overlays": [
    { "type": "graphic", "start": 2.1, "end": 5.0, "file": "assets/graphics/steps.mov", "text_source": "segment 1", "reason": "visualize 9 → 2 steps" }
  ],
  "music": { "file": "assets/music/track.mp3", "license": "see assets/LICENSES.md", "duck_db": -12 }
}
```

Every segment and every removal has a `reason`. A cut you cannot justify in a few words is a cut you have not decided.

### 5. Add context: captions, graphics, b-roll, music

Additions earn their place by helping the viewer understand or stay. Decoration that competes with the speaker is a regression.

- **Captions:** generate from transcript word times remapped to the output timeline. Keep them verbatim except for obvious transcription errors. One or two lines, roughly 32–42 characters per line, shown in sync with the words. Burn them in for social (most feeds autoplay muted) and ship the `.srt` too. On 9:16, keep text out of the bottom ~20% and the right edge where platform UI sits.
- **Graphics and lower thirds:** use them for names, numbers, steps, comparisons, and ideas that are hard to picture. On-screen text is verbatim or faithful to what is said: never invent facts, numbers, or quotes. Keep each graphic inside one uncut stretch of speech, sync its beats to the words, and leave a few seconds of the speaker between full-screen graphics. Build graphics deterministically: ffmpeg `drawtext` for simple text, or an HTML/Canvas/SVG page with a pure `draw(t)` function captured frame by frame (no timers, no CSS transitions, no state carried between frames) and exported with alpha. Write a one-page style guide (type, colors, motion) first so every graphic looks like the same show.
- **B-roll and stock:** only user-supplied footage or footage whose license you can name. Record the source in `assets/LICENSES.md`.
- **Music:** only user-supplied or license-cleared tracks. Duck it 10–15 dB under speech with a sidechain compressor, fade in and out, and never let it mask words.
- **Audio cleanup:** apply a 10–20 ms fade at every cut to prevent clicks; use noise reduction and EQ sparingly, then normalize loudness last.

### 6. Preview before the final render

Changing an EDL costs seconds; re-rendering a 4K edit costs minutes. Before the full-quality render, produce:

1. A **cut summary table**: segment id, source in/out, output start, text, reason
2. A **contact sheet of the cut**: one frame from each segment plus each graphic
3. A **low-resolution proxy render** (540p, fast preset)

In review mode, share these and wait for approval. In autonomous mode, review them yourself: watch for repeated lines, missing setup, abrupt endings, and graphics covering faces, then fix the EDL and record what you changed.

### 7. Render

Generate `render.sh` from `edl.json` so the edit is reproducible; never hand-type a one-off command you cannot rerun. Use frame-accurate `trim`/`atrim` + `concat` with re-encoding. Stream-copy cuts (`-ss ... -c copy`) snap to keyframes and silently shift cut points. Normalize every segment to the same size, SAR, fps, and pixel format before `concat`. Export H.264 High, `yuv420p`, CRF 18–20, AAC 48 kHz at 192 kbps or more, with `+faststart`. Tested commands for each step are in [ffmpeg-recipes.md](ffmpeg-recipes.md).

### 8. Verify

```bash
skills/video-editor/scripts/verify.sh out/final.mp4 <sum of segment durations> -14 1.0
```

The script checks streams, pixel format, duration against the EDL, audio/video drift, black frames, dead air, integrated loudness, and true peak, and exits non-zero on any failure. Then do the checks a script cannot:

- **Inspect every cut point:** extract the frames just before and after each cut and look at them. Check for flash frames, a jump in framing you did not intend, and graphics in the wrong place.
- **Re-transcribe the render** and diff it against the concatenated `text` of the EDL segments. Missing words, clipped words, and repeated lines show up here, not in the waveform.
- **Spot-check captions** at three or more timestamps to confirm the on-screen words match the audio.

Deliver `out/final.mp4`, `captions.srt`, `edl.json`, `render.sh`, `assets/LICENSES.md`, and a short decisions log: what was cut and why, what was reordered, and anything that needs a human call.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "I'll just cut out the silences, that's the edit" | Silence removal is cleanup, not editing. Without a throughline and a hook, a tight cut is still a boring one. |
| "The transcript is enough, I don't need to look at the frames" | Transcripts miss the slide on screen, the person walking through the shot, and the out-of-focus take. Look at the contact sheet. |
| "Stream copy is faster, cuts will be fine" | `-c copy` cuts land on keyframes, often seconds away. Frame-accurate cuts need a re-encode. |
| "I'll make the graphic say it more clearly than the speaker did" | Paraphrase drifts into claims nobody made. On-screen text stays verbatim or faithful. |
| "This track is everywhere online, it's fine to use" | Popular is not licensed. Unlicensed music gets videos muted or taken down. Use user-supplied or cleared audio. |
| "The render finished, so it's done" | A finished render can still have a clipped word, a flash frame, or audio 6 LU too quiet. Run `verify.sh` and inspect the cut points. |
| "Reviewing the plan first slows things down" | Fixing an EDL takes seconds; discovering the wrong story after a full render costs the whole render. |
| "I'll approximate what they said from the pauses" | Without a transcript you are guessing at content. Get word timestamps or ask. |

## Red Flags

- Writing to or re-encoding over the source file
- Cuts placed by fixed intervals or silence gaps alone, without consulting word timestamps
- A kept sequence that, read aloud, says something the speaker did not mean
- Two takes of the same line both in the cut
- Captions or graphics with words, numbers, or quotes not present in the source
- Music or b-roll with no recorded source or license
- `-ss`/`-to` with `-c copy` used for edit cuts
- No `edl.json`, or segments without a `reason`
- Graphics covering the speaker's face or crossing an audio cut
- Declaring the edit done without measured loudness and a look at the cut points

## Verification

After editing, confirm:

- [ ] Source files are unchanged (same size and modification time as before)
- [ ] `edl.json` exists, and every segment and removal has a reason
- [ ] The hook lands in the first 1–3 seconds of the output
- [ ] Reading the EDL segment texts in order gives a coherent story that preserves the speaker's meaning
- [ ] `verify.sh` passes: duration matches the EDL within 0.1 s, no black frames, no dead air over the gap limit, loudness within 1 LU of target, true peak ≤ -1 dBTP
- [ ] Frames on both sides of every cut were extracted and inspected
- [ ] A re-transcription of the render matches the EDL text with no missing, clipped, or repeated lines
- [ ] Captions match the audio at three or more spot-checked timestamps and sit inside the platform's safe area
- [ ] Every third-party asset is listed in `assets/LICENSES.md`
- [ ] `render.sh` regenerates the same output from source + EDL
