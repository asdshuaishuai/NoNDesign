#!/usr/bin/env python3
"""视频示例的黄金对照（批次 08）。

为什么需要它：视频本地面（`app/lib/core/video_service.dart`）把旧管线的
spec 硬门、expr 符号闭包与逐帧 SVG 整体搬到了 Dart。这类“看起来一样”的
移植最容易死在细节上（`%` 的符号、`//` 的取整、动画因子、百分比解析），
所以这里用**独立实现**对同一份示例资产再算一遍，并（在旧参考实现还在时）
逐帧比对两边的 SVG。

做三件事：
  1. 资产形状与规范硬门：每个示例都要有 timeline + 规范文件，`spec` 字段
     指向的正是随包的那份；规范按 science/screenplay 两条线校验必填项。
  2. 算式符号闭包：时间线里所有 `{"expr": ...}` 只允许 t/T/参数/公式/pi/e
     与数学函数白名单（stdlib ast，不依赖任何第三方包）。
  3. 黄金数字：片长与帧数必须等于下表（与 Dart 测试
     `video_service_test.dart` 的锚点同一组数字）。

当 `plugins/video-engine/render.py` 还在时（Python 退场前），额外做第 4 步：
  `dart run app/test/fixtures/video/dump_frames.dart` 导出的逐帧 SVG 与
  Python 参考实现在同一组时间点上逐 token 比对（数值容差 1e-6）。
参考实现被删除后这一步会明确报告 SKIP（视频的确定性由 Dart 侧测试与真机
出片承担），而不是伪装成通过。

用法：
  python3 scripts/wf/video_golden_check.py
  python3 scripts/wf/video_golden_check.py --dart-json /tmp/dart-video-dump.json
  python3 scripts/wf/video_golden_check.py --skip-parity

退出码：0 = 通过或显式跳过，1 = 不一致，2 = 无法运行（资产/工具缺失）。
"""

from __future__ import annotations

import argparse
import ast
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SAMPLES_DIR = ROOT / "app" / "assets" / "video" / "sample"
DART_ENTRY = ROOT / "app" / "test" / "fixtures" / "video" / "dump_frames.dart"
REFERENCE_RENDER = ROOT / "plugins" / "video-engine" / "render.py"

# 与 app/test/video_service_test.dart 的锚点同一组数字。
GOLDEN = {
    "physics-friction": {"fps": 30, "seconds": 8.0, "frames": 240, "size": (1280, 720), "spec": "spec.json"},
    "bio-mitosis": {"fps": 30, "seconds": 10.0, "frames": 300, "size": (1280, 720), "spec": "spec.json"},
    "art-sketch": {"fps": 30, "seconds": 5.0, "frames": 150, "size": (1280, 720), "spec": "screenplay.json"},
}

FUNCS = {
    "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sqrt",
    "abs", "min", "max", "floor", "ceil", "log", "exp", "pow",
    "radians", "degrees",
}
CONSTS = {"pi", "e"}
FORBIDDEN_NODES = (
    ast.Attribute, ast.Subscript, ast.Lambda, ast.ListComp,
    ast.DictComp, ast.SetComp, ast.GeneratorExp, ast.NamedExpr,
    ast.Compare, ast.BoolOp, ast.IfExp,
)


class Problem(Exception):
    """一条可读的失败原因（由 main 汇总成 exit 1）。"""


def fail(message: str) -> None:
    raise Problem(message)


def load_sample(sample_id: str) -> tuple[dict, dict, Path]:
    directory = SAMPLES_DIR / sample_id
    timeline_path = directory / "timeline.json"
    if not timeline_path.exists():
        fail(f"{sample_id}: 缺少 timeline.json")
    timeline = json.loads(timeline_path.read_text("utf-8"))
    spec_name = timeline.get("spec")
    if not isinstance(spec_name, str) or not spec_name.strip():
        fail(f"{sample_id}: timeline 缺少 spec 字段")
    spec_path = directory / spec_name
    if not spec_path.exists():
        fail(f"{sample_id}: spec 指向的 {spec_name} 不存在")
    spec = json.loads(spec_path.read_text("utf-8"))
    return timeline, spec, spec_path


def check_spec_gate(sample_id: str, spec: dict) -> None:
    kind = spec.get("kind")
    if kind == "science":
        for field in ("subject", "laws", "assumptions", "facts"):
            value = spec.get(field)
            if value is None or (isinstance(value, str) and not value.strip()) or (
                isinstance(value, list) and not value
            ):
                fail(f"{sample_id}: science 规范缺少非空 {field}")
        for field in ("laws", "assumptions", "facts"):
            if not isinstance(spec.get(field), list):
                fail(f"{sample_id}: {field} 必须是数组")
        params = spec.setdefault("params", {})
        if not isinstance(params, dict):
            fail(f"{sample_id}: params 必须是对象")
        for name, value in params.items():
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                fail(f"{sample_id}: params.{name} 必须是数字")
        for formula in spec.get("formulas", []):
            if not isinstance(formula, dict) or not formula.get("name") or not formula.get("expr"):
                fail(f"{sample_id}: formulas 每条需要 name+expr")
    elif kind == "screenplay":
        if not spec.get("style"):
            fail(f"{sample_id}: 剧本规范缺少 style")
        if not spec.get("beats"):
            fail(f"{sample_id}: 剧本规范缺少 beats")
        spec.setdefault("params", {})
        spec.setdefault("formulas", [])
    else:
        fail(f"{sample_id}: kind 必须是 science | screenplay")


def collect_exprs(value) -> list[str]:
    out: list[str] = []
    if isinstance(value, dict):
        expr = value.get("expr")
        if isinstance(expr, str):
            out.append(expr)
        for child in value.values():
            out.extend(collect_exprs(child))
    elif isinstance(value, list):
        for child in value:
            out.extend(collect_exprs(child))
    return out


def check_symbol_closure(sample_id: str, timeline: dict, spec: dict) -> None:
    params = spec.get("params", {}) or {}
    formulas = {f.get("name") for f in spec.get("formulas", []) if isinstance(f, dict)}
    allowed = {"t", "T"} | set(params) | formulas | CONSTS
    sources = collect_exprs(timeline.get("scenes", []))

    for formula in spec.get("formulas", []):
        if isinstance(formula, dict) and isinstance(formula.get("expr"), str):
            sources.append(formula["expr"])

    undeclared: set[str] = set()
    for source in sources:
        try:
            tree = ast.parse(source, mode="eval")
        except SyntaxError as exc:
            fail(f"{sample_id}: 算式语法错误 {source!r}（{exc.msg}）")
        for node in ast.walk(tree):
            if isinstance(node, FORBIDDEN_NODES):
                fail(f"{sample_id}: 算式含禁用结构 {source!r}")
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                if node.func.id not in FUNCS:
                    fail(f"{sample_id}: 算式用了未知函数 {node.func.id}")
        names = {node.id for node in ast.walk(tree) if isinstance(node, ast.Name)}
        undeclared |= {name for name in names if name not in allowed and name not in FUNCS}
    if undeclared:
        fail(f"{sample_id}: 未声明符号 {sorted(undeclared)}")


def total_seconds(timeline: dict) -> float:
    return sum(float(scene.get("duration", 0)) for scene in timeline.get("scenes", []))


def check_golden(sample_id: str, timeline: dict) -> None:
    expected = GOLDEN[sample_id]
    fps = int(timeline.get("fps", 30))
    width = int(timeline.get("width", 1280))
    height = int(timeline.get("height", 720))
    total = total_seconds(timeline)
    frames = int(total * fps)
    if fps != expected["fps"]:
        fail(f"{sample_id}: fps {fps} != 黄金值 {expected['fps']}")
    if (width, height) != expected["size"]:
        fail(f"{sample_id}: 尺寸 {(width, height)} != 黄金值 {expected['size']}")
    if not math.isclose(total, expected["seconds"], abs_tol=1e-9):
        fail(f"{sample_id}: 片长 {total} != 黄金值 {expected['seconds']}")
    if frames != expected["frames"]:
        fail(f"{sample_id}: 帧数 {frames} != 黄金值 {expected['frames']}")


# ---------------------------------------------------------------------------
# 与 Python 参考实现的逐帧比对
# ---------------------------------------------------------------------------

TOKEN = re.compile(r'<(/?)([a-zA-Z]+)((?:\s+[a-zA-Z_:-]+="[^"]*")*)\s*(/?)>|([^<]+)')
ATTR = re.compile(r'([a-zA-Z_:-]+)="([^"]*)"')
NUMBER = re.compile(r"^-?\d+(?:\.\d+)?$")


def tokenize_svg(svg: str) -> list[tuple]:
    tokens: list[tuple] = []
    for match in TOKEN.finditer(svg):
        if match.group(2):
            attrs = [(a.group(1), a.group(2)) for a in ATTR.finditer(match.group(3) or "")]
            tokens.append(("tag", match.group(1) != "", match.group(2), attrs))
        else:
            text = (match.group(5) or "").strip()
            if text:
                tokens.append(("text", text))
    return tokens


def values_close(a: str, b: str, tol: float = 1e-6) -> bool:
    a, b = a.strip(), b.strip()
    if a == b:
        return True
    if NUMBER.match(a) and NUMBER.match(b):
        return math.isclose(float(a), float(b), rel_tol=1e-9, abs_tol=tol)
    if "," in a and "," in b:  # points="x,y x,y"
        pairs_a = [p.split(",") for p in a.split()]
        pairs_b = [p.split(",") for p in b.split()]
        if len(pairs_a) != len(pairs_b):
            return False
        return all(
            all(pa.strip() == pb.strip() or values_close(pa.strip(), pb.strip(), tol) for pa, pb in zip(pair_a, pair_b))
            for pair_a, pair_b in zip(pairs_a, pairs_b)
        )
    return False


def compare_svg(reference: str, dart: str) -> list[str]:
    left, right = tokenize_svg(reference), tokenize_svg(dart)
    if len(left) != len(right):
        return [f"token 数 {len(left)} != {len(right)}"]
    problems: list[str] = []
    for index, (a, b) in enumerate(zip(left, right)):
        if a[0] != b[0]:
            problems.append(f"#{index} 类型 {a[0]} != {b[0]}")
            continue
        if a[0] == "text":
            if a[1] != b[1]:
                problems.append(f"#{index} 文本 {a[1]!r} != {b[1]!r}")
            continue
        if a[1] != b[1] or a[2] != b[2]:
            problems.append(f"#{index} 标签 {a[1:3]!r} != {b[1:3]!r}")
            continue
        if len(a[3]) != len(b[3]):
            problems.append(f"#{index} <{a[2]}> 属性数 {len(a[3])} != {len(b[3])}")
            continue
        for (name_a, value_a), (name_b, value_b) in zip(a[3], b[3]):
            if name_a != name_b:
                problems.append(f"#{index} <{a[2]}> 属性名 {name_a} != {name_b}")
            elif not values_close(value_a, value_b):
                problems.append(f"#{index} <{a[2]} {name_a}> {value_a!r} != {value_b!r}")
    return problems


def reference_frame_svgs(sample_id: str, times: list[float]) -> list[str]:
    sys.path.insert(0, str(ROOT / "plugins" / "video-engine"))
    import render  # noqa: E402  （参考实现还在时才导入）

    timeline, spec, spec_path = load_sample(sample_id)
    render._TIMELINE_DIR = spec_path.parent.resolve()
    render._EXPR_SYM.clear()
    allowed = {"t", "T"} | set(spec.get("params", {}) or {}) | {
        f["name"] for f in spec.get("formulas", []) if isinstance(f, dict) and f.get("name")
    } | set(render._CONSTS)
    render._EXPR_SYM.update(allowed)
    render._EXPR_CACHE.clear()
    formulas = {f["name"]: render.Expr(f["expr"], allowed) for f in spec.get("formulas", [])}
    env = dict(spec.get("params", {}) or {})
    for name, expr in formulas.items():
        if expr.symbols & {"t", "T"}:
            env[name] = expr
        else:
            env[name] = expr.eval({**env, "t": 0.0, "T": 0.0})
    width = int(timeline.get("width", 1280))
    height = int(timeline.get("height", 720))

    def resolve(value, t: float, T: float, current: dict, axis: str = "x") -> float:
        if isinstance(value, render.Expr):
            scope = dict(current)
            scope["t"] = t
            scope["T"] = T
            return value.eval(scope)
        if isinstance(value, str):
            if value.endswith("%"):
                return (width if axis == "x" else height) * float(value[:-1]) / 100
            if value in ("center", "middle"):
                return (width if axis == "x" else height) / 2
            try:
                return float(value)
            except ValueError:
                return 0.0
        return float(value)

    return [render.frame_svg(timeline, t, env, resolve) for t in times]


def find_dart() -> str | None:
    candidate = shutil.which("dart")
    if candidate:
        return candidate
    fallback = Path(os.environ.get("HOME", "")) / ".flutter_sdk" / "bin" / "dart"
    return str(fallback) if fallback.exists() else None


def dart_dump(path: str | None) -> dict:
    if path:
        return json.loads(Path(path).read_text("utf-8"))
    dart = find_dart()
    if not dart:
        fail("找不到 dart 可执行文件（用 --dart-json 传入已生成的导出）")
    output = Path(tempfile.mkdtemp(prefix="video-golden-")) / "dart-video.json"
    result = subprocess.run(
        [dart, "run", str(DART_ENTRY), "--out", str(output)],
        cwd=str(ROOT / "app"),
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        fail(f"dart 导出失败：{result.stderr.strip()[:400]}")
    return json.loads(output.read_text("utf-8"))


def check_parity(dump: dict) -> list[str]:
    problems: list[str] = []
    for sample in dump.get("samples", []):
        sample_id = sample["id"]
        times = [entry["t"] for entry in sample.get("frame_svgs", [])]
        if not times:
            continue
        reference = reference_frame_svgs(sample_id, times)
        for entry, expected in zip(sample.get("frame_svgs", []), reference):
            diffs = compare_svg(expected, entry.get("svg", ""))
            for diff in diffs[:6]:
                problems.append(f"{sample_id} t={entry['t']}: {diff}")
    return problems


# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dart-json", help="复用已生成的 Dart 导出（跳过 dart run）")
    parser.add_argument("--skip-parity", action="store_true", help="只做资产/黄金数字检查")
    args = parser.parse_args()

    if not SAMPLES_DIR.exists():
        print(f"[video-golden] cannot run: {SAMPLES_DIR} 不存在", file=sys.stderr)
        return 2

    problems: list[str] = []
    for sample_id in GOLDEN:
        try:
            timeline, spec, _ = load_sample(sample_id)
            check_spec_gate(sample_id, spec)
            check_symbol_closure(sample_id, timeline, spec)
            check_golden(sample_id, timeline)
            print(
                f"[video-golden] {sample_id}: OK "
                f"({GOLDEN[sample_id]['seconds']}s × {GOLDEN[sample_id]['fps']}fps "
                f"= {GOLDEN[sample_id]['frames']} 帧)"
            )
        except Problem as problem:
            problems.append(str(problem))
        except (json.JSONDecodeError, KeyError, TypeError) as error:
            problems.append(f"{sample_id}: 资产解析失败 {error}")

    if problems:
        print("[video-golden] FAIL")
        for problem in problems:
            print(f"  ✗ {problem}")
        return 1

    if args.skip_parity:
        print("[video-golden] parity SKIP（--skip-parity）")
        return 0

    if not REFERENCE_RENDER.exists():
        print(
            "[video-golden] parity SKIP：Python 参考实现已退场"
            "（逐帧确定性由 app/test/video_service_test.dart 与真机出片承担）"
        )
        return 0

    try:
        dump = dart_dump(args.dart_json)
        parity = check_parity(dump)
    except Problem as problem:
        print(f"[video-golden] parity FAIL: {problem}", file=sys.stderr)
        return 2
    except Exception as error:  # noqa: BLE001 - 参考实现的任何异常都算无法运行
        print(f"[video-golden] parity cannot run: {error}", file=sys.stderr)
        return 2

    if parity:
        print(f"[video-golden] parity FAIL（{len(parity)} 处差异）")
        for diff in parity[:20]:
            print(f"  ✗ {diff}")
        return 1

    print("[video-golden] parity OK：Dart 逐帧 SVG 与 Python 参考一致（数值容差 1e-6）")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001
        print(f"[video-golden] unexpected: {error}", file=sys.stderr)
        raise SystemExit(2)
