# Video pipeline: screenplay, 30fps, seek, style packs

> Reference for `creative-workbench`. The video workbench is code-first: a
> `screenplay.json` compiles to a deterministic player; the player is rendered frame
> by frame for evidence/export.

## 1. Source of truth

```
video/<project>/
  screenplay.json      # scenes/shots/beats/cast/events/vfx/musicRef
  style-pack.json      # selected style + palette/type/motion tokens
  src/                 # compiled player / custom scene code (code is truth)
  artifacts/           # frames, contact sheets, bridges, metrics
  judge/rNN/           # brief + montages + judgment + score
```

- `screenplay.json` is the authoring truth; `src/` is the executable derivation.
- The player must be replayable from `screenplay.json` + style pack alone.
- No hand-edited MP4/PNG as the only copy.

## 2. Time model

- **30fps integer frames**; all authoring in seconds converts once at compile time.
- `stateAt(frame)` is a pure function; `seek(t)` resets and replays from the shot
  start.
- Fixed-step springs/particles integrate from the shot start at 1/30 (or a fixed
  sub-step), never from wall-clock delta.
- No `Math.random` / `Date.now` in state. Seeds: `hash(projectSeed, shotId,
  trackId, instanceId, index)`.
- Background tab: pause; resume by seek, do not catch up frame-by-frame.

## 3. `screenplay.json` (v1 minimum)

```jsonc
{
  "schema": "nan.screenplay/1",
  "fps": 30,
  "seed": 20261122,
  "stage": { "w": 1080, "h": 1920 },
  "style": "silly_skit",
  "audio": { "bpm": 120, "beatsPerBar": 4, "offsetFrames": 0 },
  "casts": {
    "hero": { "rig": "cutout_01", "scale": 1 }
  },
  "shots": [{
    "id": "s01",
    "start": 0,
    "duration": 90,
    "camera": { "from": { "zoom": 1.0 }, "to": { "zoom": 1.2 }, "ease": "outCubic" },
    "cast": [{ "id": "hero", "x": 540, "y": 960, "flip": false, "z": 10 }],
    "events": [
      { "f": 18, "type": "vfx", "cue": "fire/fireball", "x": 540, "y": 820,
        "seed": 7, "layer": "front" },
      { "f": 20, "type": "sfx", "cue": "impact" },
      { "f": 24, "type": "camera.shake", "amp": 4, "freq": 18, "dur": 8 }
    ],
    "caption": { "text": "……", "preset": "bottom_bold", "in": "pop" },
    "transitionIn": { "type": "wipe", "duration": 8, "direction": "left" }
  }]
}
```

Rules:

- `fps` is 30 in v1; do not mix 24/60 in one project.
- Shot times are integer frames; no overlaps unless explicitly a transition.
- `events` are one-shot; interval events (captions, VFX loops) carry duration.
- `vfx.cue` must be in the pixelfx allowlist; unknown cues fail validation.
- `caption` text is user data: escape; no `innerHTML`; font/color whitelist.
- `musicRef` (if any) points to a music project; validate the score before linking.

## 4. Beat grid

- Measure the track (BPM, offset, beats) before planning cuts.
- Cuts/SFX/subtitles land on beats or intentional off-beats; do not eyeball.
- Render one frame per beat first; fix composition/legibility; then full render.
- A shot without a beat reason is a candidate for deletion.

## 5. Style packs

| Pack | Grammar | Renderer |
| --- | --- | --- |
| `silly_skit` | big shapes, squash/stretch, snap zoom/shake/hit-stop, meme cards, SFX | Phaser/canvas + pixelfx VFX |
| `line_toon` | hard single-line characters, speech bubbles, panel wipes, comic physics | Phaser/canvas |
| `ink_line` | thin wobbly ink, warm paper, faceless figures, open double-stroke limbs, day/night inversion | Canvas2D vector strokes (no runtime SVG) |
| `default` | neutral motion graphics | canvas/SVG |

Style pack fields: `palette`, `type`, `pen`, `motion` preset family, `vfx` allowlist,
`caption` presets, `transition` set. All are data; no style pack may add a network
request or a new runtime.

## 6. Determinism checklist

- [ ] one source file / one compiler output; no external runtime
- [ ] all state from frame; no CSS transitions/timers/state
- [ ] springs closed-form or fixed-step from shot start
- [ ] seeded RNG only
- [ ] last frame = first for loops (cursor/particles too)
- [ ] VFX seeds stable; allowlist only
- [ ] captions escaped; text safe area
- [ ] same frame number → same pixels (hash the frame buffer)
- [ ] no console errors; no network requests

## 7. QA and evidence

| Gate | Check |
| --- | --- |
| duration | sum of shots = intended; no gaps/overlaps |
| loop | first/last frame hash equal (for loops) |
| text | safe area, no overflow, contrast ≥4.5 (large text ≥3.0) |
| motion | no dead time >0.8s (unless intentional); no free sine |
| VFX | allowlist, no human/onBody, bounds, ends empty |
| audio | beat grid, SFX sync, musicRef valid |
| render | one frame per beat / contact sheet before full render |

Evidence pack: contact sheet, frame strips around cuts, 3–5 representative frames,
the final `judgment.json`/`score.json` if judged.

## 8. Export

- Current product: preview only; mp4 export is blocked.
- When enabled: deterministic frame capture (`readPixels`/canvas) → encoder; never
  MediaRecorder as the source of truth.
- Frame hash is the golden anchor; bitstream hash is not promised.
- Pixel VFX: render at pixel resolution, nearest-neighbor upscale; never bilinear.

## 9. Anti-patterns

- CSS transitions/timers, wall-clock delta, `Math.random`.
- Free sine "bobbing" instead of a motion solver.
- A new particle burst on every beat; no focal point.
- Text scaled by camera transform (blur); text inside morph without enter/exit.
- Loop where last frame differs from first.
- Mixing pixel VFX into `ink_line` by default.
- Claiming an export that is blocked.
