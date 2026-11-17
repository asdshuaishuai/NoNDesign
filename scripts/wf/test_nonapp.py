#!/usr/bin/env python3
"""`.nonapp` 包（文件即应用 v2）回归：导出 / 导入 / a2ui / 安全门 / 路由级 e2e。

用法：.venv/bin/python scripts/wf/test_nonapp.py （退出码 0 = 全绿）

覆盖（与 server/nonapp_agent.py 的校验顺序一一对应）：
  1) 导出 → zip 条目名恰为 manifest.json + payload/index.html；manifest 字段
     齐全；导入到空根后目录内容一致，作品集出现 renderer=html 条目。
  2) a2ui：导入后目录含 surface.json、作品集 renderer=a2ui、**不进
     /hotapp/list**（保 test_hotapp 第 9 条 index.html 判据）、read_a2ui
     返回数组、export → import 再一致。
  3) 安全门逐项：../ 条目、绝对路径、反斜杠、未列名条目、条目数超限、
     单条/总解压体积超限、坏 zip、坏 manifest 版本/name/id、未知 renderer、
     缺载荷、html 外链、超长 body —— 各自稳定 code，且失败不留半成品目录。
  4) 同名策略：同 id = 覆盖升级（内容替换）；不同 id = app_exists；
     **generate 目录（meta 无 nonappId）导出 → 重导按 _derive_id 兜底**。
  5) TestClient 路由级 e2e：POST /hotapp/import（真实 zip 字节）→ GET
     /portfolio 命中 → GET /hotapp/page/{name} 200 且含原 HTML 特征串 →
     POST /hotapp/export 取回字节 → 再次 import 同名同 id 覆盖成功 →
     GET /hotapp/info / /hotapp/a2ui 语义；不支持的压缩方法 400 而非 500。
  6) 客户端打开入口：AndroidManifest 的 VIEW filter 必须拆成「后缀/路径」
     与「MIME」两条（mime 与 pathPattern 混放 = 拿不到 mime 时不匹配）；
     iOS SceneDelegate 覆盖 scene willConnectTo/openURLContexts 并 swiftc
     -typecheck 真编译（缺 iOS 工具链时 skip，不判红）。
  7) 离线 CSP：客户端注入的 meta 与服务端 `_HOTAPP_PAGE_CSP` 同款，且缓存
     写入与 WebView 导航白名单确实接线。
"""

from __future__ import annotations

import asyncio
import io
import json
import re
import shutil
import subprocess
import sys
import tempfile
import tracemalloc
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "server"))

import hotapp_agent as hotapp  # noqa: E402
import nonapp_agent as nonapp  # noqa: E402


def _html(marker: str = "marker-α") -> str:
    # 长度必须 >200（hotapp._html_ok 的结构门），故带一段真实脚本与样式。
    return (
        "<!doctype html><html><head><meta charset=utf-8>"
        "<style>body{background:#111;color:#eee;font:14px system-ui}"
        "canvas{width:100%;height:60vh;display:block}</style></head>"
        f"<body><canvas id=c></canvas><div>{marker}</div>"
        "<script>const c=document.getElementById('c');const x=c.getContext('2d');"
        "let t=0;function f(){t+=0.016;x.clearRect(0,0,c.width,c.height);"
        "x.fillStyle='#6cf';x.fillRect(20+Math.sin(t)*40,40,80,80);requestAnimationFrame(f);}"
        "f();</script></body></html>"
    )


SURFACE_MESSAGES = [
    {
        "version": "1.0",
        "createSurface": {
            "surfaceId": "demo",
            "catalogId": "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json",
            "components": [
                {"id": "root", "component": "Column", "children": ["title"]},
                {"id": "title", "component": "Text", "text": "清单"},
            ],
        },
    },
    {
        "version": "1.0",
        "updateComponents": {"surfaceId": "demo", "components": [
            {"id": "root", "component": "Column", "children": ["title"]},
            {"id": "title", "component": "Text", "text": "清单"},
        ]},
    },
]


def _manifest(**over) -> dict:
    doc = {
        "formatVersion": 1,
        "id": "demo-app",
        "name": "demo-app",
        "title": "演示应用",
        "renderer": "html",
        "createdAt": 1_700_000_000,
        "minAppVersion": "0.1.0",
    }
    doc.update(over)
    return doc


def _zip(entries: dict[str, bytes | str], *, dirs: tuple[str, ...] = ()) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for d in dirs:
            zf.writestr(zipfile.ZipInfo(d if d.endswith("/") else d + "/"), b"")
        for name, content in entries.items():
            zf.writestr(name, content.encode("utf-8") if isinstance(content, str) else content)
    return buf.getvalue()


def _a2ui_zip(**manifest_over) -> bytes:
    return _zip({
        "manifest.json": json.dumps(_manifest(renderer="a2ui", **manifest_over)),
        "payload/surface.json": json.dumps(SURFACE_MESSAGES),
        "payload/data.json": json.dumps({"items": []}),
    })


def _bomb_zip(payload_bytes: int = 64 * 1024 * 1024,
              declared: int = 1000) -> bytes:
    """高压缩比解压炸弹：真实载荷 payload_bytes 个零字节，头部声明 declared。

    压缩流式写入（不物化 64MiB 明文：1MiB 块循环），随后把 payload/index.html
    的「解压后大小」在中央目录与本地头里都改成 declared（< 上限 → 声明预检
    放行）。CRC 仍是全量载荷的（伪造头场景的典型形态），真实解压超过声明
    大小时由分块读取的 CRC/长度门拒绝。
    """
    name = b"payload/index.html"
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("manifest.json", json.dumps(_manifest()))
        with zf.open("payload/index.html", "w") as fp:
            zeros = b"\0" * (1024 * 1024)
            for _ in range(payload_bytes // len(zeros)):
                fp.write(zeros)
    data = bytearray(buf.getvalue())
    # 本地文件头 PK\x03\x04：解压大小 +22、文件名长度 +26、文件名 +30；
    # 中央目录 PK\x01\x02：解压大小 +24、文件名长度 +28、文件名 +46。
    for sig, size_offset, fnlen_offset, name_offset in (
            (b"PK\x03\x04", 22, 26, 30),
            (b"PK\x01\x02", 24, 28, 46)):
        pos = 0
        while True:
            pos = data.find(sig, pos)
            if pos < 0:
                break
            fn_len = int.from_bytes(data[pos + fnlen_offset:
                                         pos + fnlen_offset + 2], "little")
            start = pos + name_offset
            if bytes(data[start:start + fn_len]) == name:
                off = pos + size_offset
                data[off:off + 4] = declared.to_bytes(4, "little")
            pos += 4
    return bytes(data)


def _patch_compression(data: bytes, method: int = 99) -> bytes:
    """把 zip 内所有条目的压缩方法改成 [method]（本地头 +8 / 中央目录 +10）。

    99 是 zipfile 不支持的压缩方法：`zf.open()` 随即抛 NotImplementedError
    （评论 nonapp-4 的 500 实证形态）。
    """
    buf = bytearray(data)
    for sig, offset in ((b"PK\x03\x04", 8), (b"PK\x01\x02", 10)):
        pos = 0
        while True:
            pos = buf.find(sig, pos)
            if pos < 0:
                break
            off = pos + offset
            buf[off:off + 2] = method.to_bytes(2, "little")
            pos += 4
    return bytes(buf)


def _check_android_manifest(check) -> None:
    """nonapp-2：VIEW 的 mime 面与路径面必须是两条 filter。

    intent-filter 内 scheme/类型/路径各自集合内部 OR、集合之间 AND：混在同
    一条时，MIME 缺失（文件管理器对未知扩展名常报 null/octet-stream）就整条
    不匹配，`.nonapp` 后缀兜不住。
    """
    path = REPO_ROOT / "app/android/app/src/main/AndroidManifest.xml"
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as e:  # pragma: no cover - 结构性损坏
        check("android manifest parses", False, f"{type(e).__name__}: {e}")
        return
    ns = "{http://schemas.android.com/apk/res/android}"
    view_filters = []
    for f in root.iter("intent-filter"):
        actions = {a.get(ns + "name") for a in f.findall("action")}
        if "android.intent.action.VIEW" in actions:
            view_filters.append(f)
    check("android VIEW filters present", len(view_filters) >= 2, str(len(view_filters)))

    def datas(f):
        return [{k.replace(ns, ""): v for k, v in d.attrib.items()} for d in f.findall("data")]

    def schemes(f):
        return {d.get("scheme") for d in datas(f) if d.get("scheme")}

    def mimes(f):
        return {d.get("mimeType") for d in datas(f) if d.get("mimeType")}

    def paths(f):
        return {d.get("pathPattern") for d in datas(f) if d.get("pathPattern")}

    check("no VIEW filter mixes mimeType with pathPattern",
          all(not (mimes(f) and paths(f)) for f in view_filters),
          str([(sorted(mimes(f)), sorted(paths(f))) for f in view_filters]))
    suffix = [f for f in view_filters if any(".nonapp" in p for p in paths(f))]
    mime = [f for f in view_filters if mimes(f)]
    check("VIEW suffix filter kept", len(suffix) == 1, str(len(suffix)))
    check("VIEW suffix filter declares content+file schemes",
          len(suffix) == 1 and {"content", "file"} <= schemes(suffix[0]),
          str(suffix[0].attrib) if suffix else "missing")
    check("VIEW suffix filter has no mimeType",
          len(suffix) == 1 and not mimes(suffix[0]))
    check("VIEW mime filter present", len(mime) == 1, str(len(mime)))
    check("VIEW mime filter carries both types",
          len(mime) == 1
          and {"application/zip", "application/x-nondesign-package"} <= mimes(mime[0]),
          str(mime[0].attrib) if mime else "missing")
    check("VIEW mime filter has no pathPattern", len(mime) == 1 and not paths(mime[0]))
    default_cat = "android.intent.category.DEFAULT"
    check("every VIEW filter has DEFAULT category",
          all(default_cat in {c.get(ns + "name") for c in f.findall("category")}
              for f in view_filters))
    # SEND 面不参与 VIEW 拆分（分享面板只按 MIME）。
    send_mimes = set()
    for f in root.iter("intent-filter"):
        if "android.intent.action.SEND" in {a.get(ns + "name") for a in f.findall("action")}:
            send_mimes |= mimes(f)
    check("SEND filter keeps zip types", {"application/zip",
                                          "application/x-nondesign-package"} <= send_mimes,
          str(send_mimes))


def _flutter_ios_framework() -> Path | None:
    """定位 Flutter iOS 引擎产物（Flutter.framework 所在目录）。"""
    roots: list[Path] = []
    env = Path.home() / ".flutter_sdk"
    if env.exists():
        roots.append(env)
    which = shutil.which("flutter")
    if which:
        roots.append(Path(which).resolve().parent.parent)
    for root in roots:
        fw = root / "bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64"
        if (fw / "Flutter.framework").exists():
            return fw
    return None


def _check_ios_scene(check) -> None:
    """nonapp-1：SceneDelegate 接住 UIScene 的两条 URL 入口，并能真编译。"""
    scene = (REPO_ROOT / "app/ios/Runner/SceneDelegate.swift").read_text(encoding="utf-8")
    appdelegate = (REPO_ROOT / "app/ios/Runner/AppDelegate.swift").read_text(encoding="utf-8")
    check("SceneDelegate handles scene willConnectTo",
          "willConnectTo" in scene and "connectionOptions.urlContexts" in scene, scene[:200])
    check("SceneDelegate handles scene openURLContexts", "openURLContexts" in scene)
    check("SceneDelegate funnels into NonAppOpenInbox",
          "NonAppOpenInbox.shared.push" in scene)
    check("AppDelegate.materialize is reusable (not private)",
          "static func materialize" in appdelegate
          and "private static func materialize" not in appdelegate)

    if sys.platform != "darwin" or shutil.which("swiftc") is None:
        print("[skip] swiftc/iOS toolchain unavailable (not macOS)")
        return
    try:
        sdk = subprocess.check_output(
            ["xcrun", "--sdk", "iphoneos", "--show-sdk-path"],
            text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        print("[skip] iphoneos SDK unavailable")
        return
    if not sdk or not Path(sdk).exists():
        print("[skip] iphoneos SDK unavailable")
        return
    framework = _flutter_ios_framework()
    if framework is None:
        print("[skip] Flutter iOS framework unavailable (run sync_engine / flutter precache)")
        return
    with tempfile.TemporaryDirectory() as td:
        # 真实 GeneratedPluginRegistrant 由 flutter build 生成（podspec 报备），
        # 仓库里没有——类型检查时用同签名桩顶替。
        stub = Path(td) / "GeneratedPluginRegistrant.swift"
        stub.write_text(
            "import Flutter\n"
            "enum GeneratedPluginRegistrant {\n"
            "  static func register(with registry: FlutterPluginRegistry) {}\n"
            "}\n",
            encoding="utf-8")
        proc = subprocess.run(
            ["xcrun", "--sdk", "iphoneos", "swiftc", "-typecheck", "-parse-as-library",
             "-target", "arm64-apple-ios15.0", "-sdk", sdk, "-F", str(framework),
             str(REPO_ROOT / "app/ios/Runner/SceneDelegate.swift"),
             str(REPO_ROOT / "app/ios/Runner/AppDelegate.swift"),
             str(stub)],
            capture_output=True, text=True)
        detail = (proc.stderr or proc.stdout).strip()[-900:]
        check("swiftc -typecheck SceneDelegate + AppDelegate", proc.returncode == 0, detail)


def _check_offline_csp(check, server_csp: str) -> None:
    """nonapp-5：离线缓存注入的 CSP meta 必须与服务端同款。"""
    dart_src = (REPO_ROOT / "app/lib/core/nonapp_package.dart").read_text(encoding="utf-8")
    match = re.search(r'const String nonAppOfflineCsp =\s*((?:"[^"]*"\s*)+);', dart_src, re.S)
    check("dart offline CSP constant present", match is not None)
    if match is None:
        return
    dart_csp = "".join(re.findall(r'"([^"]*)"', match.group(1)))
    normalize = lambda s: "".join(s.split())  # noqa: E731 - 仅规整空白
    check("offline CSP mirrors server _HOTAPP_PAGE_CSP",
          normalize(dart_csp) == normalize(server_csp),
          f"dart={dart_csp!r} server={server_csp!r}")
    cache_src = (REPO_ROOT / "app/lib/core/nonapp_cache.dart").read_text(encoding="utf-8")
    check("offline cache injects CSP before writing",
          "injectNonAppCsp(" in cache_src and "writeAsBytes(safeBytes" in cache_src)
    hotapp_src = (REPO_ROOT / "app/lib/widgets/hotapp_workspace.dart").read_text(encoding="utf-8")
    check("webview navigation whitelist wired",
          "onNavigationRequest" in hotapp_src and "hotAppNavigationAllowed(" in hotapp_src)


def main() -> int:
    failures: list[str] = []

    def check(name: str, cond: bool, detail: str = "") -> None:
        if not cond:
            failures.append(f"{name}: {detail}")

    def expect_code(name: str, fn, needle: str) -> None:
        try:
            fn()
        except hotapp.HotAppError as e:
            check(name, needle in str(e), f"got {e!r} (want {needle})")
        except Exception as e:  # noqa: BLE001 - 测试要区分错误类型
            check(name, False, f"wrong exception {type(e).__name__}: {e}")
        else:
            check(name, False, f"no exception (want {needle})")

    def install(data: bytes, hint: str | None = None) -> dict:
        return asyncio.run(nonapp.install_package(data, hint))

    def install_err(name: str, data: bytes, needle: str) -> None:
        expect_code(name, lambda: install(data), needle)

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        portfolio = tmp / "portfolio" / "index.json"
        outside = tmp / "outside"
        outside.mkdir()
        sentinel = outside / "keep.txt"
        sentinel.write_text("do not delete", "utf-8")

        src_root = tmp / "src"
        dst_root = tmp / "dst"
        src_root.mkdir()
        # 旧目录迁移只在 HOTAPP_ROOT.parent 下找 hotapp/ a2ui/——临时根名避开两者。
        with mock.patch.object(hotapp, "HOTAPP_ROOT", src_root), \
                mock.patch.object(hotapp, "PORTFOLIO_FILE", portfolio):
            # ---- 1) 导出（html） ----
            d = src_root / "demo-app"
            d.mkdir()
            (d / "index.html").write_text(_html(), "utf-8")
            (d / "meta.json").write_text(json.dumps({
                "name": "demo-app", "title": "演示应用", "brief": "一句话",
                "createdAt": 1_700_000_000, "updatedAt": 1_700_000_001, "kind": "hotapp",
            }), "utf-8")

            pkg = nonapp.build_package("demo-app")
            with zipfile.ZipFile(io.BytesIO(pkg)) as zf:
                names = sorted(zf.namelist())
                check("export entry names", names == ["manifest.json", "payload/index.html"], str(names))
                manifest = json.loads(zf.read("manifest.json").decode("utf-8"))
            check("manifest formatVersion", manifest.get("formatVersion") == 1, str(manifest))
            check("manifest id derived", manifest.get("id") == "demo-app", str(manifest))
            check("manifest name", manifest.get("name") == "demo-app", str(manifest))
            check("manifest title", manifest.get("title") == "演示应用", str(manifest))
            check("manifest renderer", manifest.get("renderer") == "html", str(manifest))
            check("manifest createdAt", manifest.get("createdAt") == 1_700_000_000, str(manifest))
            check("manifest minAppVersion", manifest.get("minAppVersion") == "0.1.0", str(manifest))
            check("manifest brief", manifest.get("brief") == "一句话", str(manifest))

            expect_code("export missing app", lambda: nonapp.build_package("ghost"),
                        "no_app:ghost")
            expect_code("export bad name", lambda: nonapp.build_package("../etc"),
                        "invalid_name")

        # ---- 1b) 导入（html）到空根 ----
        with mock.patch.object(hotapp, "HOTAPP_ROOT", dst_root), \
                mock.patch.object(hotapp, "PORTFOLIO_FILE", portfolio):
            res = install(pkg, "demo-app.nonapp")
            check("import ok", res.get("ok") is True, str(res))
            check("import renderer", res.get("renderer") == "html", str(res))
            check("import id", res.get("id") == "demo-app", str(res))
            check("import formatVersion", res.get("formatVersion") == 1, str(res))
            check("import portfolio flag", res.get("portfolio") is True, str(res))

            target = dst_root / "demo-app"
            check("import dir exists", target.is_dir(), str(target))
            check("import html content", (target / "index.html").read_text("utf-8") == _html())
            meta = json.loads((target / "meta.json").read_text("utf-8"))
            for key, want in (("renderer", "html"), ("nonappId", "demo-app"),
                              ("formatVersion", 1), ("kind", "hotapp")):
                check(f"import meta.{key}", meta.get(key) == want, str(meta))
            check("import meta importedAt", isinstance(meta.get("importedAt"), int), str(meta))

            pl = hotapp.portfolio_list()
            entry = next((e for e in pl["items"]
                          if e.get("kind") == "hotapp" and e.get("ref") == "demo-app"), None)
            check("portfolio entry present", entry is not None, str(pl))
            if entry:
                check("portfolio renderer html", entry.get("renderer") == "html", str(entry))
                check("portfolio detail", entry.get("detail") == "导入的 .nonapp", str(entry))
                check("portfolio path index.html", entry.get("path", "").endswith("index.html"),
                      str(entry))

            # 失败路径不留半成品：物化临时目录只应存在真实应用目录
            check("no staging leftovers",
                  all(not p.name.startswith((".import-", ".trash-")) for p in dst_root.iterdir()),
                  str([p.name for p in dst_root.iterdir()]))

            # ---- 2) a2ui 导入 ----
            a2ui_pkg = _a2ui_zip(id="list-app", name="list-app")
            res2 = install(a2ui_pkg)
            check("a2ui import ok", res2.get("ok") is True, str(res2))
            check("a2ui renderer", res2.get("renderer") == "a2ui", str(res2))
            a2ui_dir = dst_root / "list-app"
            check("a2ui surface.json written", (a2ui_dir / "surface.json").exists(), str(a2ui_dir))
            check("a2ui data.json written", (a2ui_dir / "data.json").exists(), str(a2ui_dir))
            check("a2ui no index.html", not (a2ui_dir / "index.html").exists(), str(a2ui_dir))

            names = [a["name"] for a in hotapp.list_apps()["apps"]]
            check("a2ui not in /hotapp/list", "list-app" not in names, str(names))
            check("html app in /hotapp/list", "demo-app" in names, str(names))

            a2 = nonapp.read_a2ui("list-app")
            check("read_a2ui messages list", isinstance(a2.get("messages"), list)
                  and len(a2["messages"]) == 2, str(a2)[:200])
            expect_code("read_a2ui not a2ui", lambda: nonapp.read_a2ui("demo-app"),
                        "not_a2ui:demo-app")
            expect_code("read_a2ui missing", lambda: nonapp.read_a2ui("ghost"), "no_app:ghost")

            pl2 = hotapp.portfolio_list()
            e2 = next((e for e in pl2["items"] if e.get("ref") == "list-app"), None)
            check("a2ui portfolio renderer", e2 is not None and e2.get("renderer") == "a2ui",
                  str(e2))
            check("a2ui portfolio path surface.json",
                  bool(e2) and str(e2.get("path", "")).endswith("surface.json"), str(e2))

            # export → import 再一致（a2ui 往返）
            exported_a2 = nonapp.build_package("list-app")
            with zipfile.ZipFile(io.BytesIO(exported_a2)) as zf:
                a2_names = sorted(zf.namelist())
            check("a2ui export entries",
                  a2_names == ["manifest.json", "payload/data.json", "payload/surface.json"],
                  str(a2_names))
            res3 = install(exported_a2)
            check("a2ui re-import (same id) overwrites", res3.get("ok") is True, str(res3))
            again = json.loads((a2ui_dir / "surface.json").read_text("utf-8"))
            check("a2ui surface normalized to array", isinstance(again, list), str(type(again)))

            info = nonapp.app_info("list-app")
            check("info a2ui renderer", info.get("renderer") == "a2ui" and info.get("exists") is True,
                  str(info))
            info_missing = nonapp.app_info("ghost")
            check("info missing ok+exists=false",
                  info_missing.get("ok") is True and info_missing.get("exists") is False,
                  str(info_missing))

            # ---- 3) 安全门 ----
            install_err("zip slip rejected",
                        _zip({"manifest.json": json.dumps(_manifest()),
                              "../evil.txt": "x"}), "nonapp_unexpected_entry:../evil.txt")
            install_err("absolute path rejected",
                        _zip({"manifest.json": json.dumps(_manifest()),
                              "/etc/passwd": "x"}), "nonapp_unexpected_entry:/etc/passwd")
            install_err("backslash rejected",
                        _zip({"manifest.json": json.dumps(_manifest()),
                              "payload\\index.html": "x"}), "nonapp_unexpected_entry")
            install_err("unlisted entry rejected",
                        _zip({"manifest.json": json.dumps(_manifest()),
                              "payload/evil.js": "x"}), "nonapp_unexpected_entry:payload/evil.js")
            install_err("bad zip rejected", b"not a zip at all", "nonapp_invalid_zip")
            # nonapp-4：zipfile 不支持的压缩方法（compress_type=99）在 zf.open
            # 抛 NotImplementedError——必须映射 nonapp_invalid_zip（400），
            # 不能漏成裸 500。
            bad_method = _patch_compression(_zip({
                "manifest.json": json.dumps(_manifest(id="bad-method", name="bad-method")),
                "payload/index.html": _html("bad-method-marker"),
            }))
            install_err("unsupported compression method rejected as bad zip",
                        bad_method, "nonapp_invalid_zip")
            install_err("oversized body rejected",
                        b"\0" * (nonapp.MAX_PACKAGE_BYTES + 1), "nonapp_too_large")

            many = {"manifest.json": json.dumps(_manifest())}
            many.update({f"payload/x{i}.js": "1" for i in range(nonapp.MAX_ENTRIES)})
            install_err("entry count limit", _zip(many), "nonapp_too_large")

            install_err("single entry size limit",
                        _zip({"manifest.json": json.dumps(_manifest()),
                              "payload/index.html": b"\0" * (nonapp.MAX_ENTRY_BYTES + 1)}),
                        "nonapp_too_large")
            total_entries = {"manifest.json": json.dumps(_manifest())}
            for i in range(20):
                total_entries[f"payload/blob{i}.bin"] = b"\0" * (900 * 1024)
            install_err("total uncompressed limit", _zip(total_entries), "nonapp_too_large")

            install_err("manifest missing",
                        _zip({"payload/index.html": _html()}), "nonapp_missing_manifest")
            install_err("manifest not object",
                        _zip({"manifest.json": "[1,2]", "payload/index.html": _html()}),
                        "nonapp_invalid_manifest")
            install_err("bad formatVersion",
                        _zip({"manifest.json": json.dumps(_manifest(formatVersion=2)),
                              "payload/index.html": _html()}),
                        "nonapp_unsupported_version:2")
            install_err("bad name",
                        _zip({"manifest.json": json.dumps(_manifest(name="bad name")),
                              "payload/index.html": _html()}),
                        "nonapp_invalid_name")
            install_err("bad id",
                        _zip({"manifest.json": json.dumps(_manifest(id="Bad/Id")),
                              "payload/index.html": _html()}),
                        "nonapp_invalid_id")
            install_err("unknown renderer",
                        _zip({"manifest.json": json.dumps(_manifest(renderer="web")),
                              "payload/index.html": _html()}),
                        "nonapp_unsupported_renderer:web")
            install_err("missing html payload",
                        _zip({"manifest.json": json.dumps(_manifest())}),
                        "nonapp_missing_payload")
            install_err("missing a2ui payload",
                        _zip({"manifest.json": json.dumps(_manifest(renderer="a2ui"))}),
                        "nonapp_missing_payload")
            install_err("html external ref rejected",
                        _zip({"manifest.json": json.dumps(_manifest()),
                              "payload/index.html": _html().replace(
                                  "<canvas id=c>", '<img src="https://evil.com/x.png">')}),
                        "nonapp_html_invalid")
            install_err("html short rejected",
                        _zip({"manifest.json": json.dumps(_manifest()),
                              "payload/index.html": "<html>short</html>"}),
                        "nonapp_html_invalid")
            install_err("surface bad shape",
                        _zip({"manifest.json": json.dumps(_manifest(renderer="a2ui")),
                              "payload/surface.json": json.dumps({"nope": 1})}),
                        "nonapp_invalid_surface")
            install_err("data not object",
                        _zip({"manifest.json": json.dumps(_manifest(renderer="a2ui")),
                              "payload/surface.json": json.dumps(SURFACE_MESSAGES),
                              "payload/data.json": json.dumps([1, 2])}),
                        "nonapp_invalid_data")
            install_err("prompt too long",
                        _zip({"manifest.json": json.dumps(_manifest(renderer="a2ui")),
                              "payload/surface.json": json.dumps(SURFACE_MESSAGES),
                              "payload/prompt.txt": "x" * (nonapp.MAX_PROMPT_BYTES + 1)}),
                        "nonapp_invalid_prompt")

            # 目录项可容忍（“无目录项亦可”）；控制字符条目拒
            ok_dir_entry = _zip({"manifest.json": json.dumps(_manifest(id="dir-app", name="dir-app")),
                                 "payload/index.html": _html()}, dirs=("payload",))
            res_dir = install(ok_dir_entry)
            check("directory entry tolerated", res_dir.get("name") == "dir-app", str(res_dir))
            install_err("control char entry rejected",
                        _zip({"manifest.json": json.dumps(_manifest()),
                              "payload/\x01evil": "x"}), "nonapp_unexpected_entry")

            # a2ui 零外链门：basic 目录 Image/Video/AudioPlayer 会直接网络拉取，
            # dataModelUpdate 里的 URL 也会经绑定喂进组件——一律拒。
            install_err("a2ui component url rejected",
                        _zip({"manifest.json": json.dumps(_manifest(renderer="a2ui")),
                              "payload/surface.json": json.dumps([
                                  {"version": "1.0", "createSurface": {
                                      "surfaceId": "demo",
                                      "components": [
                                          {"id": "root", "component": "Image",
                                           "url": "https://evil.example/x.png"},
                                      ]}}])}),
                        "nonapp_a2ui_external_refs")
            install_err("a2ui dataModel url rejected",
                        _zip({"manifest.json": json.dumps(_manifest(renderer="a2ui")),
                              "payload/surface.json": json.dumps([
                                  {"version": "1.0", "createSurface": {
                                      "surfaceId": "demo", "components": [
                                          {"id": "root", "component": "Text", "text": "x"}]}},
                                  {"version": "1.0", "updateDataModel": {
                                      "surfaceId": "demo", "path": "/",
                                      "value": {"img": "//cdn.example/a.png"}}}])}),
                        "nonapp_a2ui_external_refs")

            # 解压炸弹（res-1）：真实 64MiB 零字节，头部声明 1000 字节。
            # 修复前 zf.read 会把整段 deflate 流一次解压（峰值 RSS ~375MB）；
            # 分块读取后内存上界是 MAX_ENTRY_BYTES，且声明与真实不符的条目
            # 在首个 CRC/长度检查处即被拒（nonapp_invalid_zip）。
            bomb = _bomb_zip()
            check("bomb package small on disk", len(bomb) < 512 * 1024, f"{len(bomb)} bytes")
            with zipfile.ZipFile(io.BytesIO(bomb)) as zf:
                declared = {i.filename: i.file_size for i in zf.infolist()}
            check("bomb declared size forged", declared.get("payload/index.html") == 1000,
                  str(declared))
            tracemalloc.start()
            try:
                install_err("decompression bomb rejected", bomb, "nonapp_invalid_zip")
                _, peak = tracemalloc.get_traced_memory()
            finally:
                tracemalloc.stop()
            # 修复前一次解压 64MiB 明文 → peak ≥ 64MiB；分块读取应远低于此。
            check("bomb peak memory bounded", peak < 16 * 1024 * 1024,
                  f"peak={peak / (1024 * 1024):.1f}MiB")

            # 服务端等价 HTML 门：<a href="https://…"> 服务端 _html_ok 接受
            # （正则只覆盖 script/link/img），导入必须成功且可 round-trip——
            # 客户端 parse 若比服务端严，导出→打开自家应用会断链（reviewer
            # nonapp-4）。
            linked = _html().replace(
                "<canvas id=c>", '<canvas id=c></canvas><a href="https://example.com/docs">文档</a>')
            res_linked = install(_zip({
                "manifest.json": json.dumps(_manifest(id="linked-app", name="linked-app")),
                "payload/index.html": linked,
            }))
            check("server-compat html with <a href> imports", res_linked.get("ok") is True,
                  str(res_linked))
            check("server-compat html content kept",
                  "example.com/docs" in (dst_root / "linked-app" / "index.html").read_text("utf-8"))
            res_relinked = install(nonapp.build_package("linked-app"))
            check("server-compat html round-trips", res_relinked.get("ok") is True,
                  str(res_relinked))

            # 失败不留半成品 + 目标目录未被破坏
            check("security gates leave no staging",
                  all(not p.name.startswith((".import-", ".trash-")) for p in dst_root.iterdir()),
                  str([p.name for p in dst_root.iterdir()]))
            check("outside sentinel intact", sentinel.exists())

            # ---- 4) 同名策略 ----
            upgrade = _zip({"manifest.json": json.dumps(_manifest(title="升级版")),
                            "payload/index.html": _html("marker-β")})
            res_up = install(upgrade)
            check("same id overwrites", res_up.get("ok") is True and res_up.get("title") == "升级版",
                  str(res_up))
            check("overwrite replaced content",
                  "marker-β" in (dst_root / "demo-app" / "index.html").read_text("utf-8"))
            conflict = _zip({"manifest.json": json.dumps(_manifest(id="other-id")),
                             "payload/index.html": _html("marker-γ")})
            install_err("same name different id rejected", conflict, "app_exists:demo-app")
            check("conflict left original intact",
                  "marker-β" in (dst_root / "demo-app" / "index.html").read_text("utf-8"))

            # ---- 4b) 生成目录（meta 无 nonappId）导出 → 重导 ----
            # hotapp_agent.generate 从不写 nonappId；_conflict/_promote 必须按
            # 导出时同一规则 _derive_id(name) 兜底，否则「导出自家生成的应用
            # 再导回」必得 app_exists（重导只能删应用，连 app.db 一起丢——
            # review nonapp-3）。
            gen = dst_root / "probe-gen"
            gen.mkdir()
            (gen / "index.html").write_text(_html("gen-marker"), "utf-8")
            (gen / "meta.json").write_text(json.dumps({
                "name": "probe-gen", "title": "生成的应用", "brief": "生成",
                "createdAt": 1_700_000_000, "updatedAt": 1_700_000_001, "kind": "hotapp",
            }), "utf-8")
            gen_pkg = nonapp.build_package("probe-gen")
            with zipfile.ZipFile(io.BytesIO(gen_pkg)) as zf:
                gen_manifest = json.loads(zf.read("manifest.json"))
            check("generated app manifest id derives from name",
                  gen_manifest["id"] == nonapp._derive_id("probe-gen"), str(gen_manifest))
            try:
                res_gen = install(gen_pkg)
            except hotapp.HotAppError as e:
                res_gen = {}
                check("re-import own generated export succeeds", False, f"raised {e!r}")
            else:
                check("re-import own generated export succeeds",
                      res_gen.get("ok") is True, str(res_gen))
            check("re-import keeps generated content",
                  "gen-marker" in (gen / "index.html").read_text("utf-8"))
            check("re-import stamps nonappId",
                  json.loads((gen / "meta.json").read_text("utf-8")).get("nonappId")
                  == nonapp._derive_id("probe-gen"))

            # ---- 5) 路由级 e2e（TestClient） ----
            import main as server_main  # noqa: E402  (import 注册全部路由)
            from fastapi.testclient import TestClient

            e2e = _zip({"manifest.json": json.dumps(_manifest(id="e2e-app", name="e2e-app",
                                                              title="端到端")),
                        "payload/index.html": _html("e2e-marker")})
            client = TestClient(server_main.app)
            r = client.post("/hotapp/import", content=e2e,
                            headers={"content-type": "application/zip"})
            check("route import 200", r.status_code == 200, f"{r.status_code} {r.text[:200]}")
            body = r.json() if r.status_code == 200 else {}
            check("route import envelope", body.get("ok") is True
                  and body.get("name") == "e2e-app" and body.get("portfolio") is True, str(body))

            r = client.get("/portfolio")
            items = r.json().get("items", []) if r.status_code == 200 else []
            hit = next((e for e in items if e.get("ref") == "e2e-app"), None)
            check("route portfolio has entry", hit is not None, str(items)[:300])

            r = client.get("/hotapp/page/e2e-app")
            check("route page 200", r.status_code == 200, str(r.status_code))
            check("route page keeps original html", "e2e-marker" in r.text)
            check("route page keeps CSP", "Content-Security-Policy" in r.headers)

            r = client.post("/hotapp/export", json={"name": "e2e-app"})
            check("route export 200", r.status_code == 200, f"{r.status_code} {r.text[:200]}")
            check("route export content-type", r.headers.get("content-type", "").startswith(
                "application/zip"), r.headers.get("content-type", ""))
            check("route export disposition",
                  'filename="e2e-app.nonapp"' in r.headers.get("content-disposition", ""),
                  r.headers.get("content-disposition", ""))
            exported = r.content
            with zipfile.ZipFile(io.BytesIO(exported)) as zf:
                check("route export roundtrip names",
                      sorted(zf.namelist()) == ["manifest.json", "payload/index.html"],
                      str(zf.namelist()))

            r = client.post("/hotapp/import", content=exported)
            check("route re-import same id overwrite", r.status_code == 200
                  and r.json().get("ok") is True, f"{r.status_code} {r.text[:200]}")

            # nonapp-4 路由面：不支持的压缩方法 → 稳定 400 信封（此前裸 500）。
            # TestClient 默认把服务端未处理异常重新抛出——回归时这里会炸出
            # traceback，因此显式捕获成 FAIL（异常本身就是缺陷形态）。
            try:
                r = client.post("/hotapp/import", content=bad_method)
            except Exception as e:  # noqa: BLE001 - 未处理异常 = 裸 500 缺陷
                check("route unsupported compression 400", False,
                      f"unhandled {type(e).__name__}: {e}")
            else:
                check("route unsupported compression 400", r.status_code == 400
                      and "nonapp_invalid_zip" in r.json().get("detail", ""),
                      f"{r.status_code} {r.text[:200]}")

            r = client.get("/hotapp/info/e2e-app")
            check("route info exists", r.status_code == 200 and r.json().get("exists") is True,
                  r.text[:200])
            r = client.get("/hotapp/info/ghost-app")
            check("route info missing ok+exists=false", r.status_code == 200
                  and r.json().get("exists") is False and r.json().get("ok") is True, r.text[:200])

            a2e2e = _a2ui_zip(id="e2e-a2ui", name="e2e-a2ui")
            r = client.post("/hotapp/import", content=a2e2e)
            check("route a2ui import", r.status_code == 200
                  and r.json().get("renderer") == "a2ui", r.text[:200])
            r = client.get("/hotapp/a2ui/e2e-a2ui")
            check("route a2ui messages", r.status_code == 200
                  and isinstance(r.json().get("messages"), list), r.text[:200])
            r = client.get("/hotapp/a2ui/e2e-app")
            check("route a2ui not_a2ui", r.status_code == 400
                  and "not_a2ui" in r.json().get("detail", ""), r.text[:200])

            r = client.post("/hotapp/export", json={"name": "ghost"})
            check("route export missing 400", r.status_code == 400
                  and "no_app" in r.json().get("detail", ""), r.text[:200])

            # 契约：端点只注册 POST——客户端若写成 GET 会 405（一边 POST 一边
            # GET 的错配必须在这里暴露）。
            r = client.get("/hotapp/export")
            check("route export rejects GET", r.status_code == 405, str(r.status_code))

            # ?name= 只作日志提示（目录名唯一来源是 manifest.name）
            hinted = _zip({"manifest.json": json.dumps(_manifest(id="hint-app", name="hint-app")),
                           "payload/index.html": _html("hint-marker")})
            r = client.post("/hotapp/import?name=whatever.nonapp", content=hinted)
            check("route import name hint ignored", r.status_code == 200
                  and r.json().get("name") == "hint-app", r.text[:200])

            # 413：Content-Length 预检路径（不读 body）
            r = client.post("/hotapp/import", content=b"\0" * (nonapp.MAX_PACKAGE_BYTES + 1))
            check("route import oversized 413", r.status_code == 413
                  and "nonapp_too_large" in r.json().get("detail", ""),
                  f"{r.status_code} {r.text[:200]}")

            # 413：无 Content-Length（chunked 流）时流式累加也必须立刻拒
            def _chunks():
                for _ in range((nonapp.MAX_PACKAGE_BYTES // (1024 * 1024)) + 2):
                    yield b"\0" * (1024 * 1024)

            r = client.post("/hotapp/import", content=_chunks())
            check("route import chunked oversized 413", r.status_code == 413
                  and "nonapp_too_large" in r.json().get("detail", ""),
                  f"{r.status_code} {r.text[:200]}")

            r = client.post("/hotapp/import", content=b"")
            check("route import empty 400", r.status_code == 400
                  and "nonapp_empty_body" in r.json().get("detail", ""), r.text[:200])

    # ---- 6) 客户端打开入口（nonapp-1 / nonapp-2）----
    _check_android_manifest(check)
    _check_ios_scene(check)
    # ---- 7) 离线 CSP 与服务端同款 + 注入/导航白名单接线（nonapp-5）----
    _check_offline_csp(check, server_main._HOTAPP_PAGE_CSP)

    if failures:
        print("FAIL")
        for item in failures:
            print(" -", item)
        return 1
    print("nonapp: all cases green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
