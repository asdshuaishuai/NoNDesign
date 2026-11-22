# Blind judge and score

> Reference for `creative-workbench`. The judge is a **fresh context** that sees only
> `brief.md` and the rendered evidence. It never sees the builder's code or
> reasoning, and it never awards an overall score itself — `score` does the math.

## 1. Why blind

- The builder is invested in its own work; self-scoring inflates and misses defects.
- Visual judgments must be anchored to the same brief, images, and rubric.
- Deterministic gates answer what code can answer; the judge answers what only eyes
  can answer. Neither overrides the other: a gate ERROR caps the score.

## 2. Brief (`judge/rNN/brief.md`)

The pack contains:

1. **Request** — the user's brief and `must_have` / `must_not`.
2. **Plan digest** — parts/shots/dims/acceptance (not the full source).
3. **Measured facts** — gate PASS/FAIL, bbox/contact/placement numbers, frame
   metrics.
4. **Rubric** — criteria, weights, anchors, defect checklist, penalties, caps.
5. **Exact JSON** the judge must return.
6. **Images** — labelled montages/crops/pose/frame sheets; every tile numbered.

The judge reads `brief.md` + every image in one step, then writes `judgment.json`
and replies `wrote <path>`. It does nothing else.

## 3. Judge JSON

```jsonc
{
  "criteria": {
    "idea": { "score": 0.0, "why": "observed evidence" },
    "composition": { "score": 0.0, "why": "..." },
    "craft": { "score": 0.0, "why": "..." },
    "motion": { "score": 0.0, "why": "..." },
    "legibility": { "score": 0.0, "why": "..." },
    "constraint_fit": { "score": 0.0, "why": "..." }
  },
  "summary": "one paragraph",
  "strengths": ["..."],
  "issues": [{ "criterion": "craft", "tile": "m2", "evidence": "...", "fix": "..." }],
  "improvement_plan": [{ "priority": 1, "target": "seat/leg", "action": "...", "evidence": "..." }],
  "acceptance": [{ "item": "seat height 0.45m", "pass": true, "evidence": "measurement" }],
  "defects": [{ "id": "floating_part", "present": false, "evidence": "..." }]
}
```

Rules:

- Every score needs an observation; no score without evidence.
- Do not invent faults; do not credit what is not visible.
- If a gate fact and an image disagree about something visible, trust the image for
  the visual criterion and report the file-level fact as an issue.
- The judge never sees the builder's code, plan reasoning, or previous judgments
  (unless the brief includes a prior score for a refine round).

## 4. Score arithmetic

```
overall = Σ(weight_i × criterion_i) − Σ(defect_penalty)
then apply floors, then caps from gates.json
```

Starting weights:

| Criterion | Video | 3D |
| --- | --- | --- |
| idea | 0.20 | 0.15 |
| composition | 0.20 | 0.20 |
| craft | 0.20 | 0.25 |
| motion | 0.20 | 0.15 |
| legibility | 0.10 | 0.10 |
| constraint_fit | 0.10 | 0.15 |

Caps (examples; per-track values live in the rubric):

- build error: 0
- floating part: 0.60
- penetration >10mm: 0.70
- contract violation: 0.75
- unmet `must` acceptance: 0.60 (0.70 for graphics)
- missing pose sheet / dynamic collision: 0.50–0.60
- unverified mandatory checklist: 0.60 + 0.40 × verified/total

Caps are applied after the weighted sum; a clean-looking render cannot escape a
gate failure.

## 5. Repeatability

- Freeze the rubric and brief format before comparing harness variants.
- Use multi-view montages, not a single frame; randomize tile order where possible.
- Pairwise preference: run both display orders; only agreement counts.
- Track judge variance on a fixed artifact bank; do not tune on the same artifacts
  you report.
- A judge that cannot run in a fresh context → mark the round `self-judged` and
  treat it as degraded; never silently claim a blind score.

## 6. Refine loop

- Do not judge until `check` has no ERROR.
- `score` emits an improvement list; refine only that list, gate ERRORs first.
- One change per named item; keep all other parts/names/dimensions.
- A repeated finding needs a different change of the thing it measures.
- Exactly the number of rounds the user asked for; stop early if passed + empty
  list, or if overall fell two rounds running.
- Deliver the **best-scoring** round; if not the last, restore `src/` from its tag
  and re-run `check`.

## 7. Human-facing report

At most ten lines: deliverable/round/score/caps; source entry files; evidence
paths; gate summary; open items. No file-by-file list, no self-congratulation.
