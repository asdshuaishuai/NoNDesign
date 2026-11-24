# Story-short pipeline: 2D characters in a 3D world

> Reference for `creative-workbench`. A code-first vertical animated story short:
> 55–70 s, 1080×1920, 30 fps, 2D flat characters in a painted 3D world, ink
> outlines, lens blur, gliding camera, synthesized sound. **Reference-only**:
> no Remotion/React/Node runtime; our execution surface is three-live + the app
> WebView.

## 1. When to use

- "Make a 55–70 s vertical animated story short."
- "2D cartoon characters in a 3D world / like the bridge video."
- History/science story with a physical cause and effect, explainable by an
  everyday analogy.
- Not for: pure motion graphics (use `video-pipeline.md`), sand-sculpture comedy
  (`silly_skit`), or a 3D object turntable (`3d-pipeline.md`).

## 2. Artifacts

```
SCRIPT.md          facts + sources, 8-beat script, ~3.7 words/s
voice.wav          one steady narrator (recorded or TTS); word timings below
words.json         [{w, start, end}] — the time axis
screenplay.json    shots + cameras + lights + dof + kicks + audio cues
src/               three-live scene code + character textures + post chain
artifacts/         stills, contact sheets, QA report, final frames
judge/rNN/         look-match brief + side-by-sides + verdict/score
```

Hard rule: **story, characters and voice are ours**. Reference frames are for
style study only; never copy scripts, characters, shots, music or voices.

## 3. Script formula (8 beats)

| Beat | What |
| --- | --- |
| Hook | paradox as fact, sentence 1, 10–16 words, no setup/logo/intro |
| Setting | 1–2 lines, present tense, concrete place/time/person |
| Escalation | 3–6 beats, each bigger; 1–2 researched jokes; optional in-character lines |
| Mystery | one "Wait, …?" question |
| Pivot | "You see," → real mechanism |
| Analogy | one everyday analogy (swing, body, water pipe) |
| Consequence | the rule/change it caused |
| Callback | ironic twist; last word ends the video |

- 55–70 s at 3.5–4.1 words/s (median 3.7); sentences ~13.5 words; spoken, contractions.
- Do not describe what the viewer already sees.
- Facts carry a source in `SCRIPT.md`; jokes must be researched facts.
- Captions only if the user asks; author's "English only / one male voice" is not
  our default.

## 4. Voice and word timings

1. Record or synthesize `voice.wav` (one steady tone; no intro music).
2. Produce `words.json` with word-level start/end (ASR or TTS timings).
3. Hand-fix the timings; everything visual is timed to words.
4. Lock picture timing before making sound; any later change re-runs the mix.

## 5. Shot plan

`screenplay.json` shot fields:

```jsonc
{
  "id": 1, "a": 0, "b": 130,
  "light": "day | golden | night",
  "crowd": "march | fall | water | bank | tourists | none",
  "tau": "29.5+t",                  // story time, not wall clock
  "cam": [{ "f": 0, "pos": [7.5, 8.6, -13], "look": [0, 8.4, 5],
            "fov": 44, "roll": 0, "cut": false, "dur": 24 }],
  "dof": 15,                        // cInf px at 1080
  "foreground": ["hat"],
  "kicks": [{ "f": 130, "amp": 2.2 }]
}
```

Top-level: `xfade: {shotId: frames}`, `flashAt: frame`, `words: [...]`, `audio`.

Rules:

- Every visual reaction lands **0–3 frames before its word**.
- Hard cut only for big reframes; otherwise smootherstep glide 18–40 f.
- Every hold creeps 0.15–0.35%/f; punch words ~0.6%/f.
- Impact kicks flip sign each frame and decay over 7 f; rolls 4–4.6°.
- Foreground props in ~1/3 of shots; re-check props near moving cameras.
- No static hold ≥12 f (QA reads it as frozen).

## 6. Look values (style pack defaults)

| Item | Value |
| --- | --- |
| Format | 1080×1920, 30 fps; final 1440×2560 |
| World ink | ~3 px @1080, #0b0a0c; silhouettes/depth/normal creases only; no wall/floor joins/horizon |
| Character ink | plum #201628–#2f1d28, thicker on shadow side; character cards on `NOINK` |
| Day light | az 75 / el 48; lit [1.58,1.5,1.33]; shade [.30,.29,.36]; lift [.05,.06,.11]; sky #3e7fd2→#b8d0ec; fog=horizon 25→300 m |
| Golden | az 6 / el 7; key #FFB36B×1.5; violet-blue shade; sky #ffc47c→#8a6f8a; peach fog past 50 m |
| Albedo | muted brick/cream/ochre/terracotta; 7/8.4/9.8 m houses; no lemon/lavender lit faces |
| DOF | cInf 15–16 hook/river CU, 12–14 close-up, 10–12 MS, 7 park, 5 golden sway, 0 wide |
| Post | ink → lens pre → lens main → bloom (thr 1.0, int .5, 6 levels, radius .6) → NEUTRAL tone map → grade; MSAA 4; grain off |
| Character | bean head h/w .94, eyes .26W, no blush/highlight, 14 expressions, 3.5 head-heights, 0.8 m planted stride, blink 0.5–2.3 s |
| Camera | glides 18–40 f, peak ≤25 px/f @720p; hold creep; 4–4.6° rolls; no handheld float |

## 7. World and characters

- **World**: three-live scene; painted Canvas2D textures; sky gradient/fog; river;
  buildings as painted boxes; sight-line culling so no house blocks a camera.
- **Characters**: Canvas2D design canvas 600×1000, soles at y=975; draw body/front/side,
  outfits, 14 expressions, effect sprites; upload as textures on camera-facing
  billboards; receive scene light/shadow; no emissive paste-on; `NOINK` layer.
- **Crowds**: sprite pool, walk cycles, blinks; crowd mode per shot.
- **Post**: normal+depth ink pass; lens blur with a cInf table per beat; bloom only
  HDR emissives; neutral tone map; grade; resolution-scaled parameters.

## 8. Sound

- Event table → synthesized SFX + original score; no copyrighted music/SFX.
- Mix: music +3 dB, SFX −6 dB, voice unchanged; ~−14 LUFS, LRA ~2.4; ducking.
- Output `mix.wav` 48 kHz exact length, stems, `cues.md`.
- Mux with `-map 0:v:0 -map 1:a:0` if the renderer writes a silent track.

## 9. QA gates

Port the logic (not the code) of a frame-by-frame QA script:

| Check | Threshold |
| --- | --- |
| Specs | width/height/fps/frames/duration; audio codec/sample rate/channels |
| Loudness | ~−14 LUFS integrated; peak ≤−1 dBTP |
| Silences | no unintended >0.3 s at −45 dB |
| Black frames | mean luma <0.04 (except planned) |
| White frames | mean luma >0.93 (except planned flash) |
| Frozen | frame diff <0.02 for ≥12 frames (except planned) |
| Pops | diff >3× local median +1 (except planned) |
| Contact sheets | 2 s = 60 frames, 10×6, frame numbers burned in |
| Per-shot stats | luma mean/std/p2/p98/saturation medians |

Every ERROR/warning becomes a targeted fix with a frame number. Do not deliver on
"render exit 0".

## 10. Look-match loop

1. Measure the reference first: one report per topic (motion, depth, textures,
   characters, lighting, outlines, grade); numbers, not adjectives.
2. One sandbox per owner (cam/world/mat/char/post); each edits only its files.
3. Merge owned files; typecheck; re-sync sandboxes from main.
4. Fresh verifier: side-by-side sheets, score each area 0–10, numbered fix list.
5. Map each fix to its owner; repeat until the score plateaus.
6. Reference is for study only; never copy its content.

## 11. Boundaries

- **Do not** vendor Remotion / `@remotion/three` / React / Node / Chromium / ffmpeg
  into the product. They are reference implementations.
- **Do not** copy reference frames/videos/characters/scripts/voices/music.
- **Do** use three.js (already direct) via three-live; our own post chain, audio,
  and export.
- `toon_3d` is a **candidate** style; do not count it as a shipped style until the
  user rules and the spike passes.
