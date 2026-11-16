#!/usr/bin/env python3
"""RSI 评审工具 —— 环②（spec 对照，机械强制）+ 环③（抽帧清单，agent vision 判断）。

img2threejs 原则：scripts do enforcement; agent vision does judgment。
本脚本只做确定性核查与材料准备；视觉评分由调用方的评审 agent 完成。

环②（机械，exit 1 = fail）：
  - spec 门复检（render.py 同一套校验）
  - timeline expr 与 spec.formulas/params 符号闭包一致性
  - beats 覆盖：screenplay 每个 beat.at 必须落在片长内（教育类跳过）
  - facts/storyboard 形状完整性

环③材料：
  --samples N  在片长均匀取 N 帧的时间点清单 + 对应帧图路径（若已渲染）
  --vision-prompt  生成评审 agent 用的对照提示词（style/facts 逐条）
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from render import Expr, RenderRejected, load_spec, _CONSTS  # noqa: E402

_FUNCS_NAMES = {"sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sqrt",
                "abs", "min", "max", "floor", "ceil", "log", "exp", "pow",
                "radians", "degrees"}


def collect_expr_nodes(obj, out: list) -> None:
    if isinstance(obj, dict):
        if "expr" in obj and isinstance(obj["expr"], str):
            out.append(obj["expr"])
        for v in obj.values():
            collect_expr_nodes(v, out)
    elif isinstance(obj, list):
        for v in obj:
            collect_expr_nodes(v, out)


def main() -> int:
    if len(sys.argv) < 2:
        print("用法：review.py timeline.json [--samples N] [--frames-dir DIR] [--vision-prompt]")
        return 1
    tl_path = Path(sys.argv[1])
    tl = json.loads(tl_path.read_text("utf-8"))
    problems: list[str] = []

    # —— spec 门复检 ——
    try:
        spec = load_spec(tl_path, tl)
    except RenderRejected as e:
        print(f"REJECTED: {e}", file=sys.stderr)
        return 2

    total = sum(float(s.get("duration", 0)) for s in tl.get("scenes", []))
    params = set(spec.get("params", {}))
    formulas = {f["name"] for f in spec.get("formulas", [])}
    # 与 render.py 符号闭包逐字一致（含内建常量 pi/e）：漏 _CONSTS 曾导致
    # 「render exit 0 但 review 判 undeclared_symbol:['pi']」的矛盾死循环。
    allowed = {"t", "T"} | params | formulas | set(_CONSTS)
    formula_srcs = {f["expr"] for f in spec.get("formulas", [])}

    # —— expr 符号闭包 ——
    exprs: list[str] = []
    collect_expr_nodes(tl.get("scenes", []), exprs)
    undeclared: set[str] = set()
    for src in exprs:
        try:
            tree = ast_parse(src)
        except RenderRejected as e:
            problems.append(str(e))
            continue
        names = {n.id for n in ast_walk_names(tree)}
        bad = names - allowed - _FUNCS_NAMES
        if bad:
            undeclared |= bad
    if undeclared:
        problems.append(f"undeclared_symbol: {sorted(undeclared)} 未在 spec 声明（params/formulas）")

    # —— 公式复用：timeline expr 若与某 formula 完全同串，视为一致（好）；
    #    独立裸公式（含算术且不在 spec.formulas 里）只是提醒，强制对照由
    #    评审 agent 按 facts 做 ——「想当然」由 undeclared_symbol 硬拦。——
    raw_formulas = [e for e in exprs if any(ch in e for ch in "+-*/") and e not in formula_srcs]
    if raw_formulas:
        print(f"NOTE: {len(raw_formulas)} 条 timeline 内联算式不在 spec.formulas 原文清单中（允许，但评审 agent 需对照 facts 核查）")

    # —— beats 覆盖（screenplay）——
    if spec.get("kind") == "screenplay":
        for b in spec.get("beats", []):
            at = float(b.get("at", -1))
            if at < 0 or at > total:
                problems.append(f"beat_out_of_range: at={at} 超出片长 {total:.1f}s（{b.get('what','')[:30]}）")

    # —— 教育类：facts/storyboard 存在性已在 load_spec 保证；storyboard 场景数提示 ——
    if spec.get("kind") == "science" and spec.get("storyboard"):
        n_sb = len(spec["storyboard"])
        n_sc = len(tl.get("scenes", []))
        if n_sb != n_sc:
            print(f"NOTE: storyboard {n_sb} 幕 vs timeline {n_sc} 场景（允许合并/拆分，评审 agent 对照）")

    status = "FAIL" if problems else "PASS"
    print(f"[环② spec 对照] {status}（片长 {total:.1f}s）")
    for p in problems:
        print(f"  ✗ {p}")
    if problems:
        return 1

    # —— 环③材料 ——
    args = sys.argv[2:]
    samples = 6
    if "--samples" in args:
        samples = int(args[args.index("--samples") + 1])
    times = [round(total * i / samples, 3) for i in range(samples)]
    print(f"[环③ 抽帧清单] {samples} 帧 @ {times}")
    if "--frames-dir" in args:
        frames_dir = Path(args[args.index("--frames-dir") + 1])
        fps = int(tl.get("fps", 30))
        listing = []
        for t in times:
            f = min(int(t * fps), max(0, int(total * fps) - 1))
            listing.append(frames_dir / f"frame_{f:05d}.png")
        print("  " + "\n  ".join(str(p) for p in listing))
    if "--vision-prompt" in args:
        lines = [
            "你是视频质量评审。对照规范逐条核查抽帧，每条给 PASS/FAIL 与一句证据。",
            "规范 subject/style：" + str(spec.get("subject") or spec.get("style")),
        ]
        if spec.get("kind") == "science":
            lines += ["理想化假设：" + "; ".join(spec.get("assumptions", [])),
                      "事实核查清单（逐条判真伪）："] + [f"  {i+1}. {f}" for i, f in enumerate(spec.get("facts", []))]
        else:
            lines += ["风格锚：" + str(spec.get("style")),
                      "调色板：" + str(spec.get("palette", [])),
                      "节拍表："] + [f"  {b.get('at')}s {b.get('what')}" for b in spec.get("beats", [])]
        print("[环③ 评审提示词]")
        print("\n".join(lines))
    return 0


def ast_parse(src: str):
    import ast as _ast
    try:
        return _ast.parse(src, mode="eval")
    except SyntaxError as exc:
        raise RenderRejected(f"expr_syntax_error: {src!r} ({exc.msg})") from exc


def ast_walk_names(tree):
    import ast as _ast
    for node in _ast.walk(tree):
        if isinstance(node, _ast.Name):
            yield node


if __name__ == "__main__":
    raise SystemExit(main())
