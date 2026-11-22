# Prompt anatomy: from a brief to a spec

> Reference for `creative-workbench`. The six blocks are a **thinking order**, not a
> magic incantation. Use them to decide what is missing before code.

## 1. `<inputs>` — identity first

Ask only what changes the artifact's identity. Everything else gets a stated default.

| Input | Must ask? | Default |
| --- | --- | --- |
| Product/brand name + one-line promise | yes if the artifact is about a product | — |
| Audience + desired action | no | general audience; no CTA |
| Duration + aspect | yes for video | 15–30s, 16:9 |
| Dimensions (3D) | if the object has a real size | human-scale approximation, stated |
| Style/references | no | project `DESIGN.md` / style pack |
| Palette/type | no | style pack tokens |
| Must-have facts/lines/features | yes | — |
| Must-not (claims, colors, assets) | no | empty, stated |
| Assets (logo, footage, audio, fonts) | yes if needed | none; do not invent brand assets |
| Music/BPM | no | no music; neutral 120 BPM only if cuts need it |
| Output (preview/source/export) | no | source + preview + evidence |

**Rule:** if a missing answer changes what the artifact *is*, ask. If it only changes
taste, choose, state it in `spec.json`, and continue.

## 2. `<direction>` — one idea

Write 5–8 lines:

- **One idea** in a sentence. If you need "and", it is two ideas.
- **One focal point** per shot/scene. What should the eye land on first?
- **Palette**: 1–2 accents, paper/background, forbidden colors.
- **Type**: one family, weights, tracking; no more than two sizes per hierarchy.
- **Motion grammar**: snap/spring/linear/stop-motion; one dominant easing family.
- **Banned list**: the fastest way to prevent slop. Examples:
  - video: "no rainbow gradients, no random glitch, no particle burst per beat,
    no full-screen white flash, no template cards, no dead time >0.5s"
  - 3D: "no floating parts, no grey default materials, no unplanned parts, no
    non-uniform scale to fit"
  - VFX: "no stock human, no on-body effects, no pixel fire on ink-line"

The banned list becomes the judge's `must_not` and the checker's anti-pattern scan.

## 3. `<structure>` — time/space order

### Video

- `bpm`, `beatsPerBar`, `offset`; total bars; shot durations in **frames**.
- Beat sheet: `bar/beat → event → camera → text → SFX`.
- Hook in the first 1–3s; one idea per shot; a turn at 60–80%; a closing image.
- Every shot has an entrance, a hold, and an exit; no dead time.
- Loop: the last frame equals the first (including cursor/particles).

### 3D

- Parts list with ids, dimensions (metres), materials, parent, bbox centre.
- Assembly order: base → supports → primary mass → secondary → detail.
- Acceptance items: binary/observable (e.g. "seat is 0.45m high", "four legs
  touch the floor", "no part floats >2mm").
- Scene: zones, placements, camera path, lights, atmosphere, motion.

## 4. `<build>` — the code contract

### Video

```text
- one self-contained HTML/JS page (or the project's screenplay compiler output)
- all state is a pure function of frame: stateAt(frame), seek(t)=reset+replay
- no CSS transitions, no setTimeout/setInterval, no state carried between frames
- springs are closed-form step responses or fixed-step from shot start
- seeded RNG only; no Math.random/Date
- 30fps integer frames; render one frame per beat first
- export frames deterministically; motion blur only via subframes + blend
```

### 3D

```text
- raw executable three.js / GLSL; code is truth
- plan.json numbers are the contract; build at those numbers, never scale to fit
- one part/zone/layer per file; edit locally, never rewrite a whole file
- export GLB/URDF/PNG from code; artifacts are read-only
- gates run before judging; every ERROR caps the score
```

### VFX

```text
- cue id from the pixelfx allowlist; no actor/onBody/moves
- fixed 30fps; seed derived from (project, shot, cue, instance)
- color + light buffers; back/front layers; nearest-neighbor upscale
```

## 5. `<gotchas>` — known failure modes

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Text blurry after camera zoom | `will-change`/transform on text | render text at final scale; avoid scaling text layer |
| Morph container text overlaps | content swap has no enter/exit timing | separate text enter/exit; blur during swap |
| Loop stutters | last frame ≠ first; cursor/particles differ | author last=first; reset state at loop |
| Walk slides | speed ≠ stride/(duty×period) | move at the gait's speed; plant the foot |
| 3D part floats | placement/grounding error | snap to support surface; check gap |
| 3D part penetrates | overlap >2mm | end at receiving surface or hollow the receiver |
| Scene empty/thin | no focal object/zone | add one hero, then supporting layers |
| VFX looks like a sticker | no body/impact context | add wind-up/hit-stop/reaction in the **host** rig, not pixelfx |
| VFX washed out | too much light | lower light k; keep white for the hottest core |
| AI-slop look | every element moves, no focal point | delete half the motion; one idea per shot |

## 6. `<start>` — proof before scale

Before writing the full artifact:

1. Restate the inputs and defaults; list what is still unknown.
2. Show the direction (one idea, focal point, palette, banned).
3. Show the plan: beat sheet for video, parts/dims for 3D.
4. Build **one** figure/shot/part and show a still/frame strip.
5. Only after approval, scale to the full piece.

This is the highest-leverage rule from the prompt corpus: one good piece sets the
bar; a full set built at once comes back generic.

## 7. Map to `spec.json` / `plan.json`

| Prompt block | Spec field | Plan field |
| --- | --- | --- |
| inputs | `prompt`, `must_have`, `must_not`, `dims`, `duration`, `references`, `style` | — |
| direction | `style`, `must_not` | `summary`, `acceptance` |
| structure | `duration` | `shots[]` / `parts[]` |
| build | `output`, `track` | `src` layout, deterministic rules |
| gotchas | — | `risks[]` (optional) |
| start | — | `acceptance[]`, `preview` gate |

## 8. Minimal filled example (video, 15s UI morph)

```jsonc
{
  "kind": "video",
  "track": "silly_skit",
  "prompt": "A 15s loop where one button morphs through 8 UI states on a 120 BPM beat.",
  "must_have": ["one shape never cuts", "last frame equals first", "one accent color"],
  "must_not": ["rainbow gradients", "particle bursts", "dead time >0.4s"],
  "duration": { "seconds": 15, "fps": 30, "aspect": "16:9" },
  "style": { "pack": "default", "palette": ["#111111", "#f4f1ea", "#e25822"] },
  "output": { "preview": true, "source": true, "export": "none" }
}
```

The corresponding plan has 8 states × 4 beats, each with a frame range, spring
target, text swap timing, and an acceptance item "the shape's outline is continuous
across every state".
