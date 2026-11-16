#!/usr/bin/env python3
"""_DocDeltaExtractor 单测（write_doc 流式 JSON 的 content 增量解码状态机）。

用法：.venv/bin/python scripts/wf/test_doc_delta.py （退出码 0 = 全绿）

server/agent.py 的提取器把 write_doc 工具参数的流式 JSON 分片喂进
seek_key → in_value → done 状态机，转义 / \\uXXXX 跨片由字段承载缓冲。
这里锚定它最容易碎的行为：分片边界切在转义中间、\\uXXXX hex 中间、
键名 `"content"` 中间，以及 done 后第二份文档的惰性自复位。
doc_written 全量事件仍是正确性兜底——本提取器只服务流式 UX。
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "server"))

from agent import _DocDeltaExtractor  # noqa: E402


def main() -> int:
    failures: list[str] = []

    def check(name: str, cond: bool, detail: str = "") -> None:
        if not cond:
            failures.append(f"{name}: {detail}")

    # ---- 1) 单次整段喂入：转义（\n \" \\ \/）与裸中文全量解码 ----
    content = '第一段\n第二行 "引号" 反斜杠\\斜杠/制表\t尾'
    args = json.dumps({"kind": "prd", "content": content}, ensure_ascii=False)
    x = _DocDeltaExtractor()
    check("single feed decodes escapes",
          x.feed(args) == content, repr(x.feed(args)))

    # ---- 2) 任意切分点两片喂入：拼接必须逐字等于原文 ----
    # buf 重放回归（agent.py 注释：case2 'a' 被二次输出）：已消费部分不得留存 buf。
    bad_cuts = []
    for cut in range(1, len(args) - 1):
        y = _DocDeltaExtractor()
        out = y.feed(args[:cut]) + y.feed(args[cut:])
        if out != content:
            bad_cuts.append((cut, repr(out)))
    check("every split point exact", not bad_cuts, str(bad_cuts[:3]))

    # ---- 3) 逐字符喂入（最细粒度流式） ----
    z = _DocDeltaExtractor()
    out = "".join(z.feed(ch) for ch in args)
    check("byte-by-byte exact", out == content, repr(out))

    # ---- 4) ensure_ascii 线格式（全部 \\uXXXX 转义）任意切分 ----
    uni_content = "中文\u4e2d\u6587符"
    uni_args = json.dumps({"content": uni_content}, ensure_ascii=True)
    bad_uni = []
    for cut in range(1, len(uni_args) - 1):
        y = _DocDeltaExtractor()
        out = y.feed(uni_args[:cut]) + y.feed(uni_args[cut:])
        if out != uni_content:
            bad_uni.append((cut, repr(out)))
    check("unicode-escaped every split exact", not bad_uni, str(bad_uni[:3]))

    # ---- 5) 转义序列跨片切断：片尾孤 `\`、hex 中断的 \\uXXXX ----
    a = _DocDeltaExtractor()
    prefix = a.feed('{"content":"行尾\\')  # 片尾 `\`：前缀照常输出，转义状态挂起
    check("lone backslash held",
          prefix == "行尾" and a.escape and not a.done, repr(prefix))
    check("escape completed next chunk", a.feed('n续"}') == "\n续", "")
    b = _DocDeltaExtractor()
    out1 = b.feed('{"content":"\\u4e')  # \u 收到 2/4 hex 即断
    check("partial unicode held", out1 == "" and b.uni == "4e", f"out={out1!r} uni={b.uni!r}")
    check("unicode completed next chunk", b.feed('2d"}') == "中", "")

    # ---- 6) 非法 unicode 转义回落字面：已收 hex 照输出、当前字符原样过 ----
    c = _DocDeltaExtractor()
    got_c = c.feed('{"content":"a\\u12G b"}')
    check("bad unicode escape falls back literal", got_c == "a12G b", repr(got_c))
    d = _DocDeltaExtractor()
    got_d = d.feed('{"content":"\\uZ"}')
    check("non-hex right after \\u passes through", got_d == "Z", repr(got_d))

    # ---- 7) done 后惰性自复位：plan 同 run 第二份 write_doc（ui）继续直播 ----
    e = _DocDeltaExtractor()
    first = e.feed('{"kind":"prd","content":"第一份"}')
    check("first doc extracted", first == "第一份" and e.done, repr(first))
    second = e.feed('垃圾尾巴}{"kind":"ui","content":"第二份"}')
    check("second doc extracted after lazy reset", second == "第二份", repr(second))

    # ---- 8) 键名 `"content"` 被切在片间：尾部保留拼回完整键 ----
    f = _DocDeltaExtractor()
    check("split key held", f.feed('{"kind":"prd","con') == "", "tail must be held")
    check("split key completed", f.feed('tent":"后续"}') == "后续", "")

    # ---- 9) 值等于字串 "content" 不误触发：提取器静默，doc_written 兜底 ----
    # （JSON 字符串值里的引号必带反斜杠，`"content"` 九字面样只可能来自
    # 键或恰好的同值字符串——后者是 seek_key 的放弃分支。）
    g = _DocDeltaExtractor()
    decoy = '{"field":"content","content":"真文"}'
    got_g = g.feed(decoy)
    check("decoy content value stays silent", got_g == "", repr(got_g))

    # ---- 10) 空分片与无 content 键：不扰动状态 ----
    h = _DocDeltaExtractor()
    check("empty delta noop", h.feed("") == "", "")
    check("no content key yields nothing", h.feed('{"kind":"prd"}') == "", "")

    if failures:
        print("FAIL")
        for f in failures:
            print(" -", f)
        return 1
    print("doc delta: all cases green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
