"""`.nonapp` 单文件包（文件即应用 v2）：导出 / 校验 / 导入。

格式见 docs/plan-chat-stream-shell.md §1.1：`.nonapp` = 单个 zip（DEFLATE），
只允许 5 个条目（``ALLOWED_ENTRIES``），manifest.json 是唯一识别判据：

    manifest.json           必填：formatVersion/id/name/title/renderer/createdAt/minAppVersion
    payload/index.html      renderer=html 的载荷（零外链，过 hotapp._html_ok）
    payload/surface.json    renderer=a2ui 的载荷（A2UI 消息序列，数组或 {"messages": [...]}）
    payload/data.json       a2ui 可选 DataModel 快照（object，仅人类可读，不参与渲染）
    payload/prompt.txt      a2ui 可选续跑提示（<=8KiB，本批不消费）

**数据边界**：业务数据（app.db / DataModel 运行时数据）不随包走——导入 =
全新实例（app.db 由首次 db_exec 懒建，见 hotapp_agent.py:298）。

导入安全面是本模块存在的理由：zip 解包是最大攻击面，因此
① 白名单 + 条目数/单条解压/总解压三重上限（ZipInfo.file_size 只作快速
预检——声明值可伪造；真实解压走 ``zf.open(info)`` 分块读取并逐块累计，
超过 MAX_ENTRY_BYTES 立即失败，峰值内存不随真实载荷增长）；② 条目名拒
../、绝对路径、反斜杠、控制字符；③ 先写
``HOTAPP_ROOT/.import-<uuid>`` 临时目录，再在**每应用 asyncio 锁**内
旧目录改名 .trash-<uuid> → ``os.replace`` 落位 → rmtree 旧目录；④ 失败
路径清干净临时目录（不产生半成品）。锁必须是 ``hotapp._lock_for`` 的
asyncio.Lock——与 generate/refine/delete/db_exec 共用，换成 threading.Lock
与既有 asyncio 锁互斥，导入/删除并发会撕裂目录。
"""
from __future__ import annotations

import asyncio
import io
import json
import os
import re
import shutil
import time
import uuid
import zipfile
import zlib
from pathlib import Path
from typing import Any

import hotapp_agent as hotapp

FORMAT_VERSION = 1
MAX_PACKAGE_BYTES = 8 * 1024 * 1024
MAX_ENTRY_BYTES = 8 * 1024 * 1024
MAX_TOTAL_UNCOMPRESSED = 16 * 1024 * 1024
MAX_ENTRIES = 32
MAX_PROMPT_BYTES = 8 * 1024
MAX_TITLE_CHARS = 120
MAX_BRIEF_CHARS = 2000
# 解压读取块：上限检查在每块后执行，单块是峰值内存的固定上界（声明大小
# 伪造时真正兜底的是这个循环，而非 ZipInfo.file_size 预检）。
_READ_CHUNK_BYTES = 64 * 1024
ALLOWED_ENTRIES = {
    "manifest.json",
    "payload/index.html",
    "payload/surface.json",
    "payload/data.json",
    "payload/prompt.txt",
}
RENDERERS = ("html", "a2ui")

# id 是分享者视角的稳定身份（同名冲突策略：同名且同 id = 覆盖升级）：
# 小写字母数字开头，其后允许 -_，<=64。与 hotapp 的应用名白名单不同——
# 应用名允许 '_' / '-' 开头，id 不允许（生成时自动补前缀）。
_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
# minAppVersion 只做格式校验（语义化版本）：与客户端版本比较是**客户端**
# 的职责（服务端版本号与客户端不同轨，替客户端判会误伤）。
_SEMVER_RE = re.compile(r"^\d+\.\d+(\.\d+)?([-+][0-9A-Za-z.-]+)?$")


def _valid_app_name(name: Any) -> bool:
    """与 hotapp._app_dir 同一套应用名规则（无需副作用，供导入前置校验）。"""
    if not isinstance(name, str) or not name:
        return False
    if len(name) > hotapp.MAX_APP_NAME:
        return False
    return all(c.isascii() and (c.isalnum() or c in "-_") for c in name)


def _derive_id(name: str) -> str:
    """从应用名派生 manifest.id（首次导出时写进 meta，此后稳定）。"""
    body = "".join(c for c in name.lower() if c.isascii() and (c.isalnum() or c in "-_"))
    if not body:
        body = "app"
    if not body[0].isalnum():
        body = "app-" + body
    return body[:64]


def _meta_of(d: Path) -> dict[str, Any]:
    m = d / "meta.json"
    if not m.exists():
        return {}
    try:
        raw = json.loads(m.read_text("utf-8"))
    except (json.JSONDecodeError, OSError, ValueError):
        return {}
    return raw if isinstance(raw, dict) else {}


def _renderer_of(d: Path, meta: dict[str, Any]) -> str:
    """渲染器判定：meta.renderer 优先，其次按载荷存在性（surface.json > index.html）。"""
    declared = str(meta.get("renderer") or "")
    if declared in RENDERERS:
        return declared
    if (d / "surface.json").exists():
        return "a2ui"
    return "html"


def _app_counters(d: Path, meta: dict[str, Any]) -> tuple[int, int]:
    created = meta.get("createdAt")
    created_at = int(created) if isinstance(created, int) and not isinstance(created, bool) else int(time.time())
    return created_at, int(time.time())


# ---------- 导出 ----------


def _manifest_for(name: str) -> tuple[dict[str, Any], Path, str]:
    d = hotapp._app_dir(name)
    if not d.is_dir():
        raise hotapp.HotAppError(f"no_app:{name}")
    meta = _meta_of(d)
    renderer = _renderer_of(d, meta)
    if renderer == "html" and not (d / "index.html").exists():
        raise hotapp.HotAppError(f"no_app:{name}")
    if renderer == "a2ui" and not (d / "surface.json").exists():
        raise hotapp.HotAppError(f"no_app:{name}")
    created_at, _ = _app_counters(d, meta)
    manifest: dict[str, Any] = {
        "formatVersion": FORMAT_VERSION,
        "id": str(meta.get("nonappId") or _derive_id(name)),
        "name": name,
        "title": str(meta.get("title") or name)[:MAX_TITLE_CHARS],
        "renderer": renderer,
        "createdAt": created_at,
        "minAppVersion": str(meta.get("minAppVersion") or "0.1.0"),
    }
    brief = meta.get("brief")
    if isinstance(brief, str) and brief.strip():
        manifest["brief"] = brief[:MAX_BRIEF_CHARS]
    return manifest, d, renderer


def build_package(name: str) -> bytes:
    """把一个已存在热应用打包成 `.nonapp`（zip bytes）。"""
    manifest, d, renderer = _manifest_for(name)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, indent=1))
        if renderer == "html":
            zf.writestr("payload/index.html", (d / "index.html").read_text("utf-8"))
        else:
            zf.writestr("payload/surface.json", (d / "surface.json").read_text("utf-8"))
            data_file = d / "data.json"
            if data_file.exists():
                zf.writestr("payload/data.json", data_file.read_text("utf-8"))
            prompt_file = d / "prompt.txt"
            if prompt_file.exists():
                zf.writestr("payload/prompt.txt", prompt_file.read_text("utf-8"))
    return buf.getvalue()


# ---------- 只读查询 ----------


def _reject_a2ui_external_urls(node: Any) -> None:
    """a2ui 载荷零外链门：拒任何「整串就是一个 URL」的字符串值。

    basic 目录的 Image/Video/AudioPlayer 对 http(s) 地址直接走网络拉取
    （a2ui_flutter 0.3.0 image.dart / media.dart），dataModelUpdate 里的 URL
    也会经绑定喂进这些组件——不受信包会向任意外部地址发起请求，与「a2ui
    内存渲染零服务依赖」相悖。只匹配整串地址（trim 后以协议开头），展示文案
    里提到链接不误伤；surface 信封的 ``catalogId`` 是结构字段，按信封上下文
    豁免（不做键名全局豁免——data model 里同名键不能走私地址）。
    """
    def walk(value: Any) -> None:
        if isinstance(value, str):
            v = value.strip().lower()
            if v.startswith(("http://", "https://", "//")):
                raise hotapp.HotAppError(
                    f"nonapp_a2ui_external_refs: {value[:120]} —— a2ui 载荷必须零外链")
            return
        if isinstance(value, dict):
            is_surface_envelope = "surfaceId" in value
            for key, child in value.items():
                if is_surface_envelope and key == "catalogId":
                    continue
                walk(child)
            return
        if isinstance(value, (list, tuple)):
            for child in value:
                walk(child)

    walk(node)


def _normalize_surface(raw: Any) -> list[Any]:
    """A2UI 消息序列归一：JSON 数组或 {"messages": [...]}（其余拒绝）。"""
    if isinstance(raw, list):
        messages = raw
    elif isinstance(raw, dict) and isinstance(raw.get("messages"), list):
        messages = raw["messages"]
    else:
        raise hotapp.HotAppError("nonapp_invalid_surface: 必须是数组或 {\"messages\": [...]}")
    for i, m in enumerate(messages):
        if not isinstance(m, dict):
            raise hotapp.HotAppError(f"nonapp_invalid_surface: 第 {i} 项不是对象")
    if not messages:
        raise hotapp.HotAppError("nonapp_invalid_surface: 消息序列为空")
    return messages


def read_a2ui(name: str) -> dict[str, Any]:
    d = hotapp._app_dir(name)
    if not d.is_dir():
        raise hotapp.HotAppError(f"no_app:{name}")
    meta = _meta_of(d)
    if _renderer_of(d, meta) != "a2ui" or not (d / "surface.json").exists():
        raise hotapp.HotAppError(f"not_a2ui:{name}")
    raw = json.loads((d / "surface.json").read_text("utf-8"))
    messages = _normalize_surface(raw)
    return {
        "ok": True,
        "name": name,
        "title": str(meta.get("title") or name),
        "messages": messages,
    }


def app_info(name: str) -> dict[str, Any]:
    """应用存在性/渲染器（不存在时 exists=false 且 ok=true）。"""
    d = hotapp._app_dir(name)
    exists = d.is_dir() and (
        (d / "index.html").exists() or (d / "surface.json").exists()
    )
    if not exists:
        return {"ok": True, "name": name, "title": name, "renderer": "html", "exists": False}
    meta = _meta_of(d)
    return {
        "ok": True,
        "name": name,
        "title": str(meta.get("title") or name),
        "renderer": _renderer_of(d, meta),
        "exists": True,
    }


# ---------- 导入（校验 + 原子落位） ----------


def _reject_entry_name(name: str) -> None:
    """条目名白名单（fail-closed）：路径穿越/绝对路径/反斜杠/控制字符/未列名。"""
    if not name:
        raise hotapp.HotAppError("nonapp_unexpected_entry:<empty>")
    if "\\" in name or name.startswith("/") or ".." in name:
        raise hotapp.HotAppError(f"nonapp_unexpected_entry:{name}")
    if any(ord(c) < 0x20 for c in name):
        raise hotapp.HotAppError(f"nonapp_unexpected_entry:{name}")
    if name not in ALLOWED_ENTRIES:
        raise hotapp.HotAppError(f"nonapp_unexpected_entry:{name}")


def _is_directory_entry(name: str) -> bool:
    """zip 目录项可选（“无目录项亦可”）：只接受 manifest/payload 两级。"""
    stripped = name.rstrip("/")
    return bool(name.endswith("/")) and stripped in ("", "payload")


def _decode_text(raw: bytes, what: str) -> str:
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as e:
        raise hotapp.HotAppError(f"nonapp_invalid_payload:{what} 不是 UTF-8 文本") from e


def _parse_manifest(raw: bytes) -> dict[str, Any]:
    try:
        doc = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise hotapp.HotAppError(f"nonapp_invalid_manifest: JSON 解析失败（{e}）") from e
    if not isinstance(doc, dict):
        raise hotapp.HotAppError("nonapp_invalid_manifest: 顶层必须是对象")

    version = doc.get("formatVersion")
    if isinstance(version, bool) or not isinstance(version, int) or version != FORMAT_VERSION:
        raise hotapp.HotAppError(f"nonapp_unsupported_version:{version}")

    ident = doc.get("id")
    if not isinstance(ident, str) or not _ID_RE.match(ident):
        raise hotapp.HotAppError(f"nonapp_invalid_id:{ident}")

    name = doc.get("name")
    if not _valid_app_name(name):
        raise hotapp.HotAppError(f"nonapp_invalid_name:{name}")

    title = doc.get("title")
    if not isinstance(title, str) or len(title) > MAX_TITLE_CHARS:
        raise hotapp.HotAppError("nonapp_invalid_manifest:title（字符串，<=120 字符）")

    renderer = doc.get("renderer")
    if renderer not in RENDERERS:
        raise hotapp.HotAppError(f"nonapp_unsupported_renderer:{renderer}")

    created = doc.get("createdAt")
    if isinstance(created, bool) or not isinstance(created, int) or created <= 0:
        raise hotapp.HotAppError("nonapp_invalid_manifest:createdAt（epoch 秒整数）")

    min_version = doc.get("minAppVersion")
    if not isinstance(min_version, str) or not _SEMVER_RE.match(min_version):
        raise hotapp.HotAppError("nonapp_invalid_manifest:minAppVersion（语义化版本）")

    brief = doc.get("brief")
    if brief is not None and (not isinstance(brief, str) or len(brief) > MAX_BRIEF_CHARS):
        raise hotapp.HotAppError("nonapp_invalid_manifest:brief（字符串，<=2000 字符）")

    clean = {
        "formatVersion": FORMAT_VERSION,
        "id": ident,
        "name": name,
        "title": title or name,
        "renderer": renderer,
        "createdAt": created,
        "minAppVersion": min_version,
    }
    if isinstance(brief, str):
        clean["brief"] = brief
    return clean


def _validate_payload(manifest: dict[str, Any], files: dict[str, bytes]) -> dict[str, Any]:
    """载荷形状校验 → 返回归一化后的载荷（html 文本 / a2ui 消息 + 可选件）。"""
    out: dict[str, Any] = {}
    if manifest["renderer"] == "html":
        raw = files.get("payload/index.html")
        if raw is None:
            raise hotapp.HotAppError("nonapp_missing_payload: renderer=html 需要 payload/index.html")
        html = _decode_text(raw, "payload/index.html")
        try:
            ok = hotapp._html_ok(html)
        except hotapp.HotAppError as e:
            # 外链门：保留原判定文字，前缀稳定给客户端分派
            raise hotapp.HotAppError(f"nonapp_html_invalid: {e}") from e
        if not ok:
            raise hotapp.HotAppError("nonapp_html_invalid: 缺少 <body>/</html> 结构（服务端结构门）")
        out["html"] = html
        return out

    raw = files.get("payload/surface.json")
    if raw is None:
        raise hotapp.HotAppError("nonapp_missing_payload: renderer=a2ui 需要 payload/surface.json")
    try:
        surface = json.loads(_decode_text(raw, "payload/surface.json"))
    except json.JSONDecodeError as e:
        raise hotapp.HotAppError(f"nonapp_invalid_surface: JSON 解析失败（{e}）") from e
    out["messages"] = _normalize_surface(surface)
    _reject_a2ui_external_urls(out["messages"])

    data_raw = files.get("payload/data.json")
    if data_raw is not None:
        try:
            data = json.loads(_decode_text(data_raw, "payload/data.json"))
        except json.JSONDecodeError as e:
            raise hotapp.HotAppError(f"nonapp_invalid_data: JSON 解析失败（{e}）") from e
        if not isinstance(data, dict):
            raise hotapp.HotAppError("nonapp_invalid_data: payload/data.json 必须是对象")
        out["data"] = data

    prompt_raw = files.get("payload/prompt.txt")
    if prompt_raw is not None:
        if len(prompt_raw) > MAX_PROMPT_BYTES:
            raise hotapp.HotAppError(f"nonapp_invalid_prompt: 超过 {MAX_PROMPT_BYTES} 字节")
        out["prompt"] = _decode_text(prompt_raw, "payload/prompt.txt")
    return out


def _read_entry_limited(zf: zipfile.ZipFile, info: zipfile.ZipInfo) -> bytes:
    """分块解压单条目，累计真实输出字节；超限立即失败。

    `zf.read(info)` 会按声明大小以外的口径把整段 deflate 流一次解压（
    `ZipExtFile.read(-1)` 用 MAX_N 作为输出上限），高压缩比 + 伪造声明大小
    的包会在长度校验之前吃掉几十/几百 MB。这里按 `_READ_CHUNK_BYTES` 流式
    读取：任何时刻内存里只有已读块（上限 MAX_ENTRY_BYTES）+ 一块输出，
    末尾拼接再复制一次，峰值仍是 ≤2×MAX_ENTRY_BYTES 的固定上界。
    声明大小预检仍保留（见调用方）作为快速失败。
    """
    chunks: list[bytes] = []
    total = 0
    try:
        with zf.open(info) as fp:
            while True:
                chunk = fp.read(_READ_CHUNK_BYTES)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_ENTRY_BYTES:
                    raise hotapp.HotAppError(
                        f"nonapp_too_large: 条目 {info.filename} 解压后超过 8MiB")
                chunks.append(chunk)
    except (zipfile.BadZipFile, EOFError, zlib.error, NotImplementedError) as e:
        # 声明大小与真实数据不一致（伪造头）、损坏 deflate 流、截断数据、
        # 白名单条目声明了 zipfile 不支持的压缩方法（compress_type 未知，
        # 如 99 → zf.open 抛 NotImplementedError）：一律按坏 zip 拒绝，不把
        # zipfile 内部异常漏成裸 500（review nonapp-4）。
        raise hotapp.HotAppError(f"nonapp_invalid_zip: 条目 {info.filename} 解压失败（{e}）") from e
    return b"".join(chunks)


def _read_zip(data: bytes) -> tuple[dict[str, Any], dict[str, bytes]]:
    """解包 + 全部纯校验（不落盘）：返回 (manifest, 白名单条目字节)。"""
    if len(data) > MAX_PACKAGE_BYTES:
        raise hotapp.HotAppError("nonapp_too_large: 包体超过 8MiB")
    try:
        zf = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as e:
        raise hotapp.HotAppError(f"nonapp_invalid_zip: {e}") from e
    with zf:
        infos = zf.infolist()
        if len(infos) > MAX_ENTRIES:
            raise hotapp.HotAppError(f"nonapp_too_large: 条目数超过 {MAX_ENTRIES}")
        total = 0
        for info in infos:
            if info.flag_bits & 0x1:
                raise hotapp.HotAppError("nonapp_invalid_zip: 不支持加密条目")
            if info.file_size > MAX_ENTRY_BYTES:
                raise hotapp.HotAppError(
                    f"nonapp_too_large: 条目 {info.filename} 解压后超过 8MiB")
            total += info.file_size
            if total > MAX_TOTAL_UNCOMPRESSED:
                raise hotapp.HotAppError("nonapp_too_large: 总解压体积超过 16MiB")

        files: dict[str, bytes] = {}
        for info in infos:
            if _is_directory_entry(info.filename):
                continue
            _reject_entry_name(info.filename)
            if info.filename in files:
                raise hotapp.HotAppError(f"nonapp_unexpected_entry:{info.filename}（重复条目）")
            # 声明大小预检在上面已做（快速失败）；真实解压字节在这里分块
            # 计数，伪造声明大小的高压缩比包走不到「先全量解压再校验」。
            files[info.filename] = _read_entry_limited(zf, info)

    manifest_raw = files.get("manifest.json")
    if manifest_raw is None:
        raise hotapp.HotAppError("nonapp_missing_manifest: 缺少 manifest.json")
    manifest = _parse_manifest(manifest_raw)
    _validate_payload(manifest, files)
    return manifest, files


def _current_id(d: Path, name: str) -> str:
    """磁盘目录的当前身份 id：meta.nonappId 优先，缺失时按导出时的
    `_derive_id(name)` 兜底。

    generate 路径（hotapp_agent.generate）从不写 nonappId——只比 meta 会让
    「导出自家生成的应用再导回」必得 app_exists:name（要重导只能删应用，
    连 app.db 一起丢，review nonapp-3）。已导入目录一定带 nonappId，兜底
    只在 generate/手工目录上生效，不掩盖真实的 id 冲突。
    """
    return str(_meta_of(d).get("nonappId") or "") or _derive_id(name)


def _conflict(name: str, ident: str) -> None:
    """同名目录策略：同 id = 覆盖升级；否则 app_exists（生成路径同语义）。"""
    d = hotapp.HOTAPP_ROOT / name
    if not d.exists():
        return
    if _current_id(d, name) != ident:
        raise hotapp.HotAppError(f"app_exists:{name}")


def _write_staging(manifest: dict[str, Any], files: dict[str, bytes]) -> Path:
    """写临时目录（HOTAPP_ROOT/.import-<uuid>）：载荷扁平落到应用根。"""
    hotapp.HOTAPP_ROOT.mkdir(parents=True, exist_ok=True)
    stage = hotapp.HOTAPP_ROOT / f".import-{uuid.uuid4().hex}"
    stage.mkdir(parents=True, exist_ok=False)
    try:
        if manifest["renderer"] == "html":
            (stage / "index.html").write_text(files["payload/index.html"].decode("utf-8"), "utf-8")
        else:
            # surface.json 归一后重写：导入的形态与导出一致（数组），下游只认一种。
            surface = files["payload/surface.json"]
            try:
                normalized = _normalize_surface(json.loads(surface.decode("utf-8")))
            except (json.JSONDecodeError, UnicodeDecodeError) as e:  # 已在上游校验过，防御性
                raise hotapp.HotAppError(f"nonapp_invalid_surface: {e}") from e
            (stage / "surface.json").write_text(
                json.dumps(normalized, ensure_ascii=False, indent=1), "utf-8")
            for src, dst in (("payload/data.json", "data.json"),
                             ("payload/prompt.txt", "prompt.txt")):
                if src in files:
                    (stage / dst).write_bytes(files[src])
        now = int(time.time())
        meta = {
            "name": manifest["name"],
            "title": manifest["title"],
            "brief": manifest.get("brief") or "导入的 .nonapp",
            "createdAt": manifest["createdAt"],
            "updatedAt": now,
            "kind": "hotapp",
            "renderer": manifest["renderer"],
            "nonappId": manifest["id"],
            "formatVersion": FORMAT_VERSION,
            "minAppVersion": manifest["minAppVersion"],
            "importedAt": now,
        }
        (stage / "meta.json").write_text(
            json.dumps(meta, ensure_ascii=False, indent=1), "utf-8")
        return stage
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise


def _promote(stage: Path, name: str, ident: str) -> Path:
    """锁内落位：旧目录改名 .trash → os.replace(stage → 目标) → rmtree 旧目录。

    中途失败回滚（旧目录改回原名），绝不留下「目标不存在 + 旧内容在 .trash」
    的丢数据状态。
    """
    d = hotapp._app_dir(name)
    trash: Path | None = None
    if d.exists():
        # 锁内重验同 _conflict：generate 目录（meta 无 nonappId）按
        # _derive_id 兜底，否则重导自家生成的应用在锁内又被拦下。
        if _current_id(d, name) != ident:
            raise hotapp.HotAppError(f"app_exists:{name}")
        trash = hotapp.HOTAPP_ROOT / f".trash-{uuid.uuid4().hex}"
        os.replace(d, trash)
    try:
        os.replace(stage, d)
    except OSError:
        if trash is not None:
            try:
                os.replace(trash, d)
            except OSError:
                pass
        raise
    if trash is not None:
        shutil.rmtree(trash, ignore_errors=True)
    return d


async def install_package(data: bytes, filename_hint: str | None = None) -> dict[str, Any]:
    """导入 `.nonapp`：校验（纯内存）→ 临时目录 → 锁内原子落位 → 作品集登记。

    ``filename_hint`` 只作日志（请求头/查询参数里的原始文件名），不参与命名——
    目录名唯一来源是 manifest.name（以 manifest.json 为唯一判据，扩展名不作数）。
    """
    manifest, files = _read_zip(data)
    name = manifest["name"]
    ident = manifest["id"]
    stage: Path | None = None
    try:
        _conflict(name, ident)  # 无锁快速失败（真实裁决在锁内 _promote 重验）
        stage = _write_staging(manifest, files)
        # 与 generate/refine/delete/db_exec 共用同一把每应用 asyncio 锁：
        # 上传体已在锁外解析完（不占锁跑 IO），锁内只做目录换位。
        async with hotapp._lock_for(name):
            target = _promote(stage, name, ident)
            stage = None  # 已落位，finally 不再动它
            hotapp.portfolio_upsert(
                kind="hotapp",
                ref=name,
                title=manifest["title"],
                path=str(target / ("index.html" if manifest["renderer"] == "html" else "surface.json")),
                detail="导入的 .nonapp",
                renderer=manifest["renderer"],
            )
        hint = f" (from {filename_hint})" if filename_hint else ""
        print(f"[nonapp] imported {name} ({manifest['renderer']}){hint}", flush=True)
        return {
            "ok": True,
            "name": name,
            "title": manifest["title"],
            "renderer": manifest["renderer"],
            "id": ident,
            "formatVersion": FORMAT_VERSION,
            "dir": str(target),
            "portfolio": True,
        }
    finally:
        if stage is not None:
            shutil.rmtree(stage, ignore_errors=True)
