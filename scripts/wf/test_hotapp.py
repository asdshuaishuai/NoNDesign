#!/usr/bin/env python3
"""热应用目录 / HTML 门 / 作品集索引单测（安全与数据完整性回归）。

用法：.venv/bin/python scripts/wf/test_hotapp.py （退出码 0 = 全绿）

覆盖：
  1) _app_dir 名称校验：路径分隔符、..、Unicode 中文、超长名一律拒绝，
     合法名放行；HOTAPP_ROOT 全程指向临时目录（绝不写 ~/Documents）。
  2) portfolio_delete 的 hotapp 分支：空串 / .. / 绝对路径 / 超长 ref 均
     HotAppError 且不越界删除（临时根外哨兵文件必存活）；kind 白名单。
  3) _html_ok / _extract_html 边界：外链（http(s)、//、绝对路径）拒绝，
     data:/blob: 放行；围栏与裸码提取、无 HTML 报错。
  4) portfolio_upsert/remove/list：同 kind/ref 去重、缺失文件剔除、
     存量 mp4/3d 补扫、video/three 隐藏后不被补扫复活、重新 upsert 恢复。
  5) SQLite 持久层：建表/参数化写入/查询、字面量不误伤、单语句与
     ATTACH/PRAGMA/VACUUM 拒绝、非标量参数拒绝、缺应用拒绝，页面注入
     window.NoN.db 桥。
  6) 旧目录迁移：a2ui 应用并入 hotapps，旧作品集条目归一为 hotapp 且路径自愈。
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "server"))

import hotapp_agent as hotapp  # noqa: E402


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
        except hotapp.HotAppError as e:
            check(name, needle in str(e), str(e))
        except Exception as e:  # noqa: BLE001 - 测试要区分错误类型
            check(name, False, f"wrong exception {type(e).__name__}: {e}")
        else:
            check(name, False, "no exception raised")

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        root = tmp / "hotapp"
        root.mkdir()
        outside = tmp / "outside"
        outside.mkdir()
        sentinel = outside / "keep.txt"
        sentinel.write_text("do not delete", "utf-8")
        home = tmp / "home"
        (home / "Documents").mkdir(parents=True)
        portfolio = tmp / "portfolio" / "index.json"

        with mock.patch.object(hotapp, "HOTAPP_ROOT", root), \
                mock.patch.object(hotapp, "PORTFOLIO_FILE", portfolio), \
                mock.patch("pathlib.Path.home", return_value=home):
            # ---- 1) _app_dir 名称校验 ----
            d = hotapp._app_dir("bounce-demo_2")
            check("valid name maps under root", d == root / "bounce-demo_2", str(d))
            check("64-char name accepted", hotapp._app_dir("a" * 64).name == "a" * 64)

            for bad in ("", "..", ".", "a/b", "a\\b", "../escape", "/tmp/evil",
                        "中文应用", "a" * 65, "a\x00b", "a b"):
                expect_error(f"reject name {bad!r}", lambda b=bad: hotapp._app_dir(b), "invalid_name")

            # ---- 2) portfolio_delete 越界防护（HOTAPP_ROOT 已临时化） ----
            for bad_ref in ("", "..", str(outside), "../outside", "a" * 65):
                expect_error(
                    f"portfolio_delete rejects ref {bad_ref!r}",
                    lambda r=bad_ref: hotapp.portfolio_delete("hotapp", r),
                )
                check(f"sentinel survives ref {bad_ref!r}", sentinel.exists())
                check(f"hotapp root survives ref {bad_ref!r}", root.exists())
            expect_error("portfolio_delete rejects unknown kind",
                         lambda: hotapp.portfolio_delete("shell", "x"), "invalid_kind")

            good = root / "good-app"
            good.mkdir()
            (good / "index.html").write_text(_doc(), "utf-8")
            hotapp.portfolio_upsert("hotapp", "good-app", "good", str(good / "index.html"))
            hotapp.portfolio_delete("hotapp", "good-app")
            check("valid hotapp delete removes app dir", not good.exists())
            check("sentinel survives valid delete", sentinel.exists())

            # ---- 3) _html_ok / _extract_html 边界 ----
            check("valid inline doc passes", hotapp._html_ok(_doc()) is True)
            check("missing body rejected",
                  hotapp._html_ok("<!doctype html><html>" + "y" * 220 + "</html>") is False)
            check("too short rejected", hotapp._html_ok("<html><body>x</body></html>") is False)

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
                             lambda f=fragment: hotapp._html_ok(_doc(f)), "html_external_refs")

            inline_media = (
                '<img src="data:image/png;base64,AAAA">'
                "<style>body{background:url(data:image/svg+xml;base64,AAAA)}</style>"
                '<video src="blob:https://local/x"></video>'
            )
            check("data:/blob: refs allowed", hotapp._html_ok(_doc("x" * 220 + inline_media)) is True)

            fenced = "说明文字\n```html\n" + _doc() + "\n```\n后记"
            extracted = hotapp._extract_html(fenced)
            check("fenced html extracted", extracted.lstrip().lower().startswith("<!doctype html>"), repr(extracted[:40]))
            check("fenced extraction trimmed", extracted.endswith("\n"), repr(extracted[-10:]))

            bare = "前言。\n" + _doc()
            check("bare doctype extracted",
                  hotapp._extract_html(bare).lstrip().lower().startswith("<!doctype html>"))
            html_only = "<html><body>" + "z" * 220 + "</body></html>"
            check("bare <html> extracted", hotapp._extract_html(html_only).startswith("<html>"))
            expect_error("no html rejected", lambda: hotapp._extract_html("只有散文"), "html_parse_failed")
            expect_error("empty rejected", lambda: hotapp._extract_html(""), "html_parse_failed")

            # 运行错误回传桥：page_html 在 </body> 前注入（WebView → NONHOTAPP）
            bridge_app = root / "bridge-app"
            bridge_app.mkdir()
            (bridge_app / "index.html").write_text(_doc(), "utf-8")
            page = hotapp.page_html("bridge-app")
            check("page_html injects NONHOTAPP bridge", "NONHOTAPP" in page and "unhandledrejection" in page)
            check("bridge injected before body close", page.rfind("NONHOTAPP") < page.lower().rfind("</body>"))

            # ---- 5) SQLite 持久层（每应用 app.db，参数化、单语句、无危险关键字） ----
            db_app = root / "db-app"
            db_app.mkdir()
            (db_app / "index.html").write_text(_doc(), "utf-8")
            created = hotapp.db_exec(
                "db-app", "CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY, text TEXT)")
            check("db create table", created["ok"] and created["columns"] == [], repr(created))
            inserted = hotapp.db_exec("db-app", "INSERT INTO notes(text) VALUES(?)", ["第一条"])
            check("db insert rowcount", inserted["rowcount"] == 1, repr(inserted))
            check("db lastrowid", inserted["lastrowid"] == 1, repr(inserted))
            selected = hotapp.db_exec("db-app", "SELECT id, text FROM notes ORDER BY id")
            check("db select columns", selected["columns"] == ["id", "text"], repr(selected))
            check("db select rows", selected["rows"] == [[1, "第一条"]], repr(selected))
            check("db file on disk", (db_app / "app.db").exists())

            # 参数必须绑定（不拼 SQL）：注入串只当文本存
            hotapp.db_exec("db-app", "INSERT INTO notes(text) VALUES(?)",
                           ["x'); DROP TABLE notes;--"])
            count = hotapp.db_exec("db-app", "SELECT COUNT(*) FROM notes")
            check("params are bound not concatenated", count["rows"] == [[2]], repr(count))

            # 字面量里的危险词不误伤（单/双引号字符串都先剥离再扫关键字）
            hotapp.db_exec("db-app", "INSERT INTO notes(text) VALUES('PRAGMA is just text')")
            hotapp.db_exec("db-app", 'INSERT INTO notes(text) VALUES("VACUUM is just text")')
            count = hotapp.db_exec("db-app", "SELECT COUNT(*) FROM notes")
            check("literal keywords allowed", count["rows"] == [[4]], repr(count))

            for label, bad_sql in (
                ("pragma", "PRAGMA table_info(notes)"),
                ("attach", "ATTACH DATABASE '/tmp/evil.db' AS evil"),
                ("detach", "DETACH DATABASE evil"),
                ("vacuum", "VACUUM"),
                ("load_extension", "SELECT load_extension('evil')"),
            ):
                expect_error(f"db rejects {label}", lambda s=bad_sql: hotapp.db_exec("db-app", s),
                             "sql_forbidden")
            expect_error("db rejects multiple statements",
                         lambda: hotapp.db_exec("db-app", "SELECT 1; SELECT 2"), "invalid_sql")
            expect_error("db rejects empty sql", lambda: hotapp.db_exec("db-app", "   "), "invalid_sql")
            expect_error("db rejects non-scalar params",
                         lambda: hotapp.db_exec("db-app", "SELECT ?", [{"a": 1}]), "invalid_params")
            expect_error("db rejects missing app",
                         lambda: hotapp.db_exec("missing-app", "SELECT 1"), "no_app")

            # 页面注入 window.NoN.db 桥（同源 fetch + 应用名内嵌）
            db_page = hotapp.page_html("db-app")
            check("page injects NoN.db bridge", "window.NoN.db" in db_page and "/hotapp/db/" in db_page)
            check("db bridge names the app", 'var APP="db-app"' in db_page)
            check("db bridge before body close", db_page.rfind("window.NoN.db") < db_page.lower().rfind("</body>"))

            # 桥必须早于应用自己的脚本：页面初始化就会 await NoN.db.exec，
            # 晚注入 = 首屏 `NoN is not defined`（Chromium 真机实证）。
            order_app = root / "order-app"
            order_app.mkdir()
            (order_app / "index.html").write_text(
                "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>"
                "<script id=\"app-script\">NoN.db.exec('SELECT 1')</script>"
                "x" * 220 + "</body></html>", "utf-8")
            order_page = hotapp.page_html("order-app")
            check("db bridge before app script",
                  order_page.find("window.NoN.db") < order_page.find('id="app-script"'),
                  f"bridge={order_page.find('window.NoN.db')} app={order_page.find('id=\\\"app-script\\\"')}")

            # 旧目录迁移：a2ui 应用并入 hotapps（同名不覆盖）
            legacy_app = tmp / "a2ui" / "legacy-app"
            legacy_app.mkdir(parents=True)
            (legacy_app / "index.html").write_text(_doc(), "utf-8")
            (legacy_app / "meta.json").write_text(
                json.dumps({"name": "legacy-app", "title": "旧应用", "updatedAt": 1}), "utf-8")
            legacy_page = hotapp.page_html("legacy-app")  # _app_dir 触发迁移
            check("legacy app migrated into hotapps",
                  (root / "legacy-app" / "index.html").exists() and not legacy_app.exists())
            check("legacy app page served", "window.NoN.db" in legacy_page)
            check("empty legacy root removed", not (tmp / "a2ui").exists())

            # ---- 4) 作品集索引：去重 / 剔除 / 补扫 / 隐藏 ----
            f1 = tmp / "one.html"
            f1.write_text("1", "utf-8")
            f2 = tmp / "two.html"
            f2.write_text("2", "utf-8")
            hotapp.portfolio_upsert("hotapp", "one", "旧标题", str(f1))
            hotapp.portfolio_upsert("hotapp", "one", "新标题", str(f1))
            hotapp.portfolio_upsert("hotapp", "two", "第二", str(f2))
            raw = json.loads(portfolio.read_text("utf-8"))
            one_entries = [e for e in raw["items"] if e["kind"] == "hotapp" and e["ref"] == "one"]
            check("upsert dedupes same kind/ref", len(one_entries) == 1, repr(raw["items"]))
            check("upsert keeps newest title", one_entries and one_entries[0]["title"] == "新标题")

            listed = hotapp.portfolio_list()["items"]
            check("list returns registered files", {e["ref"] for e in listed if e["kind"] == "hotapp"} == {"one", "two"})

            f2.unlink()
            listed = hotapp.portfolio_list()["items"]
            check("missing file pruned", all(e["ref"] != "two" for e in listed), repr(listed))

            hotapp.portfolio_remove("hotapp", "one")
            listed = hotapp.portfolio_list()["items"]
            check("remove drops entry", all(e["ref"] != "one" for e in listed), repr(listed))

            # 存量补扫：临时 HOME 下的 video/3d 产物自动出现
            video_dir = home / "Documents" / "NoNDesign" / "video" / "clip1"
            video_dir.mkdir(parents=True)
            mp4 = video_dir / "frames.mp4"
            mp4.write_text("mp4", "utf-8")
            three_dir = home / "Documents" / "NoNDesign" / "3d" / "scene1"
            three_dir.mkdir(parents=True)
            (three_dir / "scene.js").write_text("// scene", "utf-8")

            listed = hotapp.portfolio_list()["items"]
            video_ref = str(mp4)
            check("existing video scanned", any(e["kind"] == "video" and e["ref"] == video_ref for e in listed))
            check("existing 3d scanned", any(e["kind"] == "three" and e["ref"] == "scene1" for e in listed))

            # video 删除 = 隐藏：补扫不得复活；重新 upsert 清除隐藏
            hotapp.portfolio_delete("video", video_ref)
            listed = hotapp.portfolio_list()["items"]
            check("hidden video not resurrected by scan",
                  all(not (e["kind"] == "video" and e["ref"] == video_ref) for e in listed))

            hotapp.portfolio_upsert("video", video_ref, "clip1", video_ref)
            listed = hotapp.portfolio_list()["items"]
            check("upsert clears hidden",
                  any(e["kind"] == "video" and e["ref"] == video_ref for e in listed))

            # 旧 A2UI 作品集条目：kind 归一为 hotapp，路径自愈到迁移后的 hotapps 目录
            raw = json.loads(portfolio.read_text("utf-8"))
            raw["items"].insert(0, {
                "kind": "a2ui", "ref": "legacy-app", "title": "旧A2UI",
                "path": str(tmp / "a2ui" / "legacy-app" / "index.html"), "ts": 1,
            })
            portfolio.write_text(json.dumps(raw, ensure_ascii=False), "utf-8")
            listed = hotapp.portfolio_list()["items"]
            legacy_entry = next((e for e in listed if e["ref"] == "legacy-app"), None)
            check("legacy a2ui entry normalized",
                  legacy_entry is not None and legacy_entry["kind"] == "hotapp", repr(legacy_entry))
            check("legacy a2ui path healed",
                  legacy_entry is not None
                  and Path(legacy_entry["path"]) == root / "legacy-app" / "index.html",
                  repr(legacy_entry))

            # 坏索引：改名 .bak 保留证据，不崩
            portfolio.write_text("{ not json", "utf-8")
            check("corrupt portfolio tolerated", hotapp.portfolio_list()["ok"] is True)
            check("corrupt portfolio backed up", portfolio.with_name(portfolio.name + ".bak").exists())

            # 坏 meta：list_apps 跳过坏应用而非整体 500
            bad_app = root / "bad-meta"
            bad_app.mkdir()
            (bad_app / "meta.json").write_text("{broken", "utf-8")
            ok_app = root / "ok-meta"
            ok_app.mkdir()
            (ok_app / "meta.json").write_text(
                json.dumps({"name": "ok-meta", "title": "OK", "updatedAt": 1}), "utf-8")
            apps = hotapp.list_apps()["apps"]
            check("bad meta skipped", all(a["name"] != "bad-meta" for a in apps), repr(apps))
            check("good app listed", any(a["name"] == "ok-meta" for a in apps), repr(apps))

        # 临时目录外不得出现任何 热应用 写入
        real_root = Path.home() / "Documents" / "NoNDesign" / "hotapps"
        check("no writes outside temp root", not (real_root / "bounce-demo_2").exists())

    if failures:
        print("FAIL")
        for f in failures:
            print(" -", f)
        return 1
    print("hotapp: all cases green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
