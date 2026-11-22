# Schemas: spec, plan, gates, judgment

> Reference for `creative-workbench`. These are the minimum contracts; implement them
> as typed Dart models + JSON validation. Unknown fields are preserved, not silently
> dropped. All paths are relative to the project root.

## 1. `creative.spec.json`

```jsonc
{
  "schema": "nan.creative.spec/1",
  "kind": "3d | video | interactive | design",
  "track": "static_object | scene | graphics | silly_skit | line_toon | ink_line",
  "prompt": "string, required, non-empty",
  "must_have": ["string"],
  "must_not": ["string"],
  "dims": { "height_m": 0.45 },
  "duration": { "seconds": 30, "fps": 30, "aspect": "16:9" },
  "references": [
    { "path": "ref.png", "role": "silhouette | palette | motion | style" }
  ],
  "style": {
    "pack": "default | silly_skit | line_toon | ink_line",
    "palette": ["#rrggbb"],
    "type": ["family", "weight"]
  },
  "output": { "preview": true, "source": true, "export": "none | mp4 | glb" }
}
```

Validation:

- `schema` exact; `kind`/`track` in the enum; `prompt` non-empty.
- `duration.fps` = 30 for v1; `aspect` in `16:9 | 9:16 | 1:1 | 4:5`.
- `dims` values > 0 and finite; `references[].path` exists and stays inside project.
- `style.palette` hex only; `style.pack` must be known.
- `output.export` cannot be `mp4` while the product export gate is closed.

## 2. `creative.plan.json`

### Common

```jsonc
{
  "schema": "nan.creative.plan/1",
  "kind": "3d | video",
  "summary": "one sentence",
  "acceptance": ["binary, observable item"],
  "risks": ["known failure mode"]
}
```

### 3D

```jsonc
{
  "track": "static_object | scene | graphics",
  "language": "threejs | scene_threejs | glsl_shader",
  "parts": [{
    "id": "seat",
    "dims_m": [0.45, 0.04, 0.42],
    "material": "oak",
    "parent": "frame | null",
    "bbox_center_m": [0, 0.45, 0],
    "fixed": false
  }],
  "zones": [{ "id": "courtyard", "bounds_m": [10, 0, 10] }],
  "placements": [{ "id": "tree_01", "zone": "courtyard", "at_m": [2, 0, 3] }],
  "lights": [{ "id": "key", "type": "directional", "color": "#fff2d0", "intensity": 2 }],
  "cameras": [{ "id": "hero", "at_m": [4, 2, 4], "look_at_m": [0, 1, 0] }],
  "motion": null
}
```

Validation:

- `parts[].id` unique, ASCII snake_case; `dims_m` 3 finite > 0; `parent` exists or null.
- `bbox_center_m` finite; `dims` and `bbox` consistent within 1mm.
- `acceptance` non-empty; each item binary/observable.
- `scene`: placements reference existing zones; cameras finite.

### Video

```jsonc
{
  "track": "silly_skit | line_toon | ink_line",
  "fps": 30,
  "durationFrames": 900,
  "beats": { "bpm": 120, "beatsPerBar": 4, "offsetFrames": 0 },
  "shots": [{
    "id": "s01",
    "start": 0,
    "duration": 90,
    "camera": { "from": { "zoom": 1.0 }, "to": { "zoom": 1.2 }, "ease": "outCubic" },
    "cast": [{ "id": "hero", "x": 540, "y": 960, "scale": 1, "flip": false }],
    "events": [
      { "f": 18, "type": "vfx", "cue": "fire/fireball", "x": 540, "y": 820,
        "seed": 7, "layer": "front" },
      { "f": 20, "type": "sfx", "cue": "impact" }
    ],
    "caption": { "text": "...", "preset": "bottom_bold", "in": "pop" }
  }]
}
```

Validation:

- `shots[].start` + `duration` within `durationFrames`; no unintentional overlap.
- `events[].f` integer; `vfx.cue` in allowlist; `seed` integer.
- `caption.text` escaped; preset/font/color in whitelist.
- `beats.bpm` > 0; `offsetFrames` integer.

## 3. `artifacts/gates.json`

```jsonc
{
  "schema": "nan.creative.gates/1",
  "round": 0,
  "verdict": "PASS | FAIL | ERROR",
  "gates": [
    { "id": "contract", "verdict": "PASS | WARN | FAIL | ERROR",
      "metrics": { "max_bbox_delta_m": 0.004 },
      "fix_hint": "translate seat by (0,0,-0.004) m" }
  ],
  "caps": { "floating": 0.60, "penetration": 0.70 }
}
```

Rules:

- `verdict=ERROR` on any gate caps the score; build errors cap to 0.
- `fix_hint` must be actionable in the runtime's native frame (metres/px/degrees).
- `metrics` values finite; no NaN/Infinity.

## 4. `judge/rNN/judgment.json`

```jsonc
{
  "criteria": {
    "idea": { "score": 0.0, "why": "..." },
    "composition": { "score": 0.0, "why": "..." },
    "craft": { "score": 0.0, "why": "..." },
    "motion": { "score": 0.0, "why": "..." },
    "legibility": { "score": 0.0, "why": "..." },
    "constraint_fit": { "score": 0.0, "why": "..." }
  },
  "summary": "string",
  "strengths": ["string"],
  "issues": [{ "criterion": "craft", "tile": "m2", "evidence": "...", "fix": "..." }],
  "improvement_plan": [{ "priority": 1, "target": "seat/leg", "action": "...", "evidence": "..." }],
  "acceptance": [{ "item": "seat height 0.45m", "pass": true, "evidence": "..." }],
  "defects": [{ "id": "floating_part", "present": false, "evidence": "..." }]
}
```

Rules:

- Each criterion score in `[0,1]` with a non-empty `why`.
- `issues` must cite a tile/evidence; no unsupported claims.
- `improvement_plan` is the **only** input to the next refine round.
- Judge never writes an overall score; `score` computes it.

## 5. `judge/rNN/score.json`

```jsonc
{
  "schema": "nan.creative.score/1",
  "round": 0,
  "overall": 0.0,
  "passed": false,
  "weights": { "idea": 0.2, "composition": 0.2, "craft": 0.2,
               "motion": 0.2, "legibility": 0.1, "constraint_fit": 0.1 },
  "caps": [{ "id": "floating", "value": 0.60, "applied": true }],
  "improvement_plan": [{ "priority": 1, "target": "seat/leg", "action": "..." }]
}
```

Rules:

- `overall` = weighted sum − penalties, floors applied, caps applied last.
- `caps[].applied` records which cap actually lowered the score.
- `improvement_plan` preserves gate ERRORs first.

## 6. Naming and rounds

- `src/` files: kebab-case; one part/zone/layer/shot per file.
- `judge/rNN/` with zero-padded `NN` (`r00`, `r01`…); each round is a git tag.
- `artifacts/` is read-only for the agent; never hand-edit.
- Best round = highest `overall`; tie within 0.03 → pairwise judge.
