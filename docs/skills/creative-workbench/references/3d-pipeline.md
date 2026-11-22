# 3D pipeline: plan → code → gates → blind judge → best round

> Reference for `creative-workbench`. Based on 3dcodeverse (Apache-2.0 skill/harness
> contract) + three-live. Python/Blender/CadQuery/URDF runtimes are **not** product
> dependencies; this is the contract implemented with our Dart/JS tools.

## 1. Tracks we support

| Track | v1 | Language | Deliverable |
| --- | --- | --- | --- |
| `static_object` | ✅ | threejs | code + `object.glb` + renders |
| `scene` | ✅ | scene_threejs | `src/**` + `public/assets/*.glb` + renders + probes |
| `graphics` | ✅ | glsl_shader | source + judged frames + metrics |
| `articulated_object` | backlog | URDF/Blender | not shipped; approximate with three.js groups later |

Pick the track from the request. "A chair" → `static_object`; "a room/street/world"
→ `scene`; "a shader/portal/nebula" → `graphics`.

## 2. Authoring modes (resolves the `scene.json` vs code conflict)

| Mode | Truth | Use | Inspector |
| --- | --- | --- | --- |
| `scene` | `scene.json` | manual modeling: primitives, transforms, materials, small scenes | direct edit; compile to `src/scene.js` for preview/export |
| `code` | `src/*.js` | agent generation, 3dcodeverse harness, complex worlds/shaders | read-only derived scene graph; edits go through controlled patches |

- New empty scene → `scene`; one-line generation/harness → `code`.
- Both share three-live, gates, artifacts, and judge.
- `scene.json` in `code` mode is a **derived projection**, not a second truth.
- If the user demands a single truth, prefer `code`; manual primitive editing can
  still be exposed as a code-patch surface.

## 3. Workspace

```
spec.json      track, language, prompt, must_have, must_not, dims, references
plan.json      exact numbers + acceptance
src/           code (code mode truth; scene mode generated)
public/        compiled assets (scene track)
artifacts/     object.glb, renders/, gates.json, measurement.json (read-only)
judge/rNN/     brief.md, montages, judgment.json, score.json
```

## 4. Plan schema

```jsonc
{
  "schema": "nan.creative.plan/1",
  "track": "static_object",
  "language": "threejs",
  "summary": "A mid-century oak dining chair, four legs, curved back.",
  "acceptance": [
    "seat height is 0.45 m",
    "four legs touch the floor within 2 mm",
    "no part floats or penetrates >2 mm",
    "one material per part; no grey default"
  ],
  "parts": [
    { "id": "seat", "dims_m": [0.45, 0.04, 0.42], "material": "oak",
      "parent": "frame", "bbox_center_m": [0, 0.45, 0] },
    { "id": "leg_fl", "dims_m": [0.04, 0.45, 0.04], "material": "oak",
      "parent": "frame", "bbox_center_m": [-0.18, 0.225, -0.17] }
  ],
  "motion": null,
  "camera": { "views": ["front", "three_quarter", "side", "top"] }
}
```

For a scene, replace `parts` with `zones`, `placements`, `lights`, `atmosphere`,
`cameras`, `motion`. Keep the same acceptance style.

**Plan rules:**

- exact numbers, no adjectives; every part has id/dims/material/parent.
- acceptance items are binary and observable; no "looks good".
- placeholders are allowed only in the plan, never in `src/`; a ≤12-triangle box
  within 1mm of the plan box at check time is a `placeholder_part` ERROR.
- build at the plan's numbers; never non-uniform scale a finished mesh to fit.

## 5. Loop

1. **Plan** — write `plan.json`.
2. **Validate** — schema + numeric checks + acceptance + duplicate ids + dims.
3. **Baseline r00** — write all files in at most three steps; entry file last;
   run `check`; fix every ERROR. Whole object first, detail second.
4. **Judge** (only when asked) — commit/tag `rNN`; pack brief + montages; hand the
   exact instruction to a fresh judge; it writes `judgment.json`.
5. **Score** — rubric arithmetic + caps + improvement list.
6. **Refine** — exactly the requested rounds; only the score's list; gate ERRORs
   first; one change per named item; repeated finding → different change.
7. **Deliver** — best-scoring round; if not the last, `checkout rNN -- src` and
   re-run `check`.

Stop: requested rounds done / score passed with empty list / overall fell two
rounds running. Do not self-polish between judges.

## 6. Gates and thresholds

### static_object / articulated

- **contract**: per-part and overall bbox within `max(10mm, 10%)` per axis;
  WARN at 1×, ERROR at 3×; ground within 10mm WARN / 30mm ERROR; footprint
  centring; `placeholder_part`.
- **connectivity**: contact ≤2mm; penetration >2mm WARN, >10mm ERROR; floating
  ERROR; islands <5% WARN.
- **detail budget**: triangle floor/ceiling, build time from parts × instances.
- **fixed parts**: must not be renamed/moved/removed.
- **articulated** (backlog): FK, rest penetration, joint sweep, motion direction.

### scene

- **placement**: each placed root: gap under feet, burial, support,
  interpenetration, bounds, scale; print metres to move.
- **census/budget**: objects, materials, lights, draw calls (≤15,000), triangles,
  console errors.
- **shader preflight**: compile every ShaderMaterial headlessly; errors with lines.
- **frames**: exposure, camera, content, frame motion, hero unseen.

### graphics

- lint; frames at t=0,1,2.5,4,6s at 1280×720; NaN, black/blown, static, flicker,
  low detail.

Every ERROR caps the score; WARN never caps (fix once if cheap).

## 7. Blind judge

- Pack: 14-view + detail/contact montage (object); authored cameras + orbit at
  t=0/1.5s (scene); frame sheet (graphics).
- Brief: request, plan digest, acceptance, measured/gate facts, rubric anchors,
  defect checklist, exact JSON.
- Judge reads only `brief.md` + images; never code/reasoning; returns
  `criteria`, `summary`, `strengths`, `issues`, `improvement_plan`, `acceptance`,
  `defects`.
- Score: weighted sum − penalties, floors, then caps from `gates.json`:
  build error 0; floating 0.60; penetration 0.70; contract 0.75; unmet must
  0.60/0.70; per-track caps.
- Pairwise comparisons run both display orders; agreement required.

## 8. Tool mapping (names to implement)

| 3dcodeverse | our tool (proposed) | purpose |
| --- | --- | --- |
| `validate-plan` | `three_plan_validate` | schema + numeric + acceptance |
| `build` | `three_build` | compile/export GLB + lint |
| `check` | `three_check` | all gates → `gates.json` |
| `measure` | `three_measure` | bbox/ground/part/tris |
| `render-views` / `render-sheet` | `three_render_views` | multi-view + contact sheet |
| `scene-probe` | `three_scene_probe` | census/draw calls/console |
| `check-placement` | `three_check_placement` | float/sink/support/overlap + metres |
| `shader-probe` | `three_shader_probe` | compile ShaderMaterial |
| `judge` / `judge-pack` | `three_judge` | commit/tag + brief + montage |
| `score` | `three_score` | rubric + caps + improvement list |

## 9. Execution surface

- three-live sandbox in the app WebView; no external browser/headless in product.
- CSP: self-contained page, no network; three-live worker boundary unchanged.
- Screenshot evidence: multi-view, not a single angle; bounded bytes/count.
- GLB export: from the same source; artifacts read-only.
- Mobile: fewer views / lower resolution if needed; do not claim 14-view parity.

## 10. Direct-adoption boundaries

- **Adopt**: 3dcodeverse skill text/plan schemas/thresholds/judge rubric (Apache-2.0),
  with attribution; three-live 1.4.0 already vendored.
- **Do not adopt**: Python CLI, Blender, CadQuery, URDF, moderngl runtimes in the
  product; 3DCodeVerse-2M dataset (CC-BY-NC-SA) in the product; example assets.
- **Backlog**: articulated track; full multi-agent DAG; training/fine-tuning.
