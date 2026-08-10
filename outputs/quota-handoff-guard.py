# ~\.claude\scripts\quota-handoff-guard.py
"""5h 額度用到 90% 時，寫一份交接文件並在 log 記一筆。

由 statusline-command.ps1 在背景呼叫，整包 statusline JSON 從 stdin 進來。
同一個 5h 視窗只寫一次：交接文件的檔名就是去重標記，檔案已存在就直接結束。

自我檢查：python quota-handoff-guard.py --selftest
"""
import glob
import json
import os
import subprocess
import sys
import tempfile
import traceback
from datetime import datetime

THRESHOLD = 90
HOME = os.path.expanduser("~")
OUTDIR = os.path.join(HOME, ".claude", "handoff")


def log(msg):
    os.makedirs(OUTDIR, exist_ok=True)
    with open(os.path.join(OUTDIR, "handoff.log"), "a", encoding="utf-8") as f:
        f.write("%s  %s\n" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg))


def dig(o, *path):
    for k in path:
        if not isinstance(o, dict):
            return None
        o = o.get(k)
    return o


def git(cwd, *args):
    try:
        p = subprocess.run(("git", "-C", cwd) + args, capture_output=True,
                           encoding="utf-8", errors="replace", timeout=10)
        return p.stdout.strip() if p.returncode == 0 else ""
    except Exception:
        return ""


def clip(text, limit):
    return text if len(text) <= limit else text[:limit] + "\n…（截斷）"


def blocks_text(content):
    """把 message.content 攤平成純文字。thinking / tool_use / tool_result 一律不要。"""
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
        return ""  # 這是工具回傳，不是使用者講的話
    return "\n".join(b.get("text", "") for b in content
                     if isinstance(b, dict) and b.get("type") == "text").strip()


def conversation(session_id, keep=3):
    """從 ~/.claude/projects/*/<session_id>.jsonl 撈最後幾則使用者訊息與最後一則回覆。"""
    hits = glob.glob(os.path.join(HOME, ".claude", "projects", "*", session_id + ".jsonl"))
    if not hits:
        return [], ""
    users, last_reply = [], ""
    with open(hits[0], encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except ValueError:
                continue  # 檔案正被寫入，最後一行可能不完整
            if rec.get("isMeta"):
                continue
            text = blocks_text(dig(rec, "message", "content"))
            if not text:
                continue
            if rec.get("type") == "user":
                users.append(text)
            elif rec.get("type") == "assistant":
                last_reply = text
    return users[-keep:], last_reply


def render(data):
    cwd = dig(data, "workspace", "current_dir") or dig(data, "cwd") or ""
    session_id = dig(data, "session_id") or ""
    pct = int(float(dig(data, "rate_limits", "five_hour", "used_percentage")))
    resets = int(dig(data, "rate_limits", "five_hour", "resets_at") or 0)
    reset_str = datetime.fromtimestamp(resets).strftime("%m/%d %H:%M") if resets else "未知"
    model = dig(data, "model", "display_name") or dig(data, "model", "id") or "未知"
    effort = dig(data, "effort", "level")
    ctx = dig(data, "context_window", "used_percentage")

    out = [
        "# 交接文件：%s" % (os.path.basename(cwd.rstrip("\\/")) or "unknown"),
        "",
        "> 5h 額度即將見底，這份文件給接手的人／Codex 用。",
        "> 讀完下面的 git 變更與「最後回覆」，從那裡接續。",
        "",
        "- 產生時間：%s" % datetime.now().strftime("%Y-%m-%d %H:%M"),
        "- 觸發原因：5h 額度已用 %d%%（%s 重置）" % (pct, reset_str),
        "- Session：`%s`" % session_id,
        "- 模型：%s%s" % (model, "·" + effort if effort else ""),
    ]
    if ctx is not None:
        out.append("- Context：已用 %d%%" % int(float(ctx)))
    out.append("- 工作目錄：`%s`" % cwd)

    if cwd and os.path.isdir(cwd):
        status = git(cwd, "status", "--short")
        stat = git(cwd, "diff", "--stat", "HEAD")
        out += ["", "## Git", "",
                "分支：`%s`" % (git(cwd, "rev-parse", "--abbrev-ref", "HEAD") or "—"),
                "", "未提交的變更：", "```",
                clip("\n".join(x for x in (status, stat) if x) or "(無)", 3000), "```",
                "", "最近 commit：", "```",
                git(cwd, "log", "-5", "--oneline") or "(無)", "```"]

    users, reply = conversation(session_id)
    out += ["", "## 最近的對話", ""]
    if not users and not reply:
        out.append("（找不到 transcript，session 可能剛開或已被清掉）")
    for i, u in enumerate(users, 1):
        out += ["### 使用者 %d" % i, "", clip(u, 1500), ""]
    if reply:
        out += ["### 最後回覆", "", clip(reply, 3000), ""]
    return "\n".join(out) + "\n"


def run(raw):
    """回傳寫出的檔案路徑；沒達門檻或已寫過則回傳 None。"""
    data = json.loads(raw)
    session_id = dig(data, "session_id")
    pct = dig(data, "rate_limits", "five_hour", "used_percentage")
    if not session_id or pct is None or float(pct) < THRESHOLD:
        return None
    resets = int(dig(data, "rate_limits", "five_hour", "resets_at") or 0)
    path = os.path.join(OUTDIR, "handoff-%s-%d.md" % (session_id[:8], resets))
    if os.path.exists(path):
        return None  # 同一個 5h 視窗已經寫過
    os.makedirs(OUTDIR, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(render(data))
    log("寫入交接文件 %s（5h %d%%）" % (os.path.basename(path), int(float(pct))))
    return path


def selftest():
    global OUTDIR
    OUTDIR = tempfile.mkdtemp(prefix="handoff-selftest-")
    payload = {"session_id": "selftest-0001", "model": {"display_name": "Opus 5"},
               "effort": {"level": "high"}, "context_window": {"used_percentage": 42},
               "workspace": {"current_dir": os.getcwd()},
               "rate_limits": {"five_hour": {"used_percentage": 92, "resets_at": 1760000000}}}

    payload["rate_limits"]["five_hour"]["used_percentage"] = 89
    assert run(json.dumps(payload)) is None, "89% 不該觸發"

    payload["rate_limits"]["five_hour"]["used_percentage"] = 92
    path = run(json.dumps(payload))
    assert path and os.path.exists(path), "92% 該寫出交接文件"
    body = open(path, encoding="utf-8").read()
    assert "5h 額度已用 92%" in body, body[:400]
    assert "## Git" in body, "在 git repo 裡跑就該有 Git 區塊"
    assert run(json.dumps(payload)) is None, "同一視窗不該重寫"

    logged = open(os.path.join(OUTDIR, "handoff.log"), encoding="utf-8").read()
    assert logged.count("寫入交接文件") == 1, logged

    # 髒資料不該讓它整個炸掉
    assert run('{"session_id":"x"}') is None
    assert blocks_text([{"type": "tool_result", "content": "x"}]) == ""
    assert blocks_text([{"type": "thinking"}, {"type": "text", "text": "hi"}]) == "hi"
    print("selftest OK ->", OUTDIR)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        # 背景執行、視窗隱藏，例外沒人看得到，所以一律記進 log
        try:
            run(sys.stdin.read())
        except Exception:
            log("失敗：" + traceback.format_exc().replace("\n", " | "))
