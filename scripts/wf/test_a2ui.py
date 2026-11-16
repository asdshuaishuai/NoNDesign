#!/usr/bin/env python3
"""A2UI 应用目录 / HTML 门 / 作品集索引单测（安全与数据完整性回归）。

用法：.venv/bin/python scripts/wf/test_a2ui.py （退出码 0 = 全绿）

覆盖：
  1) _app_dir 名称校验：路径分隔符、..、Unicode 中文、超长名一律拒绝，
     合法名放行；A2UI_ROOT 全程指向临时目录（绝不写 ~/Documents）。
  2) portfolio_delete 的 a2ui 分支：空串 / .. / 绝对路径 / 超长 ref 均
     A2uiError 且不越界删除（临时根外哨兵文件必存活）；kind 白名单。
  3) _html_ok / _extract_html 边界：外链（http(s)、//、绝对路径）拒绝，
     data:/blob: 放行；围栏与裸码提取、无 HTML 报错。
  4) portfolio_upsert/remove/list：同 kind/ref 去重、缺失文件剔除、
     存量 mp4/3d 补扫、video/three 隐藏后不被补扫复活、重新 upsert 恢复。
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "server"))

import a2ui_agent as a2ui  # noqa: E402


def _doc(body: str = "x" * 220) -> str:
    return f"<!doctype html><html><body>{body}</body></html>"


def main() -> int:
    failures: list[str] = []

    def check(name: str, cond: bool, detail: str = "") -> None:
        if not cond:
            failures.append(f"{name}: {detail}")

    def expect_error(name: str, fn, needle: str = "") -> None:
        try:
            fn()
        except a2ui.A2uiError as e:
            check(name, needle in str(e), str(e))
        except Exception as e:  # noqa: BLE001 - 测试要区分错误类型
            check(name, False, f"wrong exception {type(e).__name__}: {e}")
        else:
            check(name, False, "no exception raised")

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        root = tmp / "a2ui"
        root.mkdir()
        outside = tmp / "outside"
        outside.mkdir()
        sentinel = outside / "keep.txt"
        sentinel.write_text("do not delete", "utf-8")
        home = tmp / "home"
        (home / "Documents").mkdir(parents=True)
        portfolio = tmp / "portfolio" / "index.json"

        with mock.patch.object(a2ui, "A2UI_ROOT", root), \
                mock.patch.object(a2ui, "PORTFOLIO_FILE", portfolio), \
                mock.patch("pathlib.Path.home", return_value=home):
            # ---- 1) _app_dir 名称校验 ----
            d = a2ui._app_dir("bounce-demo_2")
            check("valid name maps under root", d == root / "bounce-demo_2", str(d))
            check("64-char name accepted", a2ui._app_dir("a" * 64).name == "a" * 64)

            for bad in ("", "..", ".", "a/b", "a\\b", "../escape", "/tmp/evil",
                        "中文应用", "a" * 65, "a\x00b", "a b"):
                expect_error(f"reject name {bad!r}", lambda b=bad: a2ui._app_dir(b), "invalid_name")

            # ---- 2) portfolio_delete 越界防护（A2UI_ROOT 已临时化） ----
            for bad_ref in ("", "..", str(outside), "../outside", "a" * 65):
                expect_error(
                    f"portfolio_delete rejects ref {bad_ref!r}",
                    lambda r=bad_ref: a2ui.portfolio_delete("a2ui", r),
                )
                check(f"sentinel survives ref {bad_ref!r}", sentinel.exists())
                check(f"a2ui root survives ref {bad_ref!r}", root.exists())
            expect_error("portfolio_delete rejects unknown kind",
                         lambda: a2ui.portfolio_delete("shell", "x"), "invalid_kind")

            good = root / "good-app"
            good.mkdir()
            (good / "index.html").write_text(_doc(), "utf-8")
            a2ui.portfolio_upsert("a2ui", "good-app", "good", str(good / "index.html"))
            a2ui.portfolio_delete("a2ui", "good-app")
            check("valid a2ui delete removes app dir", not good.exists())
            check("sentinel survives valid delete", sentinel.exists())

            # ---- 3) _html_ok / _extract_html 边界 ----
            check("valid inline doc passes", a2ui._html_ok(_doc()) is True)
            check("missing body rejected",
                  a2ui._html_ok("<!doctype html><html>" + "y" * 220 + "</html>") is False)
            check("too short rejected", a2ui._html_ok("<html><body>x</body></html>") is False)

            for label, fragment in (
                ("script src https", '<script src="https://cdn.evil/x.js"></script>'),
                ("script src protocol-relative", "<script src='//cdn.evil/x.js'></script>"),
                ("link href https", '<link rel="stylesheet" href="https://cdn.evil/x.css">'),
                ("img src absolute path", '<img src="/static/x.png">'),
                ("img srcset absolute path", '<img srcset="/static/x.png 2x, /static/y.png 1x">'),
                ("css url https", "<style>body{background:url(https://cdn.evil/bg.png)}</style>"),
                ("css import https", '<style>@import url("https://cdn.evil/f.css");</style>'),
            ):
                expect_error(f"external ref rejected: {label}",
                             lambda f=fragment: a2ui._html_ok(_doc(f)), "html_external_refs")

            inline_media = (
                '<img src="data:image/png;base64,AAAA">'
                "<style>body{background:url(data:image/svg+xml;base64,AAAA)}</style>"
                '<video src="blob:https://local/x"></video>'
            )
            check("data:/blob: refs allowed", a2ui._html_ok(_doc("x" * 220 + inline_media)) is True)

            fenced = "说明文字\n```html\n" + _doc() + "\n```\n后记"
            extracted = a2ui._extract_html(fenced)
            check("fenced html extracted", extracted.lstrip().lower().startswith("<!doctype html>"), repr(extracted[:40]))
            check("fenced extraction trimmed", extracted.endswith("\n"), repr(extracted[-10:]))

            bare = "前言。\n" + _doc()
            check("bare doctype extracted",
                  a2ui._extract_html(bare).lstrip().lower().startswith("<!doctype html>"))
            html_only = "<html><body>" + "z" * 220 + "</body></html>"
            check("bare <html> extracted", a2ui._extract_html(html_only).startswith("<html>"))
            expect_error("no html rejected", lambda: a2ui._extract_html("只有散文"), "html_parse_failed")
            expect_error("empty rejected", lambda: a2ui._extract_html(""), "html_parse_failed")

            # 运行错误回传桥：page_html 在 </body> 前注入（WebView → NONA2UI）
            bridge_app = root / "bridge-app"
            bridge_app.mkdir()
            (bridge_app / "index.html").write_text(_doc(), "utf-8")
            page = a2ui.page_html("bridge-app")
            check("page_html injects NONA2UI bridge", "NONA2UI" in page and "unhandledrejection" in page)
            check("bridge injected before body close", page.rfind("NONA2UI") < page.lower().rfind("</body>"))

            # ---- 4) 作品集索引：去重 / 剔除 / 补扫 / 隐藏 ----
            f1 = tmp / "one.html"
            f1.write_text("1", "utf-8")
            f2 = tmp / "two.html"
            f2.write_text("2", "utf-8")
            a2ui.portfolio_upsert("a2ui", "one", "旧标题", str(f1))
            a2ui.portfolio_upsert("a2ui", "one", "新标题", str(f1))
            a2ui.portfolio_upsert("a2ui", "two", "第二", str(f2))
            raw = json.loads(portfolio.read_text("utf-8"))
            one_entries = [e for e in raw["items"] if e["kind"] == "a2ui" and e["ref"] == "one"]
            check("upsert dedupes same kind/ref", len(one_entries) == 1, repr(raw["items"]))
            check("upsert keeps newest title", one_entries and one_entries[0]["title"] == "新标题")

            listed = a2ui.portfolio_list()["items"]
            check("list returns registered files", {e["ref"] for e in listed if e["kind"] == "a2ui"} == {"one", "two"})

            f2.unlink()
            listed = a2ui.portfolio_list()["items"]
            check("missing file pruned", all(e["ref"] != "two" for e in listed), repr(listed))

            a2ui.portfolio_remove("a2ui", "one")
            listed = a2ui.portfolio_list()["items"]
            check("remove drops entry", all(e["ref"] != "one" for e in listed), repr(listed))

            # 存量补扫：临时 HOME 下的 video/3d 产物自动出现
            video_dir = home / "Documents" / "NoNDesign" / "video" / "clip1"
            video_dir.mkdir(parents=True)
            mp4 = video_dir / "frames.mp4"
            mp4.write_text("mp4", "utf-8")
            three_dir = home / "Documents" / "NoNDesign" / "3d" / "scene1"
            three_dir.mkdir(parents=True)
            (three_dir / "scene.js").write_text("// scene", "utf-8")

            listed = a2ui.portfolio_list()["items"]
            video_ref = str(mp4)
            check("existing video scanned", any(e["kind"] == "video" and e["ref"] == video_ref for e in listed))
            check("existing 3d scanned", any(e["kind"] == "three" and e["ref"] == "scene1" for e in listed))

            # video 删除 = 隐藏：补扫不得复活；重新 upsert 清除隐藏
            a2ui.portfolio_delete("video", video_ref)
            listed = a2ui.portfolio_list()["items"]
            check("hidden video not resurrected by scan",
                  all(not (e["kind"] == "video" and e["ref"] == video_ref) for e in listed))

            a2ui.portfolio_upsert("video", video_ref, "clip1", video_ref)
            listed = a2ui.portfolio_list()["items"]
            check("upsert clears hidden",
                  any(e["kind"] == "video" and e["ref"] == video_ref for e in listed))

            # 坏索引：改名 .bak 保留证据，不崩
            portfolio.write_text("{ not json", "utf-8")
            check("corrupt portfolio tolerated", a2ui.portfolio_list()["ok"] is True)
            check("corrupt portfolio backed up", portfolio.with_name(portfolio.name + ".bak").exists())

            # 坏 meta：list_apps 跳过坏应用而非整体 500
            bad_app = root / "bad-meta"
            bad_app.mkdir()
            (bad_app / "meta.json").write_text("{broken", "utf-8")
            ok_app = root / "ok-meta"
            ok_app.mkdir()
            (ok_app / "meta.json").write_text(
                json.dumps({"name": "ok-meta", "title": "OK", "updatedAt": 1}), "utf-8")
            apps = a2ui.list_apps()["apps"]
            check("bad meta skipped", all(a["name"] != "bad-meta" for a in apps), repr(apps))
            check("good app listed", any(a["name"] == "ok-meta" for a in apps), repr(apps))

        # 临时目录外不得出现任何 A2UI 写入
        real_root = Path.home() / "Documents" / "NoNDesign" / "a2ui"
        check("no writes outside temp root", not (real_root / "bounce-demo_2").exists())

    if failures:
        print("FAIL")
        for f in failures:
            print(" -", f)
        return 1
    print("a2ui: all cases green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
