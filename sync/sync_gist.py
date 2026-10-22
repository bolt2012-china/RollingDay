#!/usr/bin/env python3
"""Build RollingDay schedule.json from markdown files and sync it to a secret gist."""
from __future__ import annotations

import argparse
import datetime
import datetime as dt
import glob
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - Python 3.8+ has zoneinfo.
    ZoneInfo = None


DEFAULT_SLOT = {
    "1-2": ("08:00", "09:40"),
    "3-4": ("10:00", "11:40"),
    "6-8": ("12:55", "15:40"),
    "9-10": ("16:00", "17:40"),
}
WEEKDAY_CN = "一二三四五六日"
ROOT = Path(__file__).resolve().parent.parent


def todo_id(title: str) -> str:
    return hashlib.sha1(title.strip().encode("utf-8")).hexdigest()[:10]


tid = todo_id


def read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")


def load_config(path: Path | None) -> dict[str, Any]:
    cfg: dict[str, Any] = {}
    if path and path.exists():
        cfg.update(read_json(path))
    env_map = {
        "gist_id": "ROLLINGDAY_GIST_ID",
        "gist_owner": "ROLLINGDAY_GIST_OWNER",
        "gist_token": "ROLLINGDAY_GIST_TOKEN",
        "data_dir": "ROLLINGDAY_DATA_DIR",
        "todo_file": "ROLLINGDAY_TODO_FILE",
        "week_glob": "ROLLINGDAY_WEEK_GLOB",
        "timezone": "ROLLINGDAY_TIMEZONE",
    }
    for key, env in env_map.items():
        if os.environ.get(env):
            cfg[key] = os.environ[env]
    if os.environ.get("GITHUB_GIST_TOKEN") and "gist_token" not in cfg:
        cfg["gist_token"] = os.environ["GITHUB_GIST_TOKEN"]
    if os.environ.get("GITHUB_GIST_ID") and "gist_id" not in cfg:
        cfg["gist_id"] = os.environ["GITHUB_GIST_ID"]
    return cfg


def get_tz(name: str) -> dt.tzinfo:
    if ZoneInfo:
        try:
            return ZoneInfo(name)
        except Exception:
            pass
    fixed = {
        "Asia/Shanghai": 8,
        "China Standard Time": 8,
        "UTC": 0,
    }
    return dt.timezone(dt.timedelta(hours=fixed.get(name, 8)))


def request_json(url: str, token: str, method: str = "GET", body: dict[str, Any] | None = None) -> dict[str, Any]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "RollingDay",
    }
    if token:
        headers["Authorization"] = "Bearer " + token
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        raise RuntimeError(f"GitHub API {method} {url} failed: HTTP {e.code} {detail}") from e


def parse_day_heading(line: str, fallback_year: int) -> tuple[dt.date, str] | None:
    m = re.match(r"##\s*(?:今日起[（(]?)?(\d{1,2})/(\d{1,2})\s*(\S)?", line)
    if not m:
        return None
    day = dt.date(fallback_year, int(m.group(1)), int(m.group(2)))
    label = f"{day.month}/{day.day} 周{WEEKDAY_CN[day.weekday()]}"
    return day, label


def year_from_path(path: Path, default_year: int) -> int:
    m = re.search(r"week_(\d{4})", path.name)
    return int(m.group(1)) if m else default_year


# ---- RollingDay edits (edits.json) ------------------------------------------
# Week items get stable ids derived from date + content (+ occurrence index), so
# an id stays the same across syncs until the item itself is changed.
def _h(s):
    return hashlib.sha1(s.encode("utf-8")).hexdigest()[:10]


_DAY_RE = re.compile(r"##\s*(?:今日起[（(]?)?(\d{1,2})/(\d{1,2})\s*(\S)?")
_TASK_RE = re.compile(r"(\s*-\s*)(\d{1,2}:\d{2})[–-](\d{1,2}:\d{2})\s+(.*)")
_CLASS_RE = re.compile(r"(\s*-\s*课[：:])(.*)")
_TODO_RE = re.compile(r"(\s*-\s*\[)([ xX])(\]\s*)(.*)")


def week_items(lines, year, slots):
    """Yield (date, item) for every schedule item in a week file's lines."""
    cur = None
    seen = {}
    for i, ln in enumerate(lines):
        m = _DAY_RE.match(ln)
        if m:
            cur = datetime.date(year, int(m.group(1)), int(m.group(2)))
            continue
        if ln.startswith("## "):
            cur = None
            continue
        if not cur:
            continue
        d = cur.isoformat()

        def mk(key):
            n = seen.get((d, key), 0)
            seen[(d, key)] = n + 1
            return "b" + _h(d + "|" + key + ("#%d" % n if n else ""))

        s = ln.strip()
        m = _TASK_RE.match(ln)
        if m:
            st, en, title = m.group(2).zfill(5), m.group(3).zfill(5), m.group(4).strip()
            yield cur, {"line": i, "kind": "task", "start": st, "end": en, "title": title,
                        "id": mk("task|%s|%s|%s" % (st, en, title))}
            continue
        m = _CLASS_RE.match(ln)
        if m:
            for j, it in enumerate(re.split(r"[；;]", m.group(2))):
                mm = re.match(r"\s*(\d+-\d+)\s*(.+)", it)
                if mm and mm.group(1) in slots:
                    st, en = slots[mm.group(1)]
                    name = mm.group(2).strip()
                    yield cur, {"line": i, "kind": "class", "seg": j, "slot": mm.group(1),
                                "start": st, "end": en, "title": "上课：" + name,
                                "id": mk("class|%s|%s" % (mm.group(1), name))}
            continue
        if s.startswith("-"):
            t = s[1:].strip()
            yield cur, {"line": i, "kind": "note", "start": "--:--", "end": "", "title": t,
                        "id": mk("note|" + t)}


def _clean(v):
    return re.sub(r"[\r\n|]+", " ", str(v if v is not None else "")).strip()


def _hm(v):
    m = re.match(r"^\s*(\d{1,2}):(\d{2})\s*$", str(v or ""))
    if not m or int(m.group(1)) > 23 or int(m.group(2)) > 59:
        return None
    return "%02d:%s" % (int(m.group(1)), m.group(2))


def _apply_week_edit(lines, it, e):
    """Mutate lines for one edit on a week item. Returns True if applied."""
    f = e.get("fields") or {}
    i = it["line"]
    ln = lines[i]
    if it["kind"] == "class":
        m = _CLASS_RE.match(ln)
        segs = re.split(r"[；;]", m.group(2))
        sep = "；" if "；" in m.group(2) or ";" not in m.group(2) else ";"
        new_line = None
        if e["action"] == "delete":
            del segs[it["seg"]]
        else:
            title = _clean(f.get("title", it["title"]))
            if title.startswith("上课："):
                title = title[3:].strip()
            st = _hm(f.get("start")) or it["start"]
            en = _hm(f.get("end")) or it["end"]
            if (st, en) == (it["start"], it["end"]):
                segs[it["seg"]] = "%s %s" % (it["slot"], title)
            else:  # moved out of its class slot: becomes a timed line
                del segs[it["seg"]]
                indent = re.match(r"\s*", ln).group(0)
                new_line = "%s- %s–%s 上课：%s" % (indent, st, en, title)
        segs = [x.strip() for x in segs if x.strip()]
        rest = [new_line] if new_line else []
        lines[i:i + 1] = ([m.group(1) + sep.join(segs)] if segs else []) + rest
        return True
    if e["action"] == "delete":
        del lines[i]
        return True
    indent = re.match(r"\s*", ln).group(0)
    title = _clean(f.get("title", it["title"])) or it["title"]
    st = _hm(f.get("start"))
    en = _hm(f.get("end"))
    if it["kind"] == "task" or (st and en):
        st = st or it["start"]
        en = en or it["end"]
        lines[i] = "%s- %s–%s %s" % (indent, st, en, title)
    else:
        lines[i] = "%s- %s" % (indent, title)
    return True


def _apply_todo_edit(lines, i, e):
    m = _TODO_RE.match(lines[i])
    if e["action"] == "delete":
        del lines[i]
        return True
    f = e.get("fields") or {}
    old = [x.strip() for x in m.group(4).split("|")] + ["", "", ""]
    title = _clean(f.get("title", old[0])) or old[0]
    due = _clean(f.get("due", old[1]))
    pri = _clean(f.get("priority", old[2]))
    if pri not in ("高", "中", "低"):
        pri = old[2] or "中"
    note = _clean(f.get("note", old[3]))
    lines[i] = "%s%s%s%s | %s | %s | %s" % (m.group(1), m.group(2), m.group(3), title, due, pri, note)
    lines[i] = lines[i].rstrip()
    return True


def apply_edits(edits, todo_path, week_paths, slots, default_year):
    """Apply edits to todo.md / week_*.md. Idempotent: an edit whose target id no
    longer exists (already applied, or item changed) is skipped. Returns the
    list of processed edit keys (applied or stale) so they can be cleared."""
    processed = []
    if not edits:
        return processed
    files = {}

    def load(p):
        if p not in files:
            with open(p, encoding="utf-8") as fh:
                files[p] = fh.read().split("\n")
        return files[p]

    for e in edits:
        key = edit_key(e)
        if not isinstance(e, dict) or e.get("action") not in ("edit", "delete") or not e.get("id"):
            processed.append(key)
            continue
        done = False
        if e.get("type") != "block":
            lines = load(todo_path)
            for i, ln in enumerate(lines):
                m = _TODO_RE.match(ln)
                if m and tid(m.group(4).split("|")[0]) == e["id"]:
                    done = _apply_todo_edit(lines, i, e)
                    break
        if not done and e.get("type") != "todo":
            for p in week_paths:
                ym = re.search(r"week_(\d{4})", os.path.basename(p))
                lines = load(p)
                for _d, it in week_items(lines, int(ym.group(1)) if ym else default_year, slots):
                    if it["id"] == e["id"]:
                        done = _apply_week_edit(lines, it, e)
                        break
                if done:
                    break
        print("edit", e.get("action"), e.get("id"), "applied" if done else "skipped (not found / already applied)")
        processed.append(key)
    for p, lines in files.items():
        with open(p, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))
    return processed


def edit_key(e):
    if isinstance(e, dict) and e.get("eid"):
        return "eid:" + str(e["eid"])
    return "json:" + json.dumps(e, sort_keys=True, ensure_ascii=False)
# ---------------------------------------------------------------------------


def parse_week(path: Path, default_year: int, slots: dict[str, tuple[str, str]]) -> dict[str, dict[str, Any]]:
    year = year_from_path(path, default_year)
    days: dict[str, dict[str, Any]] = {}
    lines = path.read_text(encoding="utf-8").split("\n")
    for line in lines:
        heading = parse_day_heading(line, year)
        if heading:
            day, label = heading
            days[day.isoformat()] = {"date": day.isoformat(), "label": label, "blocks": []}
    for day, it in week_items(lines, year, slots):
        days[day.isoformat()]["blocks"].append({
            "id": it["id"],
            "start": it["start"],
            "end": it["end"],
            "title": it["title"],
            "kind": it["kind"],
        })
    return days


def load_gist_state(gist_id: str | None, token: str) -> dict[str, Any]:
    """Read done.json and edits.json written back by the web page / widget."""
    state: dict[str, Any] = {"done": [], "has_done": False, "edits": [], "has_edits": False}
    if not gist_id:
        return state
    files = request_json(f"https://api.github.com/gists/{gist_id}", token).get("files", {})
    for name, key in (("done.json", "done"), ("edits.json", "edits")):
        file_obj = files.get(name)
        if not file_obj:
            continue
        state["has_" + key] = True
        try:
            state[key] = json.loads(file_obj.get("content") or "{}").get(key, []) or []
        except json.JSONDecodeError:
            pass
    return state


def merge_done_into_todo(todo_path: Path, done: list[dict[str, Any]]) -> list[dict[str, Any]]:
    dids = {d.get("id") for d in done}
    dtitles = {d.get("title") for d in done}
    lines = todo_path.read_text(encoding="utf-8").split("\n")
    present: set[str] = set()
    for i, line in enumerate(lines):
        m = re.match(r"(\s*-\s*\[)([ xX])(\]\s*)([^|]*)(.*)", line)
        if not m:
            continue
        title = m.group(4).strip()
        item_id = todo_id(title)
        present.add(item_id)
        if m.group(2) == " " and (item_id in dids or title in dtitles):
            lines[i] = m.group(1) + "x" + m.group(3) + m.group(4) + m.group(5)
    todo_path.write_text("\n".join(lines), encoding="utf-8")
    return [d for d in done if d.get("id") in present]


def parse_todos(todo_path: Path, done_ids: set[str]) -> list[dict[str, Any]]:
    todos: list[dict[str, Any]] = []
    with todo_path.open("r", encoding="utf-8") as f:
        for line in f:
            m = re.match(r"-\s*\[([ xX])\]\s*(.*)", line.strip())
            if not m:
                continue
            fields = [x.strip() for x in m.group(2).split("|")] + ["", "", ""]
            item_id = todo_id(fields[0])
            if m.group(1) != " " and item_id not in done_ids:
                continue
            todos.append({
                "id": item_id,
                "title": fields[0],
                "due": fields[1],
                "priority": fields[2] or "中",
                "note": fields[3],
                "done": m.group(1) != " ",
            })
    priority_order = {"高": 0, "中": 1, "低": 2}
    todos.sort(key=lambda t: (priority_order.get(t["priority"], 1), t["due"] if re.match(r"\d{4}", t["due"]) else "9999"))
    return todos


def build_schedule(cfg: dict[str, Any], apply: bool = True) -> tuple[dict[str, Any], list[dict[str, Any]], bool, dict[str, Any]]:
    timezone = cfg.get("timezone", "Asia/Shanghai")
    tz = get_tz(timezone)
    now = dt.datetime.now(tz)
    today = now.date()
    data_dir = Path(cfg.get("data_dir") or ROOT)
    todo_path = Path(cfg.get("todo_file") or data_dir / "todo.md")
    week_glob = str(cfg.get("week_glob") or data_dir / "week_*.md")
    slots = {**DEFAULT_SLOT, **{k: tuple(v) for k, v in (cfg.get("slots") or {}).items()}}

    if not todo_path.exists():
        raise FileNotFoundError(f"todo file not found: {todo_path}")

    state = load_gist_state(cfg.get("gist_id"), cfg.get("gist_token", ""))
    done, has_done = state["done"], state["has_done"]
    new_done = merge_done_into_todo(todo_path, done)
    week_files = sorted(glob.glob(week_glob))
    processed: list[str] = []
    if apply:
        processed = apply_edits(state["edits"], str(todo_path), week_files, slots, today.year)

    days: dict[str, dict[str, Any]] = {}
    for filename in week_files:
        days.update(parse_week(Path(filename), today.year, slots))
    day_list = [d for k, d in sorted(days.items()) if k >= today.isoformat()][: int(cfg.get("days", 7))]
    for day in day_list:
        day["blocks"].sort(key=lambda b: (b["kind"] == "note", b["start"]))
    todos = parse_todos(todo_path, {d.get("id") for d in done})

    hm = now.strftime("%H:%M")
    current = None
    next_block = None
    for day in day_list:
        for block in day["blocks"]:
            if block["kind"] == "note":
                continue
            if day["date"] == today.isoformat() and block["start"] <= hm < block["end"]:
                current = block
            elif (day["date"] > today.isoformat() or block["start"] > hm) and not next_block:
                next_block = dict(block, date=day["date"])

    schedule = {
        "updated_at": now.strftime(f"%Y-%m-%d %H:%M ({timezone})"),
        "current": current,
        "next": next_block,
        "days": day_list,
        "todos": todos,
    }
    return schedule, new_done, has_done, {"processed": processed, "has_edits": state["has_edits"]}


def sync(cfg: dict[str, Any], schedule: dict[str, Any], done: list[dict[str, Any]], has_done: bool, config_path: Path | None,
         edit_state: dict[str, Any] | None = None) -> str:
    token = cfg.get("gist_token")
    if not token:
        raise RuntimeError("missing gist token: set ROLLINGDAY_GIST_TOKEN or gist_token in config")
    gist_id = cfg.get("gist_id")
    files = {
        "schedule.json": {"content": json.dumps(schedule, ensure_ascii=False, indent=1)},
    }
    if not has_done:
        files["done.json"] = {"content": json.dumps({"done": done}, ensure_ascii=False, indent=1)}

    edit_state = edit_state or {}
    if gist_id and edit_state.get("processed"):
        # Re-read just before writing so edits queued in the meantime survive.
        latest = load_gist_state(gist_id, token)["edits"]
        applied = set(edit_state["processed"])
        remaining = [e for e in latest if edit_key(e) not in applied]
        files["edits.json"] = {"content": json.dumps({"edits": remaining}, ensure_ascii=False, indent=1)}
    elif not edit_state.get("has_edits"):
        files["edits.json"] = {"content": json.dumps({"edits": []})}

    web_path = Path(cfg.get("web_index") or ROOT / "web" / "index.html")
    if cfg.get("publish_web", False) and web_path.exists():
        files["index.html"] = {"content": web_path.read_text(encoding="utf-8")}

    body: dict[str, Any] = {
        "files": files,
        "description": cfg.get("gist_description", "RollingDay schedule data"),
    }
    if gist_id:
        request_json(f"https://api.github.com/gists/{gist_id}", token, "PATCH", body)
    else:
        body["public"] = bool(cfg.get("public", False))
        created = request_json("https://api.github.com/gists", token, "POST", body)
        gist_id = created["id"]
        cfg["gist_id"] = gist_id
        cfg["gist_owner"] = created.get("owner", {}).get("login", cfg.get("gist_owner", ""))
        if config_path:
            existing = read_json(config_path)
            existing.update({k: cfg[k] for k in ("gist_id", "gist_owner") if cfg.get(k)})
            write_json(config_path, existing)
    return gist_id


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Sync RollingDay markdown schedule files to a GitHub gist.")
    parser.add_argument("--config", type=Path, default=ROOT / "sync" / "config.json", help="JSON config path")
    parser.add_argument("--dry-run", action="store_true", help="build schedule.json without patching GitHub")
    parser.add_argument("--out", type=Path, help="optional local schedule.json output for dry runs")
    args = parser.parse_args(argv)

    cfg = load_config(args.config)
    schedule, done, has_done, edit_state = build_schedule(cfg, apply=not args.dry_run)
    if args.out:
        write_json(args.out, schedule)
    if args.dry_run:
        print(json.dumps(schedule, ensure_ascii=False, indent=2))
        return 0
    gist_id = sync(cfg, schedule, done, has_done, args.config, edit_state)
    current = schedule["current"] and schedule["current"]["title"]
    next_block = schedule["next"] and schedule["next"]["title"]
    print("synced", gist_id, schedule["updated_at"], "cur:", current, "next:", next_block)
    return 0


if __name__ == "__main__":
    sys.exit(main())
