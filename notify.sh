#!/bin/zsh
# Claude Code 훅에서 부른다. 사용: notify.sh prompt|stop|notification|end  (stdin = 훅 JSON)
# 세션 상태를 ~/.claude/bell/sessions/<세션 id>.json 에 쓰고, ClaudeBell(메뉴 막대 앱)이 그 폴더를 보고 알린다.
export BELL_EVENT="${1:-stop}"
export BELL_INPUT="$(cat)"

/usr/bin/python3 - <<'PY' 2>/dev/null
import json, os, subprocess, tempfile, time

event = os.environ.get("BELL_EVENT", "stop")
try:
    hook = json.loads(os.environ.get("BELL_INPUT") or "{}")
except Exception:
    hook = {}

session_id = hook.get("session_id") or "unknown"
cwd = hook.get("cwd") or ""
base = os.path.expanduser("~/.claude/bell/sessions")
os.makedirs(base, exist_ok=True)
path = os.path.join(base, f"{session_id}.json")

if event == "end":
    try:
        os.remove(path)
    except FileNotFoundError:
        pass
    raise SystemExit(0)

try:
    with open(path) as f:
        previous = json.load(f)
except Exception:
    previous = {}

def git(*args):
    try:
        return subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=2).stdout.strip()
    except Exception:
        return ""

def repo_name():
    if previous.get("repo"):
        return previous["repo"]
    remote = git("remote", "get-url", "origin")
    if remote:
        return os.path.basename(remote.rstrip("/")).removesuffix(".git")
    common = git("rev-parse", "--path-format=absolute", "--git-common-dir")
    if common:
        return os.path.basename(os.path.dirname(common))
    return os.path.basename(cwd) or "Claude Code"

def session_title(transcript):
    """transcript 끝에서부터 가장 최근 세션 제목(이름을 바꿨으면 custom-title, 아니면 ai-title)"""
    try:
        size = os.path.getsize(transcript)
        with open(transcript, "rb") as f:
            for chunk in (2_000_000, size):
                f.seek(max(0, size - chunk))
                for line in reversed(f.read().decode("utf-8", "ignore").splitlines()):
                    if '"custom-title"' not in line and '"ai-title"' not in line:
                        continue
                    try:
                        entry = json.loads(line)
                    except Exception:
                        continue
                    title = entry.get("customTitle") or entry.get("aiTitle")
                    if title:
                        return title
                if chunk >= size:
                    break
    except Exception:
        pass
    return None

def launch_folder(transcript):
    """세션을 시작한 폴더 — transcript 앞쪽 첫 cwd. 세션이 worktree 로 옮겨 가도 VS Code 창은 이 폴더다"""
    try:
        with open(transcript, encoding="utf-8", errors="ignore") as f:
            for _, line in zip(range(300), f):
                if '"cwd"' not in line:
                    continue
                try:
                    folder = json.loads(line).get("cwd")
                except Exception:
                    continue
                if folder:
                    return folder
    except Exception:
        pass
    return None

status = {"prompt": "running", "stop": "done", "notification": "waiting"}.get(event, "done")
workspace = previous.get("workspace") or launch_folder(hook.get("transcript_path") or "") or cwd
title = session_title(hook.get("transcript_path") or "") or previous.get("title")
if not title and hook.get("prompt"):
    title = hook["prompt"].strip().splitlines()[0][:40]

record = {
    "sessionId": session_id,
    "repo": repo_name(),
    "branch": git("rev-parse", "--abbrev-ref", "HEAD") or None,
    "title": title,
    "cwd": cwd,
    "workspace": workspace,
    "status": status,
    "message": (hook.get("message") or None) if event == "notification" else None,
    "updatedAt": time.time(),
}
fd, tmp = tempfile.mkstemp(dir=base, suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(record, f, ensure_ascii=False)
os.replace(tmp, path)
PY

pgrep -x ClaudeBell >/dev/null || open -g -j "$HOME/Applications/ClaudeBell.app" --args --agent
exit 0
