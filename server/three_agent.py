"""3D 制作工作台服务（轨道 C，客户端插件能力——与 MoonViz 引擎解耦）。

LLM 生成 three.js `scene.js`，**应用内 WebView 即执行面**（不引外部浏览器
与 headless）：预览页由 `/three/preview/<name>` 实时 serve，执行错误/场景
测量/截图经页面桥回传 `/three/feedback`，驱动修复轮。

img2threejs 纪律（骨架即落）：
- **spec 先行**：先产出 `three-spec.json`（目标/组件清单/材质/相机/验收
  标准），没有 spec 的代码生成请求直接拒绝（fail-closed）。
- **分 pass 雕塑**：blockout → structure → form → material → lighting →
  interaction，每 pass 只解当前层；`build-state.json` 是状态权威——每步
  必须带 evidence 才能推进，禁止从对话记忆重建进度；修复轮上限每 pass
  3 次，超限 blocked（BLOCKED 必须先 refine-spec，不许通用场景糊弄）。
- **确定性反馈先行，vision 殿后**：执行错误（error）与场景测量（metrics）
  是机械反馈；截图（screenshot）落盘 evidence/ 供评审 agent 查看。
  turntable 多方位门与自相交检测在 C2 接入。

scene.js 执行契约（预览页加载）：
  `export default function build(THREE, scene, camera, controls, renderer) { … }
  `——宿主页提供 importmap（three 0.160 CDN）与 OrbitControls；scene.js
  可自由 `import * as THREE from 'three'`（命中宿主 importmap）。返回
  `{ metrics: {...} }` 会被收集为测量反馈。
"""
from __future__ import annotations

import json
import os
import shutil
import tempfile
import time
from pathlib import Path
from typing import Any

import openai
from openai import AsyncOpenAI

THREE_ROOT = Path.home() / "Documents" / "NoNDesign" / "3d"

# pass 序列与各层目标（img2threejs 的锁定 pass 语义：只解当前层）
PASSES: list[dict[str, str]] = [
    {"id": "blockout", "goal": "主几何占位（盒子/球/布局块），相机就位，整体构图可辨识"},
    {"id": "structure", "goal": "组件层级细化：真实几何形状、比例、父子关系（Group 层级）"},
    {"id": "form", "goal": "细节造型：倒角/轮廓/子部件/表面起伏——身份定义特征在这一层"},
    {"id": "material", "goal": "PBR 材质：颜色/roughness/metalness/透明度，按 spec 材质清单"},
    {"id": "lighting", "goal": "灯光与环境：主光/补光/背景色/阴影，服务可读性与氛围"},
    {"id": "interaction", "goal": "动画与交互：自转/轨道/呼吸/点击响应（clock 驱动）"},
]
LOOP_MAX = 3  # 每 pass 修复轮上限（超限 → blocked，须 refine-spec）

PREVIEW_TEMPLATE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>NonDesign 3D · __NAME__</title>
<style>html,body{margin:0;height:100%;overflow:hidden;background:#0b0d12}
#err{position:fixed;top:8px;left:8px;color:#ff8a7a;font:12px monospace;white-space:pre-wrap;max-width:70%;z-index:9}</style>
<script type="importmap">{"imports":{"three":"/three/vendor/three.module.js"}}</script>
</head><body><pre id="err"></pre>
<script>
// —— 执行反馈桥（环①）：一切运行时错误回传 Flutter（JavaScriptChannel NON3D）——
function __report(obj){ try { window.NON3D.postMessage(JSON.stringify(obj)); } catch(e){} }
window.onerror = function(msg, src, line, col){
  document.getElementById('err').textContent = msg + ' @' + line + ':' + col;
  __report({kind:'error', message: String(msg), line: line, col: col});
  return true;
};
window.addEventListener('unhandledrejection', function(e){
  __report({kind:'error', message: 'unhandledrejection: ' + String(e.reason)});
});
</script>
<script type="module">
import * as THREE from 'three';
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x0b0d12);
const camera = new THREE.PerspectiveCamera(45, innerWidth/innerHeight, 0.1, 2000);
camera.position.set(6, 4, 8);
const renderer = new THREE.WebGLRenderer({antialias: true, preserveDrawingBuffer: true});
renderer.setSize(innerWidth, innerHeight);
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
document.body.appendChild(renderer.domElement);
// —— 轨道控制（自实现，零 addons 依赖）：接口兼容 controls.target/update() ——
class MiniOrbit {
  constructor(camera, dom, targetInit) {
    this.target = targetInit;
    this.spherical = { r: 10, theta: Math.atan2(camera.position.x - targetInit.x, camera.position.z - targetInit.z), phi: Math.acos(Math.min(1, Math.max(-1, (camera.position.y - targetInit.y) / Math.max(0.001, camera.position.distanceTo(targetInit))))) };
    this.goal = { ...this.spherical };
    this.pan = targetInit.clone();
    this.panGoal = targetInit.clone();
    let mode = 0, lx = 0, ly = 0;
    dom.addEventListener('contextmenu', (e) => e.preventDefault());
    dom.addEventListener('pointerdown', (e) => { mode = e.button === 2 || e.button === 1 ? 2 : 1; lx = e.clientX; ly = e.clientY; dom.setPointerCapture(e.pointerId); });
    dom.addEventListener('pointermove', (e) => {
      if (!mode) return;
      const dx = e.clientX - lx, dy = e.clientY - ly; lx = e.clientX; ly = e.clientY;
      if (mode === 1) {
        this.goal.theta -= dx * 0.006;
        this.goal.phi = Math.min(Math.PI - 0.05, Math.max(0.05, this.goal.phi - dy * 0.006));
      } else {
        const scale = this.goal.r * 0.0012;
        const right = new THREE.Vector3().setFromMatrixColumn(camera.matrix, 0).multiplyScalar(-dx * scale);
        const up = new THREE.Vector3().setFromMatrixColumn(camera.matrix, 1).multiplyScalar(dy * scale);
        this.panGoal.add(right).add(up);
      }
    });
    dom.addEventListener('pointerup', () => { mode = 0; });
    dom.addEventListener('wheel', (e) => { e.preventDefault(); this.goal.r = Math.min(500, Math.max(0.5, this.goal.r * Math.exp(e.deltaY * 0.0011))); }, { passive: false });
  }
  update() {
    const k = 0.16;
    this.spherical.r += (this.goal.r - this.spherical.r) * k;
    this.spherical.theta += (this.goal.theta - this.spherical.theta) * k;
    this.spherical.phi += (this.goal.phi - this.spherical.phi) * k;
    this.pan.lerp(this.panGoal, k);
    const sp = this.spherical;
    camera.position.set(
      this.pan.x + sp.r * Math.sin(sp.phi) * Math.sin(sp.theta),
      this.pan.y + sp.r * Math.cos(sp.phi),
      this.pan.z + sp.r * Math.sin(sp.phi) * Math.cos(sp.theta),
    );
    camera.lookAt(this.pan);
  }
  // 直写 goal+spherical 绕过阻尼——turntable 四方位等编排路径需要确定性
  // 视角：update() 只从自持 spherical 重建 camera.position（从不读回），
  // 直设 camera.position 会被下一帧 update() 立即覆写回旧视角。
  setView(theta, phi) {
    this.goal.theta = theta;
    this.goal.phi = phi;
    this.spherical.theta = theta;
    this.spherical.phi = phi;
  }
}
const controls = new MiniOrbit(camera, renderer.domElement, new THREE.Vector3(0, 0, 0));
addEventListener('resize', () => {
  camera.aspect = innerWidth/innerHeight; camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight);
});
const clock = new THREE.Clock();
let metrics = {};
let userUpdate = null;
try {
  const mod = await import('/three/scene/__NAME__.js?v=__TS__');
  const ret = mod.default(THREE, scene, camera, controls, renderer);
  if (ret && ret.metrics) metrics = ret.metrics;
  if (ret && ret.update) userUpdate = ret.update;
} catch (e) {
  document.getElementById('err').textContent = String(e);
  __report({kind:'error', message: String(e)});
}
// —— 测量反馈桥（环②）：场景几何自检，随帧回传 ——
function __measure(){
  let meshes = 0, tris = 0;
  scene.traverse(o => { if (o.isMesh) { meshes++; tris += (o.geometry.index ? o.geometry.index.count : o.geometry.attributes.position.count) / 3; } });
  const box = new THREE.Box3().setFromObject(scene);
  const size = box.isEmpty() ? {x:0,y:0,z:0} : box.getSize(new THREE.Vector3());
  return { meshes, triangles: Math.round(tris), bounds: {x:+size.x.toFixed(2), y:+size.y.toFixed(2), z:+size.z.toFixed(2)}, user: metrics };
}
let lastSent = 0;
function __loop(){
  if (userUpdate) { try { userUpdate(clock.getDelta()); } catch(e){} }
  controls.update();
  renderer.render(scene, camera);
  const now = performance.now();
  if (now - lastSent > 2000) { lastSent = now; __report({kind:'metrics', payload: __measure()}); }
}
renderer.setAnimationLoop(__loop);
// —— 视觉反馈桥（环③）：截图给评审 agent（preserveDrawingBuffer 开启）。
// tag 进 evidence 文件名；turntable 四方位取证（img2threejs：单视角不是
// 模型的证据——正面八轮通过、帽子长在胯上的事故即此）。——
window.__non3d_screenshot = function(tag){
  const data = renderer.domElement.toDataURL('image/png');
  __report({kind:'screenshot', payload: data, tag: tag || 'shot'});
};
window.__non3d_turntable = function(){
  if (!window.__non3d_turning) {
    window.__non3d_turning = true;
    // 截图期间暂停动画循环：__loop 每帧 controls.update() 会用阻尼态
    // spherical 重建 camera.position，把直设的取证视角立即覆写回旧值
    // （四张截图同一视角的事故根因——turntable 直设 + update 覆写双败）。
    renderer.setAnimationLoop(null);
    const baseAngle = Math.atan2(camera.position.x - controls.target.x, camera.position.z - controls.target.z);
    const phi0 = controls.spherical.phi; // 保持原仰角与距离，只转方位
    const angles = [0, 90, 180, 270];
    let i = 0;
    const step = () => {
      if (i >= angles.length) {
        controls.setView(baseAngle, phi0);
        renderer.render(scene, camera);
        clock.getDelta(); // 吞掉暂停期的 dt，恢复后用户动画不瞬移
        renderer.setAnimationLoop(__loop);
        window.__non3d_turning = false;
        return;
      }
      const a = baseAngle + angles[i] * Math.PI / 180;
      controls.setView(a, phi0);
      renderer.render(scene, camera);
      __report({kind:'screenshot', payload: renderer.domElement.toDataURL('image/png'), tag: 'turn-' + angles[i]});
      i++;
      setTimeout(step, 150);
    };
    step();
  }
};
setTimeout(() => __report({kind:'metrics', payload: __measure()}), 300);
</script></body></html>"""


class ThreeError(Exception):
    """fail-closed 业务拒绝（端点层转 400）。"""


def _proj_dir(name: str) -> Path:
    # ASCII 白名单（issue three-4）：Python isalnum 对 CJK 也为真，旧过滤曾放行
    # 中文项目名落盘，与错误文案/UI 新建提示「字母数字-下划线」全部矛盾。
    # 名称来自 HTTP body，是不可信字符串——白名单收紧后行为与提示一致。
    safe = "".join(c for c in name if c.isascii() and (c.isalnum() or c in "-_"))
    if not safe or safe != name:
        raise ThreeError(f"invalid_name:{name} —— 只允许字母数字-下划线")
    return THREE_ROOT / safe


def _atomic_write(path: Path, text: str) -> None:
    """同目录临时文件 + fsync + os.replace：写盘永不 truncate 出半截文件
    （对齐 hotapp_agent 的同名纪律——build-state.json 自称状态权威，
    非原子 write_text 一次崩溃就把它写成半截 JSON）。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _initial_state() -> dict[str, Any]:
    return {"current": PASSES[0]["id"],
            "passes": [{"id": p["id"], "status": "pending", "attempts": 0, "evidence": []}
                       for p in PASSES],
            "loop_max": LOOP_MAX, "blocked": False, "blocked_reason": ""}


def read_state(name: str) -> dict[str, Any]:
    d = _proj_dir(name)
    state_file = d / "build-state.json"
    if not state_file.exists():
        raise ThreeError(f"no_project:{name}")
    try:
        state = json.loads(state_file.read_text("utf-8"))
        if not isinstance(state, dict):
            raise ValueError("state is not a JSON object")
    except (json.JSONDecodeError, OSError, ValueError):
        # 半截状态文件（原子写落地前的崩溃残留 / 手编损坏）：备份 .bak 留证据，
        # 重置为初始 pass——不从对话记忆重建进度（那是状态权威纪律），宁可从
        # blockout 重跑；原文件半截内容对推进毫无可信度。
        try:
            os.replace(state_file, state_file.with_name(state_file.name + ".bak"))
        except OSError:
            pass
        state = _initial_state()
        write_state(name, state)
        append_history(name, {"action": "state-corrupt-reset", "pass": "-",
                              "summary": "build-state.json 损坏，已备份 .bak 并重置为初始 pass"})
    return state


def write_state(name: str, state: dict[str, Any]) -> None:
    _atomic_write(_proj_dir(name) / "build-state.json",
                  json.dumps(state, ensure_ascii=False, indent=1))


def append_history(name: str, entry: dict[str, Any]) -> None:
    with (_proj_dir(name) / "history.jsonl").open("a", encoding="utf-8") as f:
        f.write(json.dumps({"ts": time.time(), **entry}, ensure_ascii=False) + "\n")


async def _chat(model: str, base_url: str, api_key: str, thinking: str,
                system: str, user: str) -> str:
    """单轮结构化调用（3D 生成不走设计域的 Agents 循环）。AsyncOpenAI
    原生 await——不能用 to_thread 包 coroutine（无 event loop 会炸）。"""
    client = AsyncOpenAI(api_key=api_key or "missing", base_url=base_url or None)
    kwargs: dict[str, Any] = dict(model=model or "gpt-5.1", temperature=0.4)
    # thinking 方言从简：OpenAI 标准字段直传，兼容网关忽略即可（AGENTS 教训：
    # 响应侧保持宽容，请求侧非标字段只加不删）。
    if thinking and thinking in ("low", "medium", "high"):
        kwargs["extra_body"] = {"reasoning_effort": thinking}
    try:
        resp = await client.chat.completions.create(
            messages=[{"role": "system", "content": system},
                      {"role": "user", "content": user}],
            **kwargs)
    except openai.OpenAIError as e:
        # SDK 全异常族（AuthenticationError/APIConnectionError/…都继承
        # OpenAIError）——此前裸抛直达端点层变 500 "Internal Server Error"
        # 零诊断（issue three-3：401 mock 实测）。包 ThreeError 带类型与
        # 状态码诊断，端点层转 400 可读错误面。
        status = getattr(e, "status_code", None)
        raise ThreeError(
            f"llm_error:{type(e).__name__}:{status if status is not None else '-'}: {str(e)[:300]}"
        ) from e
    if not resp.choices:
        raise ThreeError("llm_error: 响应无 choices（网关返回空补全）")
    return resp.choices[0].message.content or ""


def _extract_json(text: str) -> dict[str, Any]:
    """从回复中提取 JSON（```json 围栏或裸 JSON）。JSONDecodeError 也包
    ThreeError：含花括号的非 JSON 回复此前裸抛直达 500 零诊断（issue three-3）。"""
    text = text.strip()
    if "```" in text:
        for seg in text.split("```"):
            seg = seg.strip()
            if seg.startswith("json"):
                seg = seg[4:]
            if seg.strip().startswith("{"):
                text = seg.strip()
                break
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end <= start:
        raise ThreeError("spec_parse_failed: 模型未返回 JSON")
    try:
        return json.loads(text[start:end + 1])
    except json.JSONDecodeError as e:
        raise ThreeError(
            f"spec_parse_failed: JSON 解析失败（{e.msg} @pos {e.pos}）：{text[start:end + 1][:120]!r}"
        ) from e


def _extract_js(text: str) -> str:
    """从回复中提取 JS 代码（```js 围栏或裸码）。"""
    if "```" in text:
        for seg in text.split("```"):
            seg = seg.strip()
            if seg.startswith(("js", "javascript", "module")):
                seg = seg.split("\n", 1)[1] if "\n" in seg else seg
            if "export default" in seg:
                return seg.strip() + "\n"
    # 裸码：要求回复就是代码本身
    if "export default" in text:
        return text.strip() + "\n"
    raise ThreeError("code_parse_failed: 模型回复不含 export default")


async def new_project(name: str, brief: str, model: str, base_url: str,
                      api_key: str, thinking: str) -> dict[str, Any]:
    """spec 阶段：LLM 产 three-spec.json + 初始 build-state。**没有 spec
    就没有代码**（fail-closed）。"""
    d = _proj_dir(name)
    if d.exists():
        raise ThreeError(f"project_exists:{name}")
    system = (
        "你是 3D 场景规格师。根据 brief 产出 three-spec.json——它是后续分 pass"
        " 生成 three.js 代码的唯一依据（img2threejs 纪律：spec 先行）。只输出 JSON。"
        "字段：title（短名）、summary（一句话）、components[]（每个可辨识组件："
        "{id, what, geometry 提示, material 提示, size_scale 相对尺寸}）、"
        "materials[]（{id, color_hex, roughness, metalness}）、camera（{view 描述}）、"
        "interactions[]（动画/交互清单）、acceptance[]（验收标准，可判真伪，3-6 条）、"
        "complexity（simple|moderate|complex）。"
    )
    raw = await _chat(model, base_url, api_key, thinking, system, brief)
    spec = _extract_json(raw)
    if not spec.get("components") or not spec.get("acceptance"):
        raise ThreeError("spec_invalid: components/acceptance 必填（img2threejs：无验收标准的 spec 不可实现）")
    # spec 成功后才落盘目录（LLM/解析失败不留残骸目录——project_exists 事故实证）
    d.mkdir(parents=True, exist_ok=True)
    (d / "three-spec.json").write_text(json.dumps(spec, ensure_ascii=False, indent=1), "utf-8")
    state = _initial_state()
    write_state(name, state)
    append_history(name, {"action": "new", "pass": "-", "summary": spec.get("summary", "")})
    return {"ok": True, "spec": spec, "state": state, "dir": str(d)}


def _read_spec_json(d: Path) -> dict[str, Any]:
    """读 spec（唯一入口）：JSONDecodeError 包 ThreeError 带诊断。spec 是
    手编文件（UI 编辑器回灌 + 人工直改都有），损坏不能变裸 500——
    与 build-state.json 的损坏自愈不同：spec 损坏不自愈重置（spec 是
    生成依据不是进度状态，静默清空会让后续 pass 拿空 spec 瞎写），
    如实报错，出路是 /three/spec/save 回灌合法 JSON（其校验门同 new）。
    （issue three-3：手编损坏后 /three/project 与 /three/pass 双双 500。）"""
    try:
        spec = json.loads((d / "three-spec.json").read_text("utf-8"))
    except json.JSONDecodeError as e:
        raise ThreeError(
            f"spec_corrupt: three-spec.json 损坏（{e.msg} @行 {e.lineno} 列 {e.colno}）"
            " —— 用 /three/spec/save 回灌合法 JSON 修复"
        ) from e
    return spec if isinstance(spec, dict) else {}


def _pass_prompt(name: str) -> tuple[str, str]:
    """生成当前 pass 的 (system, user) 提示。"""
    d = _proj_dir(name)
    spec = _read_spec_json(d)
    state = read_state(name)
    cur = next((p for p in state["passes"] if p["id"] == state["current"]), None)
    if cur is None:
        raise ThreeError("state_corrupt: current pass 不存在")
    goal = next((p["goal"] for p in PASSES if p["id"] == state["current"]), "")
    scene_file = d / "scene.js"
    existing = scene_file.read_text("utf-8") if scene_file.exists() else ""
    system = (
        "你是 three.js 场景工程师（img2threejs 分 pass 雕塑纪律）。契约：\n"
        "1. scene.js 必须默认导出 `export default function build(THREE, scene, camera, controls, renderer)`；"
        "可自由 `import * as THREE from 'three'` 与 'three/addons/...（宿主提供 importmap）。\n"
        "2. 返回 `{ metrics: {...}, update(dt) {...} }`（可选）：metrics 进测量反馈，update 为逐帧动画。\n"
        "3. **只实现/完善当前 pass 的层**，其余层保持已有代码不退化（重写整文件，但不得删除其他层的成果）。\n"
        "4. 所有反馈（错误/测量）都已修完才可能收到本任务；blocked 时先改 spec 不写代码。\n"
        "5. 只输出完整 scene.js 代码（```js 围栏或裸码，必须含 export default）。"
    )
    user = (
        f"# 规格（three-spec.json）\n{json.dumps(spec, ensure_ascii=False, indent=1)}\n\n"
        f"# 当前 pass：{state['current']} —— {goal}\n"
        f"# 修复轮：{cur['attempts']}/{state['loop_max']}（本 pass 已失败 {cur['attempts']} 次；"
        f"若有失败原因见下方反馈记录）\n"
        + (f"# 当前 scene.js（在此基础上完善，勿退化其他层）\n```js\n{existing}\n```\n" if existing else "# 尚无代码——从本 pass 起步。\n")
        + f"\n请输出本 pass（{state['current']}）完成后的完整 scene.js。"
    )
    return system, user


async def run_pass(name: str, model: str, base_url: str, api_key: str,
                   thinking: str) -> dict[str, Any]:
    """执行当前 pass：LLM 生成/修补 scene.js（状态门禁：blocked 拒绝）。"""
    state = read_state(name)
    if state.get("blocked"):
        raise ThreeError(
            f"blocked:{state.get('blocked_reason')}"
            " —— 先 refine-spec（POST /three/spec/save 回灌新规范，保存成功即解封重试）"
            "或 POST /three/delete 删项目重开")
    if state.get("current") == "done":
        raise ThreeError("already_done: 项目已完成，无当前 pass")
    cur = next((p for p in state["passes"] if p["id"] == state["current"]), None)
    if cur is None:
        raise ThreeError("state_corrupt: current pass 不存在")
    if cur["status"] == "generated" and cur["attempts"] == 0:
        raise ThreeError(f"pass_awaiting_feedback:{state['current']} 已生成，先跑预览收集反馈（error/metrics/screenshot）")
    if cur["attempts"] >= state["loop_max"]:
        cur["status"] = "blocked"
        state["blocked"] = True
        state["blocked_reason"] = f"{state['current']} 连续 {cur['attempts']} 轮未过——img2threejs：BLOCKED 时保留证据 refine-spec，不许通用场景糊弄"
        write_state(name, state)
        append_history(name, {"action": "blocked", "pass": state["current"], "summary": state["blocked_reason"]})
        raise ThreeError(state["blocked_reason"])
    pid = cur["id"]  # 本次实际生成的 pass；await 期间状态可能被并发推进
    system, user = _pass_prompt(name)
    raw = await _chat(model, base_url, api_key, thinking, system, user)
    js = _extract_js(raw)
    (_proj_dir(name) / "scene.js").write_text(js, "utf-8")
    # await 之后重读盘上状态，按 pid 键控写回：run 期间并发 feedback（error/
    # metrics/screenshot）可能已推进 attempts/blocked/evidence——旧快照整写
    # 会把它们覆盖掉（状态机绕过：blocked 门复活）。本函数只拥有 status 字段。
    # 键控到 pid 而非「重读时刻的 current」：若 await 期间 continue_pass 已
    # 推进到下一 pass，按 current 找会把无生成地标的下一 pass 标 generated
    # （scene.js 内容其实是上一 pass 的），推进到 done 则误报 state_corrupt。
    state2 = read_state(name)
    cur2 = next((p for p in state2["passes"] if p["id"] == pid), None)
    if cur2 is None or state2.get("current") != pid:
        # 已被推进/越界：不写状态、保留 scene.js、如实返回——绝不把别的
        # pass 标 generated。
        append_history(name, {"action": "generate", "pass": pid, "stale": True, "chars": len(js)})
        return {"ok": True, "pass": pid, "stale": True, "chars": len(js), "state": state2,
                "note": f"{pid} 的 scene.js 已生成落盘；await 期间状态已推进到 "
                        f"{state2.get('current')}，未改写状态（如需重生成请切回该 pass 后重跑）"}
    cur2["status"] = "generated"
    write_state(name, state2)
    append_history(name, {"action": "generate", "pass": pid, "chars": len(js)})
    return {"ok": True, "pass": pid, "chars": len(js), "state": state2}


async def feedback(name: str, kind: str, payload: Any) -> dict[str, Any]:
    """三反馈入口（WebView 桥回传）。error → 修复轮 +1；metrics 记录；
    screenshot 落盘 evidence/。"""
    state = read_state(name)
    if state.get("current") == "done":
        raise ThreeError("already_done: 项目已完成，无当前 pass")
    cur = next((p for p in state["passes"] if p["id"] == state["current"]), None)
    if cur is None:
        raise ThreeError("state_corrupt: current pass 不存在")
    if kind == "error":
        cur["attempts"] += 1
        cur["status"] = "failed"
        cur["last_error"] = str(payload)[:500]
        append_history(name, {"action": "feedback", "pass": state["current"],
                              "kind": "error", "summary": str(payload)[:200]})
        status = "failed"
    elif kind == "metrics":
        append_history(name, {"action": "feedback", "pass": state["current"],
                              "kind": "metrics", "summary": json.dumps(payload, ensure_ascii=False)[:200]})
        status = "metrics-ok"
    elif kind == "screenshot":
        ev_dir = _proj_dir(name) / "evidence"
        ev_dir.mkdir(exist_ok=True)
        # payload 可为纯 dataUrl 字符串或 {data, tag}（turntable 方位取证命名）
        tag = ""
        data = payload
        if isinstance(payload, dict):
            tag = "".join(c for c in str(payload.get("tag", "")) if c.isalnum() or c in "-_")[:24]
            data = payload.get("data", "")
        n = len(cur["evidence"]) + 1
        img = ev_dir / f"{state['current']}-{tag or 'shot'}-{n:02d}.png"
        data = str(data)
        if data.startswith("data:image/png;base64,"):
            data = data[len("data:image/png;base64,"):]
        import base64
        img.write_bytes(base64.b64decode(data))
        cur["evidence"].append(img.name)
        # 仅在已有真实生成痕迹（修复轮已计/scene.js 在场）时才置 generated：
        # 骨架页（首次 run_pass 前）的截图不能置 generated——否则 continue
        # 门被骨架截图穿透、首个真实 run_pass 反被 pass_awaiting_feedback
        # 卡死（状态机绕过登记 2026-11-16）。无痕迹时只记 evidence 不改 status。
        if cur["attempts"] > 0 or (_proj_dir(name) / "scene.js").exists():
            cur["status"] = "generated"  # 有截图证据，等待 continue 判定
        append_history(name, {"action": "evidence", "pass": state["current"],
                              "kind": "screenshot", "file": img.name, "tag": tag})
        status = "evidence-ok"
    else:
        raise ThreeError(f"invalid_feedback_kind:{kind}")
    if kind == "error" and cur["attempts"] >= state["loop_max"]:
        cur["status"] = "blocked"
        state["blocked"] = True
        state["blocked_reason"] = (
            f"{state['current']} 连续 {cur['attempts']} 轮执行失败：{str(payload)[:200]}"
            " —— BLOCKED：保留证据 refine-spec（img2threejs 纪律），不许硬写")
        append_history(name, {"action": "blocked", "pass": state["current"],
                              "summary": state["blocked_reason"]})
        status = "blocked"
    write_state(name, state)
    return {"ok": True, "status": status, "pass": state["current"],
            "attempts": cur["attempts"], "state": state}


def continue_pass(name: str, summary: str = "") -> dict[str, Any]:
    """评审通过（agent 看过 evidence/截图后调用）：推进到下一 pass。"""
    state = read_state(name)
    if state.get("current") == "done":
        raise ThreeError("already_done: 项目已完成，无当前 pass")
    cur = next((p for p in state["passes"] if p["id"] == state["current"]), None)
    if cur is None:
        raise ThreeError("state_corrupt: current pass 不存在")
    if cur["status"] not in ("generated", "verified") or not cur["evidence"]:
        raise ThreeError(f"cannot_continue:{state['current']} 状态 {cur['status']} 且无 evidence —— 先截图（img2threejs：每步必带证据）")
    cur["status"] = "verified"
    append_history(name, {"action": "continue", "pass": state["current"], "summary": summary[:200]})
    idx = next((i for i, p in enumerate(state["passes"]) if p["id"] == state["current"]), -1)
    if idx + 1 < len(state["passes"]):
        state["current"] = state["passes"][idx + 1]["id"]
        write_state(name, state)
        return {"ok": True, "current": state["current"], "done": False}
    state["current"] = "done"
    write_state(name, state)
    append_history(name, {"action": "done", "pass": "-", "summary": "全部 pass verified"})
    return {"ok": True, "current": "done", "done": True}


def save_spec(name: str, spec: dict[str, Any]) -> dict[str, Any]:
    """规范手编回灌（img2threejs：手改必须落 spec，不许只改代码）。
    最小校验：components/acceptance 非空（与 new_project 同门）。

    成功落盘后解除 blocked 并复位对应 pass 计数（issue three-1：错误信封
    教用户「refine-spec 解封」，此前 save_spec 只写文件不清标志——blocked
    是永久死锁，两剂药「重新 new 覆盖」也撞 project_exists 门）。复位 =
    blocked pass 的 attempts 归零、状态回 pending：携带新 spec 从本层重跑，
    旧 attempts 不清零会在下一次生成后立刻再撞 loop_max。"""
    d = _proj_dir(name)
    if not (d / "build-state.json").exists():
        raise ThreeError(f"no_project:{name}")
    if not spec.get("components") or not spec.get("acceptance"):
        raise ThreeError("spec_invalid: components/acceptance 必填")
    (d / "three-spec.json").write_text(json.dumps(spec, ensure_ascii=False, indent=1), "utf-8")
    state = read_state(name)
    unblocked = bool(state.get("blocked"))
    if unblocked:
        state["blocked"] = False
        state["blocked_reason"] = ""
        reset = [p for p in state["passes"] if p.get("status") == "blocked"]
        if not reset:
            # 兜底：标志在场但无 pass 标 blocked（历史状态形状）——复位当前层
            curp = next((p for p in state["passes"] if p["id"] == state.get("current")), None)
            if curp is not None:
                reset = [curp]
        for p in reset:
            p["attempts"] = 0
            p["status"] = "pending"
        write_state(name, state)
    append_history(name, {"action": "refine-spec", "pass": "-",
                          "unblocked": unblocked,
                          "summary": str(spec.get("title") or spec.get("summary") or "")[:120]})
    return {"ok": True, "unblocked": unblocked, "state": state}


def delete_project(name: str) -> dict[str, Any]:
    """真删 3D 项目目录（blocked 终局的第二条出路 + 用户主动清理）。

    路径校验对齐 portfolio_delete 纪律：name 经 ``_proj_dir`` 全量白名单
    校验，并显式断言目标只能落在 ``THREE_ROOT`` 下一层——name 来自 HTTP
    body，空串/``..``/绝对路径绝不进 ``shutil.rmtree``（hotapp 旧实现空串
    删整个应用根的同款事故）。此前作品集对 three 只隐藏不删（产物不归
    作品集所有），用户唯一的删除出路是手改文件系统。"""
    d = _proj_dir(name)
    if d.parent != THREE_ROOT:  # 显式断言：删除目标只能落在项目根下一层
        raise ThreeError(f"invalid_ref:{name} —— 路径越界")
    if not d.exists():
        raise ThreeError(f"no_project:{name}")
    shutil.rmtree(d)
    return {"ok": True, "name": name}


def read_spec(name: str) -> dict[str, Any]:
    d = _proj_dir(name)
    f = d / "three-spec.json"
    if not f.exists():
        raise ThreeError(f"no_project:{name}")
    return {"ok": True, "spec": _read_spec_json(d)}


def read_project(name: str) -> dict[str, Any]:
    d = _proj_dir(name)
    if not d.exists():
        raise ThreeError(f"no_project:{name}")
    spec = _read_spec_json(d) if (d / "three-spec.json").exists() else {}
    scene = (d / "scene.js").read_text("utf-8") if (d / "scene.js").exists() else ""
    history = []
    hist_file = d / "history.jsonl"
    if hist_file.exists():
        # 单行坏档（崩溃时 append 写了半行）跳过，不让它 500 整个项目读取。
        for l in hist_file.read_text("utf-8").splitlines()[-50:]:
            try:
                history.append(json.loads(l))
            except (json.JSONDecodeError, ValueError):
                continue
    return {"ok": True, "name": name, "spec": spec, "state": read_state(name),
            "scene_js": scene, "history": history, "dir": str(d)}


def list_projects() -> dict[str, Any]:
    items = []
    if THREE_ROOT.exists():
        for d in sorted(THREE_ROOT.iterdir()):
            sf = d / "build-state.json"
            if not sf.exists():
                continue
            try:
                st = json.loads(sf.read_text("utf-8"))
                if not isinstance(st, dict):
                    raise ValueError("not an object")
            except (json.JSONDecodeError, OSError, ValueError):
                # 单个项目状态损坏不得 500 整个列表——标注 corrupt 让用户看见；
                # 点击项目即触发 read_state 的 .bak 自愈重置。
                items.append({"name": d.name, "current": "corrupt", "blocked": True})
                continue
            items.append({"name": d.name, "current": st.get("current"),
                          "blocked": st.get("blocked", False)})
    return {"ok": True, "projects": items}


def preview_html(name: str) -> str:
    d = _proj_dir(name)
    if not (d / "three-spec.json").exists():
        raise ThreeError(f"no_project:{name}")
    return (PREVIEW_TEMPLATE.replace("__NAME__", name)
            .replace("__TS__", str(int(time.time()))))


def scene_js(name: str) -> str:
    d = _proj_dir(name)
    f = d / "scene.js"
    if not f.exists():
        # 骨架：让首帧预览不是 404（pass 未生成时也能开预览收环境 metrics）
        return ("export default function build(THREE, scene, camera, controls, renderer) {\n"
                "  const grid = new THREE.GridHelper(20, 20, 0x33415a, 0x1b2338);\n"
                "  scene.add(grid);\n"
                "  return { metrics: { skeleton: true } };\n"
                "}\n")
    return f.read_text("utf-8")
