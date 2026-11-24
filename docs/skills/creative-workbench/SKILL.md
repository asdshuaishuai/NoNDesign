---
name: creative-workbench
description: Turn a creative brief into a code-first, verifiable artifact — a 3D world/object, a motion-graphics video, or an interactive prototype. Use when the user asks for a 3D scene, a code-generated video, a pixel-VFX-driven animation, or a creative deliverable that must stay editable, deterministic, and provable with renders/measurements. Enforces intake → direction → structure → build → check → blind judge → refine → deliver.
metadata:
  version: 0.1-spec
  status: spec-only (not wired into the app yet)
  applies_to: [3d, video, design]
  references: prompt-anatomy · 3d-pipeline · video-pipeline · story-short · vfx-pixelfx · judging · schemas
---

# Creative Workbench Skill

> 状态：**方案定稿（2026-11-22），未接线**。本 skill 是契约/流程规范，不是已实现
> 运行时；施工前不得把其中的工具名/目录当成现状。

This skill is the **controller** for all code-first creative work in NaN. It does not
replace the workbench UIs; it defines the shared contract they call.

> **Core sentence:** the artifact is executable code; the render is evidence; the
> judge is blind; the best round is delivered.

## Contents

- [0. What this skill is / is not](#0-what-this-skill-is--is-not)
- [1. Non-negotiables](#1-non-negotiables)
- [2. Intake: ask before build](#2-intake-ask-before-build)
- [3. Classify the request](#3-classify-the-request)
- [4. Canonical artifacts](#4-canonical-artifacts)
- [5. The workflow](#5-the-workflow)
- [6. Video line](#6-video-line)
- [7. 3D line](#7-3d-line)
- [8. VFX line](#8-vfx-line)
- [9. Blind judge and score](#9-blind-judge-and-score)
- [10. The six-block prompt](#10-the-six-block-prompt)
- [11. Quality rubric](#11-quality-rubric)
- [12. Anti-patterns](#12-anti-patterns)
- [13. Delivery format](#13-delivery-format)
- [14. References](#14-references)

## 0. What this skill is / is not

**Is:**

- A standardized way to turn a brief into a **spec → plan → source → artifacts →
  judgment → score** pipeline.
- A shared language for the **3D**, **video**, and **design** workbenches.
- A set of **hard gates** (deterministic) plus a **blind judge** (perceptual).
- A way to keep the user in control: inputs are asked, rounds are explicit, the
  best round is delivered with evidence.

**Is not:**

- A prompt-only "make it viral" template.
- A runtime that starts Python, Blender, CadQuery, URDF, headless Chrome, or any
  external service.
- A license to copy third-party characters, videos, logos, prompts, or assets.
- A replacement for the workbench UI; it is the contract behind it.

## 1. Non-negotiables

1. **Code is truth; artifacts are derived.** The source in `src/` (or the structured
   source in the mode's contract) is the deliverable. GLB, PNG, MP4, sprite sheets
   are regenerated; never hand-edit them as the only copy.
2. **Requirements, not templates.** The skill states what must be true, where, and
   how it is measured. It does not force a shape/structure the brief did not ask for.
3. **Deterministic before perceptual.** Every run has a fixed frame clock, seeded
   randomness, and gates that code can answer. A visual "looks fine" cannot override
   a measured ERROR.
4. **Ask before build.** Missing inputs (duration, aspect, palette, references,
   must/must-not) are asked or explicitly defaulted. Never silently invent brand,
   factual claims, or assets.
5. **One idea, one focal point.** A shot/scene has a single thing the viewer should
   look at. "Everything moves" is a defect, not a style.
6. **Evidence, not claims.** A round is done when `check` has no ERROR and the
   evidence pack exists. "It should be fine" is not evidence.
7. **Generator and judge are separate contexts.** The judge sees only `brief.md`
   and images; never the builder's code, reasoning, or self-assessment.
8. **Repairs are targeted and numeric.** Each fix names the part/zone/layer, the
   measured deviation, and the direction/amount to move or change. No whole-file
   rewrites, no "polish everything".
9. **No external runtimes in the product.** three-live (3D), the app WebView (video),
   and our own Dart/JS instruments are the execution surface. Python/Blender/CadQuery/
   URDF/headless Chrome are development references only.
10. **Respect the source licenses.** Third-party code/effects/assets are vendored
    only when the user has explicitly allowed them; NOTICE/LICENSE travel with them;
    characters/humans are not imported from VFX libraries.

## 2. Intake: ask before build

Ask for the smallest set that changes the output. If the user says "you decide",
record the default and proceed; do not ask again.

| Input | Why it matters | Default if silent |
| --- | --- | --- |
| Artifact kind | 3D object / 3D scene / video / interactive / design prototype | infer from the verb; ask if still ambiguous |
| One-line promise | the single idea/focal point | none — must ask or derive from brief |
| Audience + call to action | tone, density, ending | general audience / no CTA |
| Duration + aspect | timeline, camera, subtitle safe area | video 15–30s; 16:9; 3D square preview |
| Style / references | palette, type, motion grammar | project DESIGN.md / style pack default |
| Must-have | facts, brand, product, features, exact lines | none |
| Must-not | banned looks, claims, colors, assets | none |
| Assets | logo, footage, images, audio, fonts | none; do not invent brand assets |
| Music/BPM | beat grid, cuts, SFX | no music; use a neutral tempo only if needed |
| Output | preview only / source / export | source + preview + evidence |

**Stop rule:** if the missing input changes the artifact's identity (brand name,
product claims, duration, aspect, must-have), ask. If it only changes taste, choose a
default, state it, and continue.

## 3. Classify the request

| Request looks like | Line | Primary contract |
| --- | --- | --- |
| "Make a chair / robot / room / street / world" | 3D | `3d-pipeline.md`; 3dcodeverse tracks |
| "Make a 15s launch film / UI motion / explainer / music visual" | Video | `video-pipeline.md`; `screenplay.json` |
| "Add fire / ice / wind / explosion / hit spark" | VFX | `vfx-pixelfx.md`; pixelfx allowlist |
| "Make an interactive prototype / game / toy" | Interactive | video line + interaction contract |
| "Design a product / prototype" | Design | existing design pipeline; this skill only supplies intake/judge |

Pick the **smallest** line that satisfies the brief. A 3D object used inside a video
is a 3D asset, not a second video pipeline.

## 4. Canonical artifacts

Every creative project uses the same workspace shape, regardless of line:

```
spec.json        the request: kind, track/style, prompt, must_have, must_not,
                 dims/duration, references, output
plan.json        the plan: exact numbers, parts/shots/beats, materials/palette,
                 motion, acceptance checklist
src/             the executable source (code is truth in code mode)
artifacts/       build/render/measure output; read-only for the agent
judge/rNN/       brief.md + montages + judgment.json + score.json
```

### 4.1 `creative.spec.json` (minimum)

```jsonc
{
  "schema": "nan.creative.spec/1",
  "kind": "3d | video | interactive | design",
  "track": "static_object | scene | graphics | silly_skit | line_toon | ink_line | toon_3d",
  "prompt": "one-line brief",
  "must_have": ["..."],
  "must_not": ["..."],
  "dims": { "height_m": 0.45 },
  "duration": { "seconds": 30, "fps": 30, "aspect": "16:9" },
  "references": [{ "path": "ref.png", "role": "silhouette|palette|motion" }],
  "style": { "pack": "default", "palette": [], "type": [] },
  "output": { "preview": true, "source": true, "export": "none|mp4|glb" }
}
```

### 4.2 `creative.plan.json` (minimum)

```jsonc
{
  "schema": "nan.creative.plan/1",
  "kind": "3d | video",
  "summary": "one sentence",
  "acceptance": ["binary, observable item"],
  "parts": [{ "id": "seat", "dims_m": [0.45, 0.04, 0.42], "material": "oak",
              "parent": "frame", "bbox_center_m": [0, 0.45, 0] }],
  "shots": [{ "id": "s01", "start": 0, "duration": 90, "camera": "...",
              "cast": [], "events": [], "vfx": [] }],
  "style": { "pack": "ink_line", "palette": [], "gait": "walk" }
}
```

The plan is **validated before any source is written**. A plan without exact numbers
or acceptance items is invalid.

## 5. The workflow

Copy this checklist per run.

**Task Progress**

- [ ] 0. Intake: fill `spec.json`; ask only the identity-changing gaps.
- [ ] 1. Direction: one idea, one focal point, palette/type, banned list.
- [ ] 2. Plan: write `plan.json` with exact numbers + acceptance.
- [ ] 3. Validate plan: schema + numeric/acceptance checks; fix until PASS.
- [ ] 4. Build: one figure/shot/scene first; write source; no whole-file rewrites.
- [ ] 5. Check: deterministic gates; fix every ERROR; WARN fixed once if cheap.
- [ ] 6. Judge (only if asked): fresh context, brief + images only.
- [ ] 7. Refine (exact rounds asked): only the score's improvement list.
- [ ] 8. Deliver: best round + evidence + ≤10-line report.

### Stage details

0. **Intake** — use the table in §2. Write `spec.json`; do not start coding before
   the identity inputs are settled.
1. **Direction** — write a short direction block: one idea, one focal point, 1–2
   accents, type, motion grammar, banned list. This becomes the judge's anchor.
2. **Plan** — 3D: parts/dims/materials/parents/acceptance. Video: shots/beats/
   duration/camera/events/acceptance. Keep it short; one sentence per part/shot.
3. **Validate** — reject placeholder echo, missing acceptance, impossible dims,
   duplicate ids, out-of-range times. The plan is the contract the gates measure.
4. **Build** — 3D: whole object/scene first (every part at its box), then detail;
   video: one shot/figure first, then the rest. Small modular files; edits are local.
5. **Check** — run all gates; every ERROR caps the score. Do not judge a broken
   build. Record `artifacts/gates.json`.
6. **Judge** — only when the user asks for a score/refine. Pack the brief/montages;
   start a fresh context with the exact judge instruction; it writes
   `judgment.json` and nothing else.
7. **Refine** — exactly the requested number of rounds. Gate ERRORs first, then the
   judge's improvement list. A repeated finding needs a different change, not the
   same edit again. Stop if the overall score falls two rounds running.
8. **Deliver** — best-scoring round, not necessarily the last. Report overall/caps
   per round, entry files, deliverable round, evidence paths. No file-by-file list.

## 6. Video line

Contract: [references/video-pipeline.md](references/video-pipeline.md).

- Source of truth: `screenplay.json` + style pack + `src/`.
- Fixed **30fps integer frames**; all state is `stateAt(frame)`; `seek(t)` resets
  and replays from the shot start; no `Math.random`/`Date`/wall-clock delta.
- No CSS transitions/timers/state between frames; springs are closed-form or fixed
  step from the shot start.
- Beat grid: `bpm`, `beatsPerBar`, `offset`; cuts/SFX/subtitles on beats or
  intentional off-beats.
- Loop: last frame = first frame, including cursor/particles.
- Render QA: one frame per beat / contact sheet first; then full render; motion
  blur only via subframes + blend.
- Styles: `silly_skit` (pixel/combat), `line_toon` (hard-line comic), `ink_line`
  (ink/paper, Canvas2D vector strokes); `toon_3d` (2D characters in a 3D world)
  is a **candidate** until ruled and spiked — see
  [references/story-short.md](references/story-short.md).
- Export: current product blocks mp4; when enabled, use deterministic frame capture,
  never MediaRecorder as the source of truth.

## 7. 3D line

Contract: [references/3d-pipeline.md](references/3d-pipeline.md).

- Direct adoption: **three-live** execution + **3dcodeverse** skill/harness
  contract (Apache-2.0). Python/Blender/CadQuery/URDF runtimes are not shipped.
- Tracks: `static_object` (threejs), `scene` (scene_threejs), `graphics`
  (glsl_shader); `articulated_object` is backlog.
- Two authoring modes:
  - `scene`: `scene.json` is truth; compile to three.js; manual gizmo/inspector.
  - `code`: `src/*.js` is truth; 3dcodeverse harness; `scene.json` is a derived
    read-only projection.
- Gates: contract/bbox/grounding, connectivity/contact, placeholder parts, scene
  placement/census/draw calls, shader compile, frame metrics.
- Judge: 14-view/montage for objects; authored cameras + orbit for scenes; frame
  sheets for graphics.
- Best round delivered; every round is a git tag `rNN`.

## 8. VFX line

Contract: [references/vfx-pixelfx.md](references/vfx-pixelfx.md).

- Direct adoption: **pixelfx effects only**, MIT, no humans.
- Allowed: fire, explosions, water, ice, lightning, nature, weather, impacts/
  projectiles/melee (effect-only), arcane, holy, shadow, sci-fi, transitions,
  pickups, UI, non-on-body status.
- Forbidden: `actor.js`/`rig.js`/`poses.js`/`act.js`, `moves/`, any `meta.actor`/
  `o.actor`/`onBody` effect, stock character, gallery/fonts.
- VFX is an event in `screenplay.json`: `{f, type:"vfx", cue, x, y, seed, palette,
  layer}`; cue must be in the allowlist.
- Primary style: `silly_skit`; conditional `line_toon`; not default for `ink_line`.
- Two buffers: color + additive light; nearest-neighbor upscale; fixed 30fps.

## 9. Blind judge and score

Contract: [references/judging.md](references/judging.md).

- Fresh context; reads only `brief.md` + images; returns exact JSON:
  `criteria`, `summary`, `strengths`, `issues`, `improvement_plan`, `acceptance`,
  `defects`.
- Deterministic gates cap the score: build error 0; floating 0.60; penetration
  0.70; contract violation 0.75; unmet must 0.60–0.70; per-track caps.
- The judge never sees the builder's code or reasoning; the builder never
  self-scores to skip the judge.
- Pairwise preference (when comparing rounds/designs) must run both display orders.
- Best round selected by score; ties within 0.03 use pairwise.

## 10. The six-block prompt

Use this as the **intake/direction** template; it is not a magic prompt. Details and
examples: [references/prompt-anatomy.md](references/prompt-anatomy.md).

```text
<inputs>   Ask me for the identity-changing inputs; list defaults.
<direction> One idea, one focal point, palette/type, motion grammar, banned list.
<structure> Beat/shot/part order with times and durations.
<build>    Code contract: single source, deterministic clock, no timers/CSS state,
           seeds, render/export, file layout.
<gotchas>  Known failure modes for this exact artifact.
<start>    Ask the remaining inputs; show the plan/beat sheet/one figure first.
```

## 11. Quality rubric

| Dimension | Weight (video) | Weight (3D) | What it means |
| --- | --- | --- | --- |
| `idea` | 0.20 | 0.15 | one clear idea; not a pile of effects |
| `composition` | 0.20 | 0.20 | focal point, framing, negative space, hierarchy |
| `craft` | 0.20 | 0.25 | line/material/light/timing detail; no slop |
| `motion` | 0.20 | 0.15 | easing, weight, secondary motion, no dead time |
| `legibility` | 0.10 | 0.10 | reads at 1x; text/subtitles safe |
| `constraint_fit` | 0.10 | 0.15 | brief/brand/must-have/must-not honored |
| **Caps** | — | — | gate errors, floating, penetration, contract, unmet must |

Rubric numbers are **starting points**; calibrate per track with a fixed artifact
bank before comparing harness variants. Do not let the judge invent weights.

## 12. Anti-patterns

- One-shot "make it viral" with no inputs/direction.
- Template look: every element moves, rainbow gradients, generic glow, stock
  transitions, no focal point.
- Video: CSS transitions/timers/state, wall-clock delta, free sine motion, last
  frame ≠ first frame, text blur after camera scale.
- 3D: placeholders, floating parts, >10mm penetration, non-uniform scale to fit a
  box, detail via new unplanned parts, grey default materials.
- VFX: importing the stock character/moves, mixing pixel VFX into ink-line by
  default, arbitrary palettes, unseeded randomness.
- Judge: self-judging in the same context, judging code instead of renders,
  averaging away a gate ERROR.
- Delivery: reporting "done" without evidence; delivering the last round instead
  of the best; claiming an export that is blocked.

## 13. Delivery format

At most ten lines:

```text
Deliverable: <kind/track> · round rNN · score <n>/100 (caps: ...)
Source: <entry files>
Evidence: <montage/contact sheet/frame strip paths>
Checks: <gate PASS/FAIL summary>
Open items: <only if the user asked for more rounds or an export is blocked>
```

No file-by-file list, no restating the plan, no self-congratulation.

## 14. References

- [prompt-anatomy.md](references/prompt-anatomy.md) — six-block template, intake,
  direction, beat structure, build/gotchas/start.
- [3d-pipeline.md](references/3d-pipeline.md) — 3dcodeverse tracks/plan/gates/judge,
  three-live, dual authoring mode.
- [video-pipeline.md](references/video-pipeline.md) — `screenplay.json`, 30fps,
  seek, beat grid, style packs, render/export.
- [story-short.md](references/story-short.md) — 55–70 s vertical story-short
  pipeline: 8-beat script, word timings, shot plan, 2D/3D look values, QA,
  look-match loop; `toon_3d` candidate, reference-only.
- [vfx-pixelfx.md](references/vfx-pixelfx.md) — filtered pixelfx subset, allowlist,
  event schema, style matrix.
- [judging.md](references/judging.md) — blind judge, brief, JSON, rubric, caps,
  best-round selection.
- [schemas.md](references/schemas.md) — `spec` / `plan` / `gates` / `judgment` /
  `score` field contracts and validation rules.
- Research: [awesome-opus5-5-videos.md](../../research/awesome-opus5-5-videos.md) ·
  [3dcodeverse.md](../../research/3dcodeverse.md) ·
  [pixelfx.md](../../research/pixelfx.md) ·
  [line-art-animation.md](../../research/line-art-animation.md) ·
  [raea.md](../../research/raea.md)（只参考，不引入；3D 视频执行面用 three-live）·
  [material-painter.md](../../research/material-painter.md)（GPL 阻塞，参考/可选外部工作站）·
  [plan-creative-workbench.md](../../plan-creative-workbench.md).
