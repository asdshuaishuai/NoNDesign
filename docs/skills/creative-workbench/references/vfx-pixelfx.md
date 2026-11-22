# VFX pipeline: pixelfx effects only, no humans

> Reference for `creative-workbench`. Direct adoption is authorized for **effects
> only** (user decision 2026-11-22). Characters/humans stay in our own rig.

## 1. What we vendor

```
app/assets/video/vendor/pixelfx/
  core/                 color, math, painter, sim, shapes, fx (patched), index
  fx/                   allowlisted effects only
  LICENSE
  NOTICE.md             Hugo Duprez / Hollow Crown / Patch font exclusion
  manifest.json         upstream commit/version + per-file sha256 + allowlist
```

**Not vendored:** `actor.js`, `rig.js`, `poses.js`, `act.js`, `moves/`, `gallery/`,
`skills/`, `tools/` (dev only), `gallery/fonts`.

## 2. Allowlist rules

An effect is allowed only if:

- no `meta.actor`, no `o.actor`, no `onBody`, no `stockActor`, no `createAct`;
- it does not draw the 24×38 stock character or any human silhouette;
- it is a pure environmental/combat effect: fire, explosions, water, ice,
  lightning, nature, weather, impacts/projectiles/melee (effect-only), arcane,
  holy, shadow, sci-fi, transitions, pickups, UI, non-on-body status.

Generate the allowlist by scanning `src/fx/**/*.js` at vendoring time. The manifest
is the only source; the video compiler rejects any cue not in it.

## 3. Event schema

```jsonc
{
  "f": 42,
  "type": "vfx",
  "cue": "fire/fireball",
  "x": 540, "y": 960,
  "scale": 1.0,
  "flip": false,
  "palette": ["#2b0a06", "#7a1a10", "#d33a1e", "#ff8a2a", "#ffd166", "#fff3c4"],
  "seed": 7,
  "light": 1.2,
  "layer": "front"
}
```

- `x/y` is the anchor (impact point/ground/muzzle), not the top-left.
- `layer`: `front` default; `back` for ground rings/far half.
- `seed`: derive from `hash(projectSeed, shotId, cue, instanceId)` if omitted.
- `palette`: style-pack whitelist; no arbitrary CSS gradients.
- One-shot must end empty at `duration`; loops must be seamless.

## 4. Runtime

- `createFrame(w,h)` + `clearFrame`; `createFx(mod, opts)`; `fx.update(1/30);
  fx.draw(frame,"back"/"front")`; `composite(frame, rgba, bg)`.
- Color buffer + additive light buffer; light is added last.
- 120Hz internal substeps for simulated effects; frame number is the only clock.
- Pixel resolution: 320×180 / 480×270 (choose per project); upscale
  nearest-neighbor.
- Multiple effects share a frame; sort by layer/y; no per-effect canvas.

## 5. Style matrix

| Style | Use | Notes |
| --- | --- | --- |
| `silly_skit` | ✅ primary | combat/impact/fire/ice/wind; keep pixel density consistent |
| `line_toon` | ⚠️ conditional | only as a deliberate pixel-FX layer; don't default-mix |
| `ink_line` | ❌ default no | 1px pixel light clashes with ink/paper; only an explicit experiment |
| 3D | ❌ | use three-live/3dcodeverse, not 2D VFX |

## 6. Gates

- cue in allowlist; no actor/onBody/moves.
- deterministic: same seed+frame → same pixels; no `Math.random`/`Date`.
- bounds: no spill; one-shot ends empty; loop seam clean.
- palette whitelist; no arbitrary gradients.
- performance: <2ms/frame desktop; mobile uses sprite sheets.
- composition: back/front layers correct; light doesn't cover characters.
- human boundary: no stock character/human rig in the vendored subset.
- license: LICENSE/NOTICE/manifest present; font excluded.

## 7. Dev-time checks (not shipped)

From pixelfx `tools/check.mjs`: spills, loop seams, unseeded randomness, slow
frames, act key order (not used), hands teleport (not used). Run these when
creating a new effect; our runtime gates mirror them.

## 8. Anti-patterns

- Importing `moves/` or `createAct` "because it looks cool" — that brings the human.
- Using `onBody` effects (freeze/poison) without our own character mask.
- Default pixel fire in `line_toon`/`ink_line`.
- Unseeded particles; frame-rate-dependent physics.
- Bilinear upscaling (mushy pixels) or light layer painted over the hero.
