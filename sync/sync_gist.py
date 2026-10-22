#!/usr/bin/env python3
"""Build RollingDay schedule.json from markdown files and sync it to a secret gist."""
from __future__ import annotations

import argparse
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


def parse_week(path: Path, default_year: int, slots: dict[str, tuple[str, str]]) -> dict[str, dict[str, Any]]:
    year = year_from_path(path, default_year)
    days: dict[str, dict[str, Any]] = {}
    cur: str | None = None
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            heading = parse_day_heading(line, year)
            if heading:
                day, label = heading
                cur = day.isoformat()
                days[cur] = {"date": cur, "label": label, "blocks": []}
                continue
            if line.startswith("## "):
                cur = None
                continue
            if not cur:
                continue
            stripped = line.strip()
            m = re.match(r"-\s*(\d{1,2}:\d{2})[–-](\d{1,2}:\d{2})\s+(.*)", stripped)
            if m:
                days[cur]["blocks"].append({
                    "start": m.group(1).zfill(5),
                    "end": m.group(2).zfill(5),
                    "title": m.group(3).strip(),
                    "kind": "task",
                })
                continue
            m = re.match(r"-\s*课[：:](.*)", stripped)
            if m:
                for item in re.split(r"[；;]", m.group(1)):
                    mm = re.match(r"\s*(\d+-\d+)\s*(.+)", item)
                    if mm and mm.group(1) in slots:
                        start, end = slots[mm.group(1)]
                        days[cur]["blocks"].append({
                            "start": start,
                            "end": end,
                            "title": "上课：" + mm.group(2).strip(),
                            "kind": "class",
                        })
                continue
            if stripped.startswith("-"):
                days[cur]["blocks"].append({
                    "start": "--:--",
                    "end": "",
                    "title": stripped[1:].strip(),
                    "kind": "note",
                })
    return days


def load_done(gist_id: str | None, token: str) -> tuple[list[dict[str, Any]], bool]:
    if not gist_id:
        return [], False
    gist = request_json(f"https://api.github.com/gists/{gist_id}", token)
    file_obj = gist.get("files", {}).get("done.json")
    if not file_obj:
        return [], False
    try:
        return json.loads(file_obj.get("content") or "{}").get("done", []), True
    except json.JSONDecodeError:
        return [], True


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


def build_schedule(cfg: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]], bool]:
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

    days: dict[str, dict[str, Any]] = {}
    for filename in sorted(glob.glob(week_glob)):
        days.update(parse_week(Path(filename), today.year, slots))
    day_list = [d for k, d in sorted(days.items()) if k >= today.isoformat()][: int(cfg.get("days", 7))]
    for day in day_list:
        day["blocks"].sort(key=lambda b: (b["kind"] == "note", b["start"]))

    done, has_done = load_done(cfg.get("gist_id"), cfg.get("gist_token", ""))
    new_done = merge_done_into_todo(todo_path, done)
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
    return schedule, new_done, has_done


def sync(cfg: dict[str, Any], schedule: dict[str, Any], done: list[dict[str, Any]], has_done: bool, config_path: Path | None) -> str:
    token = cfg.get("gist_token")
    if not token:
        raise RuntimeError("missing gist token: set ROLLINGDAY_GIST_TOKEN or gist_token in config")
    gist_id = cfg.get("gist_id")
    files = {
        "schedule.json": {"content": json.dumps(schedule, ensure_ascii=False, indent=1)},
    }
    if not has_done:
        files["done.json"] = {"content": json.dumps({"done": done}, ensure_ascii=False, indent=1)}

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
    schedule, done, has_done = build_schedule(cfg)
    if args.out:
        write_json(args.out, schedule)
    if args.dry_run:
        print(json.dumps(schedule, ensure_ascii=False, indent=2))
        return 0
    gist_id = sync(cfg, schedule, done, has_done, args.config)
    current = schedule["current"] and schedule["current"]["title"]
    next_block = schedule["next"] and schedule["next"]["title"]
    print("synced", gist_id, schedule["updated_at"], "cur:", current, "next:", next_block)
    return 0


if __name__ == "__main__":
    sys.exit(main())
