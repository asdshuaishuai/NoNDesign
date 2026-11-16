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
  7) 异步写路径（generate/refine/delete_app，mock LLM）：app_exists 拒绝、
     写失败清理半成品、refine fail-closed（坏回复/短 HTML 不覆盖旧版）、
     await 窗口外部删除 → no_app 而非裸 FileNotFoundError、_app_locks
     同名串行（并发 refine 无丢更新：后者读前者产物）、delete_app 清目录
     与作品集。
  8) db_exec_locked 与 delete 同锁串行：持锁删除期间 db_exec 必须等待；
     锁释放后重验 no_app，不得在已删目录里凭空重建 app.db（半删目录 +
     幽灵 app.db 卡死同名重建的竞态回归）。
"""

from __future__ import annotations

import asyncio
import json
import shutil
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

    # ---- 7) 异步写路径 + _app_locks 并发不变量 ----
    _run_async_write_cases(failures)

    if failures:
        print("FAIL")
        for f in failures:
            print(" -", f)
        return 1
    print("hotapp: all cases green")
    return 0


def _padded(marker: str) -> str:
    """带标记且总量过 _html_ok 200 字符门的正文。"""
    return f"{marker} " + "x" * 220


def _chat_returning(text: str):
    async def _fake(*args: object) -> str:
        return text
    return _fake


def _run_async_write_cases(failures: list[str]) -> None:
    """异步写路径（generate/refine/delete_app）与 _app_locks 串行不变量。"""
    asyncio.run(_async_write_cases(failures))


async def _async_write_cases(failures: list[str]) -> None:
    def check(name: str, cond: bool, detail: str = "") -> None:
        if not cond:
            failures.append(f"{name}: {detail}")

    async def expect_error(name: str, awaitable, needle: str = "") -> None:
        try:
            await awaitable
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
        portfolio = tmp / "portfolio" / "index.json"

        hotapp._app_locks.clear()  # 单 asyncio.run 单事件循环，锁状态从零开始

        with mock.patch.object(hotapp, "HOTAPP_ROOT", root), \
                mock.patch.object(hotapp, "PORTFOLIO_FILE", portfolio), \
                mock.patch("pathlib.Path.home", return_value=home):
            chat_ok = _chat_returning("```html\n" + _doc(_padded("gen-v1")) + "\n```")

            # generate 成功：落盘 + meta + 作品集登记
            with mock.patch.object(hotapp, "_chat", chat_ok):
                res = await hotapp.generate("gen-app", "生成测试", "m", "http://b", "k")
            check("generate ok", res.get("ok") is True and res.get("name") == "gen-app", repr(res))
            gen_file = root / "gen-app" / "index.html"
            check("generate writes index", gen_file.exists() and "gen-v1" in gen_file.read_text("utf-8"))
            gen_meta = json.loads((root / "gen-app" / "meta.json").read_text("utf-8"))
            check("generate writes meta", gen_meta.get("name") == "gen-app"
                  and gen_meta.get("kind") == "hotapp", repr(gen_meta))
            check("generate registers portfolio",
                  any(e.get("ref") == "gen-app" for e in hotapp.portfolio_list()["items"]))

            # generate 同名拒绝：app_exists 且不烧 LLM
            calls: list[object] = []

            async def chat_spy(*args: object) -> str:
                calls.append(args)
                return _doc(_padded("never"))

            with mock.patch.object(hotapp, "_chat", chat_spy):
                await expect_error("generate rejects existing name",
                                   hotapp.generate("gen-app", "再来", "m", "b", "k"), "app_exists")
            check("app_exists rejected without LLM call", not calls, str(len(calls)))

            # generate 写失败：半成品目录清干净，同名重试不被 app_exists 挡住
            def boom_write(path: Path, text: str) -> None:
                raise OSError("disk full")

            with mock.patch.object(hotapp, "_chat", chat_ok), \
                    mock.patch.object(hotapp, "_atomic_write", boom_write):
                await expect_error("generate write failure reported",
                                   hotapp.generate("wfail-app", "写盘失败", "m", "b", "k"),
                                   "app_write_failed")
            check("failed generate cleans half dir", not (root / "wfail-app").exists())

            with mock.patch.object(hotapp, "_chat", chat_ok):
                res2 = await hotapp.generate("wfail-app", "重试", "m", "b", "k")
            check("retry after cleanup succeeds",
                  res2.get("ok") is True and (root / "wfail-app" / "index.html").exists(), repr(res2))

            # refine 成功覆盖 + fail-closed 两路（坏回复 / 短 HTML 旧版保留）
            rapp = root / "ref-app"
            rapp.mkdir()
            (rapp / "index.html").write_text(_doc(_padded("ref-v0")), "utf-8")
            with mock.patch.object(hotapp, "_chat", _chat_returning(_doc(_padded("ref-v1")))):
                r = await hotapp.refine("ref-app", "改一版", "m", "b", "k")
            check("refine ok", r.get("ok") is True and r.get("reload") is True, repr(r))
            check("refine overwrites html",
                  "ref-v1" in (rapp / "index.html").read_text("utf-8"))

            with mock.patch.object(hotapp, "_chat", _chat_returning("抱歉，无法输出 HTML")):
                await expect_error("refine rejects non-html reply",
                                   hotapp.refine("ref-app", "x", "m", "b", "k"), "html_parse_failed")
            check("non-html reply keeps old version",
                  "ref-v1" in (rapp / "index.html").read_text("utf-8"))

            with mock.patch.object(hotapp, "_chat", _chat_returning("<html><body>短</body></html>")):
                await expect_error("refine rejects short html",
                                   hotapp.refine("ref-app", "x", "m", "b", "k"), "html_invalid")
            check("short html keeps old version",
                  "ref-v1" in (rapp / "index.html").read_text("utf-8"))

            await expect_error("refine missing app",
                               hotapp.refine("no-such-app", "x", "m", "b", "k"), "no_app")

            # await 窗口外部删除（portfolio_delete 是不持应用锁的同步删除路径）：
            # refine 回写前重查目录 → no_app 业务拒绝，不裸 FileNotFoundError
            dapp = root / "extdel-app"
            dapp.mkdir()
            (dapp / "index.html").write_text(_doc(_padded("ext-v0")), "utf-8")
            in_flight = asyncio.Event()
            release = asyncio.Event()

            async def chat_blocked(*args: object) -> str:
                in_flight.set()
                await release.wait()
                return _doc(_padded("ext-v2"))

            with mock.patch.object(hotapp, "_chat", chat_blocked):
                task = asyncio.create_task(hotapp.refine("extdel-app", "慢改", "m", "b", "k"))
                await asyncio.wait_for(in_flight.wait(), 5)
                hotapp.portfolio_delete("hotapp", "extdel-app")
                release.set()
                await expect_error("refine after external delete fails closed", task, "no_app")
            check("externally deleted dir stays gone", not dapp.exists())

            # _app_locks 同名串行：读 → await LLM → 写 窗口内第二个 refine
            # 必须等锁——它读到的是第一个的产物（丢更新整类消除），最终文件=后写
            lock_dir = root / "lock-app"
            lock_dir.mkdir()
            (lock_dir / "index.html").write_text(_doc(_padded("lock-v0")), "utf-8")
            seen: list[str] = []
            first_started = asyncio.Event()
            release_first = asyncio.Event()
            counter = {"n": 0}

            async def chat_seq(model: str, base_url: str, api_key: str,
                               system: str, user: str) -> str:
                seen.append(user)
                counter["n"] += 1
                if counter["n"] == 1:
                    first_started.set()
                    await release_first.wait()
                    return _doc(_padded("lock-v1"))
                return _doc(_padded("lock-v2"))

            with mock.patch.object(hotapp, "_chat", chat_seq):
                t1 = asyncio.create_task(hotapp.refine("lock-app", "第一改", "m", "b", "k"))
                await asyncio.wait_for(first_started.wait(), 5)
                t2 = asyncio.create_task(hotapp.refine("lock-app", "第二改", "m", "b", "k"))
                await asyncio.sleep(0.05)  # 给 t2 机会（错误地）抢进 chat
                check("second refine waits on app lock", len(seen) == 1, f"chat calls: {len(seen)}")
                release_first.set()
                r1, r2 = await t1, await t2
            check("both serialized refines ok",
                  r1.get("ok") is True and r2.get("ok") is True, f"{r1!r} {r2!r}")
            check("second refine reads first output",
                  len(seen) == 2 and "lock-v1" in seen[1], f"seen={len(seen)}")
            final_html = (lock_dir / "index.html").read_text("utf-8")
            check("final html is second refine output",
                  "lock-v2" in final_html and "lock-v1" not in final_html, repr(final_html[:60]))

            # delete_app：删目录 + 清作品集；缺失诚实 no_app
            fapp = root / "del-app"
            fapp.mkdir()
            (fapp / "index.html").write_text(_doc(), "utf-8")
            hotapp.portfolio_upsert("hotapp", "del-app", "待删", str(fapp / "index.html"))
            res3 = await hotapp.delete_app("del-app")
            check("delete_app ok", res3.get("ok") is True, repr(res3))
            check("delete_app removes dir", not fapp.exists())
            check("delete_app drops portfolio entry",
                  all(e.get("ref") != "del-app" for e in hotapp.portfolio_list()["items"]))
            await expect_error("delete_app missing", hotapp.delete_app("del-app"), "no_app")

            # ---- 8) db_exec_locked 与 delete 同锁（半删目录幽灵 app.db 竞态） ----
            # db_exec 是同步函数（def 路由跑线程池），与事件循环上的 delete 真并行；
            # 无锁时它的 index.html 检查与 sqlite3.connect（缺失文件即新建空库）
            # 之间无重验——与持锁 rmtree 交错会在半删目录里凭空重建 app.db。
            race = root / "dbrace-app"
            race.mkdir()
            (race / "index.html").write_text(_doc(), "utf-8")
            made = await hotapp.db_exec_locked(
                "dbrace-app", "CREATE TABLE IF NOT EXISTS t(x TEXT)")
            check("locked db create", made.get("ok") is True, repr(made))
            ins = await hotapp.db_exec_locked(
                "dbrace-app", "INSERT INTO t(x) VALUES(?)", ["甲"])
            check("locked db insert params flow", ins.get("rowcount") == 1, repr(ins))

            async with hotapp._lock_for("dbrace-app"):  # 模拟持锁 delete 进行中
                task = asyncio.create_task(
                    hotapp.db_exec_locked("dbrace-app", "SELECT COUNT(*) FROM t"))
                await asyncio.sleep(0.15)
                check("db_exec waits for app lock", not task.done(),
                      "db_exec ran concurrently with a lock-holding delete")
                shutil.rmtree(race)  # delete_app 在锁内做的就是这件事
            await expect_error("db_exec revalidates after lock release", task, "no_app")
            check("no ghost app dir after delete race", not race.exists(), str(race))
            check("no ghost app.db", not (race / "app.db").exists())

            check("async sentinel survives", sentinel.exists())


if __name__ == "__main__":
    raise SystemExit(main())
