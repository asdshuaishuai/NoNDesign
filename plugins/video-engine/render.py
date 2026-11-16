#!/usr/bin/env python3
"""代码生成视频渲染器 v2 —— timeline JSON → 逐帧 SVG → resvg PNG → ffmpeg mp4。

双强制纪律（管线硬门，不是提示词约定）：
1. spec_missing 硬门：timeline 必须携带 spec（science-spec 或
   screenplay-spec），缺失或不达标直接拒绝渲染（exit 2）。规范/剧本先行。
2. 符号声明硬门：expr 表达式里出现的自定义标识符必须来自
   spec.params ∪ spec.formulas（外加内建 t/T/pi/e）——「想当然」的
   裸坐标/裸常数进不来，未声明即 undeclared_symbol 拒绝。

确定性：同 (timeline, spec) 永远出同一片。所有表达式在渲染开始前
一次性预编译（fail-closed：语法/符号错误在第一帧之前报干净）。
光栅化链：resvg → rsvg-convert → cairosvg。
"""
from __future__ import annotations

import ast
import json
import math
import shutil
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------- spec 门


class RenderRejected(Exception):
    """管线硬门拒绝（exit 2）：spec 缺失/不达标/表达式未声明等。"""


def load_spec(timeline_path: Path, tl: dict) -> dict:
    """读取并校验 spec。双形态：science（教育）| screenplay（艺术）。"""
    ref = tl.get("spec")
    if not ref or not isinstance(ref, str):
        raise RenderRejected("spec_missing: timeline 必须携带 spec 字段（规范/剧本先行，管线硬门）")
    spec_path = (timeline_path.parent / ref).resolve()
    if not spec_path.exists():
        raise RenderRejected(f"spec_missing: {spec_path} 不存在")
    try:
        spec = json.loads(spec_path.read_text("utf-8"))
    except json.JSONDecodeError as exc:
        raise RenderRejected(f"spec_invalid: JSON 解析失败 {exc}") from exc
    kind = spec.get("kind")
    if kind == "science":
        for field in ("subject", "laws", "assumptions", "facts"):
            v = spec.get(field)
            if not v or (isinstance(v, list) and len(v) == 0):
                raise RenderRejected(f"spec_invalid: science spec 缺少非空 {field}")
        for field in ("laws", "assumptions", "facts"):
            if not isinstance(spec.get(field), list):
                raise RenderRejected(f"spec_invalid: {field} 必须是数组")
        spec.setdefault("params", {})
        if not isinstance(spec["params"], dict):
            raise RenderRejected("spec_invalid: params 必须是对象")
        for name, val in spec["params"].items():
            if not isinstance(val, (int, float)):
                raise RenderRejected(f"spec_invalid: params.{name} 必须是数字（量纲请写进 note，不放单位后缀）")
        for f in spec.get("formulas", []):
            if not f.get("name") or not f.get("expr"):
                raise RenderRejected("spec_invalid: formulas 每条需要 name+expr")
    elif kind == "screenplay":
        if not spec.get("style"):
            raise RenderRejected("spec_invalid: screenplay spec 缺少 style")
        if not spec.get("beats"):
            raise RenderRejected("spec_invalid: screenplay spec 缺少 beats")
        spec.setdefault("params", {})
        spec.setdefault("formulas", [])
    else:
        raise RenderRejected("spec_invalid: kind 必须是 science | screenplay")
    return spec


# ---------------------------------------------------------------- expr 求值

# math 白名单：函数 + 常量。其余一切（属性访问/下标/lambda/推导式）fail-closed。
_FUNCS = {
    "sin": math.sin, "cos": math.cos, "tan": math.tan,
    "asin": math.asin, "acos": math.acos, "atan": math.atan, "atan2": math.atan2,
    "sqrt": math.sqrt, "abs": abs, "min": min, "max": max,
    "floor": math.floor, "ceil": math.ceil, "log": math.log, "exp": math.exp,
    "pow": math.pow, "radians": math.radians, "degrees": math.degrees,
}
_CONSTS = {"pi": math.pi, "e": math.e}


def _collect_names(node: ast.AST, into: list[str]) -> None:
    if isinstance(node, ast.Name):
        into.append(node.id)
    for child in ast.iter_child_nodes(node):
        _collect_names(child, into)


class Expr:
    """预编译的表达式（fail-closed：语法/符号错误在渲染第一帧前报干净）。"""

    __slots__ = ("src", "tree", "symbols")

    def __init__(self, src: str, allowed_symbols: set[str]):
        self.src = src
        self.symbols: set[str] = set()
        try:
            tree = ast.parse(src, mode="eval")
        except SyntaxError as exc:
            raise RenderRejected(f"expr_syntax_error: {src!r} ({exc.msg})") from exc
        for bad in (ast.Attribute, ast.Subscript, ast.Lambda, ast.ListComp,
                    ast.DictComp, ast.SetComp, ast.GeneratorExp, ast.NamedExpr):
            if any(isinstance(n, bad) for n in ast.walk(tree)):
                raise RenderRejected(f"expr_forbidden_construct: {src!r} 只允许算术/函数调用")
        names: list[str] = []
        _collect_names(tree, names)
        func_names = {n.func.id for n in ast.walk(tree)
                      if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
        for fn in func_names:
            if fn not in _FUNCS:
                raise RenderRejected(f"expr_unknown_function: {fn} 不在白名单")
        undeclared = sorted({n for n in names if n not in allowed_symbols and n not in _FUNCS})
        if undeclared:
            raise RenderRejected(
                f"undeclared_symbol: {','.join(undeclared)} 不在 spec.params ∪ spec.formulas ∪ 内建({sorted(allowed_symbols)}) —— 请先在 spec 里声明")
        # symbols 含函数名无妨（t/T 不会是函数名）；用于判断公式是否时间相关
        self.symbols = set(names)
        self.tree = tree

    def eval(self, env: dict) -> float:
        # 值域收口（fail-closed 兑现：除零/负数开方/log(0) 等裸 Python 异常
        # 不允许在渲染中段以 traceback 崩掉（exit 1），一律转 RenderRejected
        # exit 2 干净拒绝；复数/inf 不能进 SVG 坐标属性）。
        try:
            v = self._eval(self.tree.body, env)
        except (ZeroDivisionError, ValueError, OverflowError) as exc:
            raise RenderRejected(f"expr_domain_error: {self.src!r}: {exc}") from exc
        if isinstance(v, complex) or not math.isfinite(v):
            raise RenderRejected(f"expr_domain_error: {self.src!r} 产出 {v!r}（复数/非有限值）")
        return v

    def _eval(self, node: ast.AST, env: dict) -> float:
        if isinstance(node, ast.Expression):
            return self._eval(node.body, env)
        if isinstance(node, ast.Constant):
            if isinstance(node.value, (int, float)) and not isinstance(node.value, bool):
                return float(node.value)
            raise RenderRejected(f"expr_bad_constant: {node.value!r}")
        if isinstance(node, ast.Name):
            if node.id in env:
                v = env[node.id]
                # 时间相关公式存的是 Expr（求值期展开，绝不在 T=0 冻结）
                return v.eval(env) if isinstance(v, Expr) else float(v)
            if node.id in _CONSTS:
                return float(_CONSTS[node.id])
            raise RenderRejected(f"undeclared_symbol: {node.id}")
        if isinstance(node, ast.BinOp):
            l, r = self._eval(node.left, env), self._eval(node.right, env)
            op = type(node.op)
            if op is ast.Add:
                return l + r
            if op is ast.Sub:
                return l - r
            if op is ast.Mult:
                return l * r
            if op is ast.Div:
                if r == 0:
                    raise RenderRejected(f"expr_domain_error: 除零 in {self.src!r}")
                return l / r
            if op is ast.Pow:
                if l < 0 and r != int(r):
                    raise RenderRejected(f"expr_domain_error: 负底数非整数指数 in {self.src!r}")
                v = l ** r
                if isinstance(v, complex) or not math.isfinite(v):
                    raise RenderRejected(f"expr_domain_error: {self.src!r} 产出 {v!r}（复数/非有限值）")
                return v
            if op is ast.Mod:
                if r == 0:
                    raise RenderRejected(f"expr_domain_error: 模零 in {self.src!r}")
                return l % r
            if op is ast.FloorDiv:
                if r == 0:
                    raise RenderRejected(f"expr_domain_error: 除零 in {self.src!r}")
                return l // r
            raise RenderRejected(f"expr_forbidden_operator: {op.__name__}")
        if isinstance(node, ast.UnaryOp):
            v = self._eval(node.operand, env)
            return -v if isinstance(node.op, ast.USub) else (+v if isinstance(node.op, ast.UAdd) else v)
        if isinstance(node, ast.Call):
            fn = _FUNCS[node.func.id]  # 白名单已在预编译校验
            return float(fn(*[self._eval(a, env) for a in node.args]))
        raise RenderRejected(f"expr_forbidden_construct: {type(node).__name__}")


def _maybe_expr(v, allowed: set[str], cache: dict) -> object:
    """数值或 {'expr': ...}；expr 返回预编译 Expr（进入 cache 供预检）。"""
    if isinstance(v, dict) and "expr" in v:
        key = v["expr"]
        if key not in cache:
            cache[key] = Expr(key, allowed)
        return cache[key]
    return v


# ---------------------------------------------------------------- 动画因子


def _anim_factor(anim, t_scene: float):
    """入场动画因子 → (alpha, dy, scale)。fade/rise/pop，easeOutCubic。"""
    if not anim:
        return 1.0, 0.0, 1.0
    dur = float(anim.get("dur", 0.5))
    delay = float(anim.get("delay", 0.0))
    local = t_scene - delay
    if local < 0:
        return 0.0, 0.0, 1.0
    p = min(1.0, local / dur) if dur > 0 else 1.0
    ease = 1 - (1 - p) ** 3
    kind = anim.get("in", "fade")
    if kind == "rise":
        return ease, (1 - ease) * 40, 1.0
    if kind == "pop":
        return ease, 0.0, 0.6 + 0.4 * ease + (0.08 * math.sin(ease * math.pi) if ease < 1 else 0)
    return ease, 0.0, 1.0  # fade / 未知 → 按 fade


def _motion_offset(motion, t_scene: float, T: float, env_static: dict, resolve) -> tuple[float, float, bool]:
    """持续运动 → (mx, my, absolute)。

    - linear：加性偏移（vx*t, vy*t 叠加到元素坐标）。
    - orbit：元素绕**屏幕点** (cx, cy) 转圈，返回绝对位置（元素自身 x/y 被
      orbit 完全决定——此前是加性语义，按自然读法写会把元素甩出画外，
      真机复现 cx=1380 出画后改为绝对语义；现无示例依赖旧行为，零破坏）。
    - path：元素沿**屏幕坐标**折线走，返回绝对位置（同上改绝对语义）。
    """
    if not motion:
        return 0.0, 0.0, False
    kind = motion.get("type", "linear")
    if kind == "linear":
        vx = resolve(_maybe_expr(motion.get("vx", 0), _EXPR_SYM, _EXPR_CACHE), t_scene, T, env_static)
        vy = resolve(_maybe_expr(motion.get("vy", 0), _EXPR_SYM, _EXPR_CACHE), t_scene, T, env_static)
        return vx * t_scene, vy * t_scene, False
    if kind == "orbit":
        cx = resolve(_maybe_expr(motion.get("cx", 0), _EXPR_SYM, _EXPR_CACHE), t_scene, T, env_static)
        cy = resolve(_maybe_expr(motion.get("cy", 0), _EXPR_SYM, _EXPR_CACHE), t_scene, T, env_static)
        r = resolve(_maybe_expr(motion.get("r", 50), _EXPR_SYM, _EXPR_CACHE), t_scene, T, env_static)
        omega = resolve(_maybe_expr(motion.get("omega", 1), _EXPR_SYM, _EXPR_CACHE), t_scene, T, env_static)
        a = omega * t_scene
        return cx + r * math.cos(a), cy + r * math.sin(a), True
    if kind == "path":
        pts = motion.get("points") or []
        if len(pts) < 2:
            return 0.0, 0.0, False
        speed = resolve(_maybe_expr(motion.get("speed", 100), _EXPR_SYM, _EXPR_CACHE), t_scene, T, env_static)
        dist = speed * t_scene
        acc = 0.0
        for i in range(len(pts) - 1):
            x1, y1 = float(pts[i][0]), float(pts[i][1])
            x2, y2 = float(pts[i + 1][0]), float(pts[i + 1][1])
            seg = math.hypot(x2 - x1, y2 - y1)
            if acc + seg >= dist:
                f = (dist - acc) / seg if seg > 0 else 0
                return x1 + (x2 - x1) * f, y1 + (y2 - y1) * f, True
            acc += seg
        return float(pts[-1][0]), float(pts[-1][1]), True
    return 0.0, 0.0, False


# ---------------------------------------------------------------- 元素渲染

_EXPR_CACHE: dict[str, Expr] = {}
_EXPR_SYM: set[str] = set()  # 渲染前由 prepare 填充
_TIMELINE_DIR: Path = Path(".")  # image 相对路径的解析基准（main() 设置）


def _esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _element_svg(el, t_scene: float, T: float, env: dict, resolve) -> str:
    alpha, dy, scale = _anim_factor(el.get("anim"), t_scene)
    mx, my, motion_absolute = _motion_offset(el.get("motion"), t_scene, T, env, resolve)
    if alpha <= 0.01:
        return ""
    kind = el.get("type")
    color = str(el.get("color", "#FFFFFF"))
    opacity = float(el.get("opacity", 1.0)) * alpha
    parts = [f'opacity="{opacity:.3f}"']

    def px(v, axis, size=False):
        # 位置/尺寸语义拆分：orbit/path（motion_absolute）完全决定位置——
        # 元素自身 x/y/cx/cy/线段端点/锚点返回 0（由 mx/my 接管）；尺寸类
        # （w/h/r/rx/ry，size=True）恒解析——绝对运动只接管锚点，不清元素
        # 尺寸（此前整条表达式归零，元素渲染成零尺寸隐形）。
        val = resolve(_maybe_expr(v, _EXPR_SYM, _EXPR_CACHE), t_scene, T, env, axis)
        return 0.0 if (motion_absolute and not size) else val

    if kind == "text":
        x = px(el.get("x", "50%"), "x") + mx
        y = px(el.get("y", "50%"), "y") + dy + my
        size = float(el.get("size", 32)) * scale
        anchor = el.get("anchor", "middle")
        weight = el.get("weight", "600")
        fam = el.get("font", "PingFang SC")
        if "textValue" in el:
            tv = el["textValue"]
            expr_src = tv.get("expr") if isinstance(tv, dict) else None
            if not expr_src:
                raise RenderRejected("spec_invalid: textValue 需要 expr")
            val = resolve(_maybe_expr({"expr": expr_src}, _EXPR_SYM, _EXPR_CACHE), t_scene, T, env)
            fmt = tv.get("format", "{:.2f}")
            content = _esc(fmt.format(val))
        else:
            content = _esc(str(el.get("text", "")))
        parts.append(f'font-family="{fam}" font-size="{size:.1f}" fill="{color}"'
                     f' text-anchor="{anchor}" font-weight="{weight}"')
        return f'<text x="{x:.1f}" y="{y:.1f}" {" ".join(parts)}>{content}</text>'

    if kind == "rect":
        x = px(el.get("x", 0), "x") + mx
        y = px(el.get("y", 0), "y") + my  # motion 纵向分量（vy/orbit-cy/path）与其余元素类型同语义
        w = px(el.get("w", 100), "x", size=True) * scale
        h = px(el.get("h", 60), "y", size=True) * scale
        cx, cy = x + w / 2, y + h / 2  # 缩放绕中心，x/y = 左上角
        rx = float(el.get("radius", 8))
        body = (f'<rect x="{cx - w/2:.1f}" y="{cy + dy - h/2:.1f}"'
                f' width="{w:.1f}" height="{h:.1f}" rx="{rx:.1f}" fill="{color}"/>')
        return f'<g {" ".join(parts)}>{body}</g>'

    if kind == "circle":
        cx = px(el.get("cx", "50%"), "x") + mx
        cy = px(el.get("cy", "50%"), "y") + dy + my
        r = px(el.get("r", 40), "x", size=True) * scale
        return f'<g {" ".join(parts)}><circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="{color}"/></g>'

    if kind == "ellipse":
        cx = px(el.get("cx", "50%"), "x") + mx
        cy = px(el.get("cy", "50%"), "y") + dy + my
        rx = px(el.get("rx", 50), "x", size=True) * scale
        ry = px(el.get("ry", 30), "y", size=True) * scale
        return f'<g {" ".join(parts)}><ellipse cx="{cx:.1f}" cy="{cy:.1f}" rx="{rx:.1f}" ry="{ry:.1f}" fill="{color}"/></g>'

    if kind == "line":
        x1 = px(el.get("x1", 0), "x") + mx
        y1 = px(el.get("y1", 0), "y") + dy + my
        x2 = px(el.get("x2", 100), "x") + mx
        y2 = px(el.get("y2", 0), "y") + dy + my
        sw = float(el.get("stroke_width", 2)) * scale
        return (f'<g {" ".join(parts)}><line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}"'
                f' stroke="{color}" stroke-width="{sw:.1f}" stroke-linecap="round"/></g>')

    if kind == "arrow":
        x1 = px(el.get("x1", 0), "x") + mx
        y1 = px(el.get("y1", 0), "y") + dy + my
        x2 = px(el.get("x2", 100), "x") + mx
        y2 = px(el.get("y2", 0), "y") + dy + my
        sw = float(el.get("stroke_width", 3)) * scale
        head = float(el.get("head", 14)) * scale
        ang = math.atan2(y2 - y1, x2 - x1)
        bx, by = x2 - head * math.cos(ang), y2 - head * math.sin(ang)
        per = ang + math.pi / 2
        p1x, p1y = bx + head * 0.42 * math.cos(per), by + head * 0.42 * math.sin(per)
        p2x, p2y = bx - head * 0.42 * math.cos(per), by - head * 0.42 * math.sin(per)
        body = (f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{bx:.1f}" y2="{by:.1f}"'
                f' stroke="{color}" stroke-width="{sw:.1f}" stroke-linecap="round"/>'
                f'<polygon points="{x2:.1f},{y2:.1f} {p1x:.1f},{p1y:.1f} {p2x:.1f},{p2y:.1f}" fill="{color}"/>')
        return f'<g {" ".join(parts)}>{body}</g>'

    if kind == "polyline":
        pts = el.get("points") or []
        if len(pts) < 2:
            return ""
        coords = []
        for p in pts:
            coords.append((px(p[0], "x") + mx, px(p[1], "y") + dy + my))
        d = " ".join(f"{x:.1f},{y:.1f}" for x, y in coords)
        sw = float(el.get("stroke_width", 2)) * scale
        fill = el.get("fill", "none")
        return (f'<g {" ".join(parts)}><polyline points="{d}" fill="{fill}" stroke="{color}"'
                f' stroke-width="{sw:.1f}" stroke-linecap="round" stroke-linejoin="round"/></g>')

    if kind == "image":
        x = px(el.get("x", 0), "x") + mx
        y = px(el.get("y", 0), "y") + dy + my
        w = px(el.get("w", 200), "x", size=True) * scale
        h = px(el.get("h", 200), "y", size=True) * scale
        path = el.get("path", "")
        if not path:
            return ""
        # 相对路径按 timeline 目录解析（非进程 cwd）——同 timeline 同片，
        # 不随调用目录漂移；缺失 fail-closed（此前静默消失，破坏确定性声明）。
        img_path = Path(path)
        if not img_path.is_absolute():
            img_path = _TIMELINE_DIR / img_path
        if not img_path.exists():
            raise RenderRejected(f"image_missing: {path}（解析为 {img_path}）——元素静默消失会破坏确定性")
        mime = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}.get(
            img_path.suffix.lower(), "image/png")
        import base64
        b64 = base64.b64encode(img_path.read_bytes()).decode()
        return (f'<g {" ".join(parts)}><image x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}"'
                f' href="data:{mime};base64,{b64}" preserveAspectRatio="xMidYMid slice"/></g>')
    return ""


# ---------------------------------------------------------------- 帧与主流程


def frame_svg(tl: dict, t_global: float, env: dict, resolve) -> str:
    W, H = int(tl.get("width", 1280)), int(tl.get("height", 720))
    bg = tl.get("background", "#0B0D12")
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">']
    parts.append(f'<rect width="{W}" height="{H}" fill="{bg}"/>')
    remain = t_global
    for scene in tl.get("scenes", []):
        dur = float(scene.get("duration", 3.0))
        # 浮点容差：t 恰好等于场景结束时刻仍渲染该场景终态（防边界闪黑）。
        if remain > dur + 1e-9:
            remain -= dur
            continue
        t_scene = remain
        sbg = scene.get("background", bg)
        parts.append(f'<rect width="{W}" height="{H}" fill="{sbg}"/>')
        for el in scene.get("elements", []):
            parts.append(_element_svg(el, t_scene, t_global, env, resolve))
        break
    parts.append("</svg>")
    return "".join(parts)


def _rasterize(svg: str, out_png: Path, width: int, height: int) -> None:
    svg_file = out_png.with_suffix(".svg")
    svg_file.write_text(svg, "utf-8")
    for cmd in (
        ["resvg", str(svg_file), str(out_png), "--width", str(width), "--height", str(height)],
        ["rsvg-convert", "-w", str(width), "-h", str(height), "-o", str(out_png), str(svg_file)],
    ):
        exe = shutil.which(cmd[0])
        if exe:
            subprocess.run([exe, *cmd[1:]], check=True)
            return
    try:
        import cairosvg
        cairosvg.svg2png(bytestring=svg.encode("utf-8"), write_to=str(out_png),
                         output_width=width, output_height=height)
    except ImportError as exc:
        raise SystemExit("无可用的 SVG 光栅化器：brew install resvg（推荐）或 pip install cairosvg") from exc


def _collect_exprs(obj, out: list) -> None:
    """深扫 timeline 里全部 {'expr': ...}（含 motion/anim/points/textValue）。"""
    if isinstance(obj, dict):
        if "expr" in obj and isinstance(obj["expr"], str):
            out.append(obj["expr"])
        for v in obj.values():
            _collect_exprs(v, out)
    elif isinstance(obj, list):
        for v in obj:
            _collect_exprs(v, out)


def main() -> int:
    if len(sys.argv) < 3:
        print("用法：render.py timeline.json out_dir [--fps N] [--keep-svg]")
        return 1
    timeline_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    tl = json.loads(timeline_path.read_text("utf-8"))
    global _TIMELINE_DIR
    _TIMELINE_DIR = timeline_path.resolve().parent

    # —— 硬门 1：spec 先行 ——
    spec = load_spec(timeline_path, tl)
    params = spec.get("params", {})
    formulas = {f["name"]: f["expr"] for f in spec.get("formulas", [])}

    # —— 硬门 2：符号声明闭包 ——
    allowed = {"t", "T"} | set(params) | set(formulas) | set(_CONSTS)
    _EXPR_SYM.clear()
    _EXPR_SYM.update(allowed)
    _EXPR_CACHE.clear()
    # spec 公式本身先过同一套白名单（spec 层的想当然也进不来）
    formula_exprs: dict[str, Expr] = {}
    for name, src in formulas.items():
        formula_exprs[name] = Expr(src, allowed)

    if not tl.get("scenes"):
        raise RenderRejected("no_scenes: timeline.scenes 为空——渲染 0 帧只会让 ffmpeg 产出坏片")
    fps = int(sys.argv[sys.argv.index("--fps") + 1]) if "--fps" in sys.argv else int(tl.get("fps", 30))
    keep_svg = "--keep-svg" in sys.argv
    W, H = int(tl.get("width", 1280)), int(tl.get("height", 720))
    total = sum(float(s.get("duration", 0)) for s in tl.get("scenes", []))
    frames = int(total * fps)
    if frames <= 0:
        # scenes 非空但时长全 0 时 no_scenes 门（只查真值）拦不住——
        # 0 帧会让 ffmpeg 在空目录上 check=True 崩（正是该注释声称要防的事）。
        raise RenderRejected("no_frames: scenes 时长全为 0")
    out_dir.mkdir(parents=True, exist_ok=True)

    env_static: dict = dict(params)
    # 公式入 env：纯参数公式按声明顺序求值一次（常量）；含 t/T 的时间相关
    # 公式保持 Expr 求值期展开——在 T=0 冻结会把运动钉死在起点（真 bug：
    # 首版冒烟滑块钉在顶部、读数恒 0.00 即此根因）。
    for name, ex in formula_exprs.items():
        if ex.symbols & {"t", "T"}:
            env_static[name] = ex
        else:
            env_static[name] = ex.eval({**env_static, "t": 0.0, "T": 0.0})

    def resolve(v, t: float, T: float, env: dict, axis: str = "x") -> float:
        """数字 | Expr | '50%'/'center' → 帧时刻浮点值（轴感知）。"""
        if isinstance(v, Expr):
            e = dict(env)
            e["t"] = t
            e["T"] = T
            return v.eval(e)
        if isinstance(v, str):
            if v.endswith("%"):
                total = W if axis == "x" else H
                return total * float(v[:-1]) / 100
            if v in ("center", "middle"):
                return (W if axis == "x" else H) / 2
            try:
                return float(v)
            except ValueError:
                return 0.0
        return float(v)

    # —— 帧前全量预编译：语法/符号错误在第一帧渲染之前报干净（fail-closed）——
    all_exprs: list[str] = []
    _collect_exprs(tl.get("scenes", []), all_exprs)
    for src_expr in all_exprs:
        Expr(src_expr, allowed)

    print(f"spec ok（{spec.get('kind')}）: {spec.get('subject') or spec.get('style')}", flush=True)
    print(f"渲染 {frames} 帧（{total:.1f}s × {fps}fps，{W}×{H}）", flush=True)
    for f in range(frames):
        T = f / fps
        svg = frame_svg(tl, T, env_static, resolve)
        png = out_dir / f"frame_{f:05d}.png"
        _rasterize(svg, png, W, H)
        if not keep_svg:
            png.with_suffix(".svg").unlink(missing_ok=True)
        if f % (fps * 2) == 0:
            print(f"  {f}/{frames}")
    print(f"✓ 帧序列完成：{out_dir}")

    if shutil.which("ffmpeg"):
        mp4 = out_dir.parent / (out_dir.name + ".mp4")
        subprocess.run(["ffmpeg", "-y", "-framerate", str(fps),
                        "-i", str(out_dir / "frame_%05d.png"),
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", str(mp4)], check=True)
        print(f"✓ mp4：{mp4}")
    else:
        print("ffmpeg 未安装：brew install ffmpeg 后执行")
        print(f'  ffmpeg -framerate {fps} -i "{out_dir}/frame_%05d.png" -c:v libx264 -pix_fmt yuv420p demo.mp4')
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RenderRejected as e:
        print(f"REJECTED: {e}", file=sys.stderr)
        raise SystemExit(2)
