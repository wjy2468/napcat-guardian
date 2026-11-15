#!/usr/bin/env python3
"""Daily digest for the NapCat + AstrBot setup.

Collects the last 24 hours of evidence that normally only exists in log
files, and emails it through the same SMTP settings the guardian uses:

  * AstrBot token usage (provider_stats) - requests, new/cached/output
  * kicks and session lifetime (kick.log)
  * AstrBot watchdog restarts
  * current guardian state (metrics.json)

Usage:
    python daily-report.py --config D:\\napcat\\guardian.config.json --dry-run
    python daily-report.py --config D:\\napcat\\guardian.config.json

Exit codes: 0 success, 1 config/SMTP problem, 2 unexpected error.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import smtplib
import sqlite3
import sys
from email.message import EmailMessage
from pathlib import Path

DEFAULT_DB = r"C:\path\to\astrbot\data\data_v4.db"
DEFAULT_KICK_LOG = r"D:\napcat\kick.log"
DEFAULT_METRICS = r"D:\napcat\metrics.json"
DEFAULT_WATCHDOG_LOG = r"D:\napcat\astrbot_watchdog.log"
DEFAULT_ASTRBOT_LOG = r"C:\path\to\astrbot\data\logs\astrbot.log"


def load_config(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as exc:
        print(f"config is not valid JSON: {exc}", file=sys.stderr)
        return {}


def token_stats(db_path: str, since: float, until: float) -> dict:
    """Aggregate provider_stats between two epoch timestamps."""
    out = {"requests": 0, "new": 0, "cached": 0, "output": 0, "top": [], "error": ""}
    if not os.path.exists(db_path):
        out["error"] = f"db not found: {db_path}"
        return out
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5)
    except sqlite3.Error as exc:
        out["error"] = f"cannot open db: {exc}"
        return out
    try:
        row = conn.execute(
            "select count(*), coalesce(sum(token_input_other),0),"
            " coalesce(sum(token_input_cached),0), coalesce(sum(token_output),0)"
            " from provider_stats where start_time >= ? and start_time < ?",
            (since, until),
        ).fetchone()
        out["requests"], out["new"], out["cached"], out["output"] = (
            row[0],
            int(row[1]),
            int(row[2]),
            int(row[3]),
        )
        out["top"] = [
            (umo or "?", int(tok or 0))
            for umo, tok in conn.execute(
                "select umo, sum(coalesce(token_input_other,0)"
                " + coalesce(token_input_cached,0) + coalesce(token_output,0)) as tok"
                " from provider_stats where start_time >= ? and start_time < ?"
                " group by umo order by tok desc limit 3",
                (since, until),
            )
        ]
    except sqlite3.Error as exc:
        out["error"] = f"query failed: {exc}"
    finally:
        conn.close()
    return out


def read_kicks(path: str, since: dt.date) -> list[str]:
    """Return kick.log lines dated on/after `since`."""
    lines: list[str] = []
    if not os.path.exists(path):
        return lines
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            for fmt in ("%Y-%m-%d %H:%M:%S",):
                try:
                    stamp = dt.datetime.strptime(line[1:20], fmt)
                except ValueError:
                    continue
                if stamp.date() >= since:
                    lines.append(line)
                break
    return lines


def watchdog_restarts(path: str, since: dt.date) -> int:
    """Count hard restarts performed by astrbot_watchdog."""
    if not os.path.exists(path):
        return 0
    count = 0
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if "判定为僵死" not in line and "端口无响应" not in line:
                continue
            try:
                stamp = dt.datetime.strptime(line[1:20], "%Y-%m-%d %H:%M:%S")
            except ValueError:
                continue
            if stamp.date() >= since:
                count += 1
    return count


def astrbot_errors(path: str, since: dt.datetime) -> dict:
    """Count [ERRO lines in AstrBot's own log and keep the top messages.

    只看错误行数量与「同一类错误的次数」，目的是发现"某插件每天报 300 次"这种趋势，
    而不是把整份日志搬进邮件。
    """
    import re

    if not os.path.exists(path):
        return {"count": 0, "top": [], "path": path, "missing": True}

    count = 0
    buckets: dict[str, int] = {}
    stamp_re = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(?:\.\d+)?\]\s*")
    noise_re = re.compile(r"\d+")
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if "[ERRO" not in line:
                continue
            match = stamp_re.match(line)
            if not match:
                continue
            try:
                stamp = dt.datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S")
            except ValueError:
                continue
            if stamp < since:
                continue
            count += 1
            # 去掉时间戳、把数字归一化，让"同一类错误"落到同一个桶里
            text = line[match.end():].strip()
            text = noise_re.sub("N", text)
            if len(text) > 110:
                text = text[:110] + "…"
            buckets[text] = buckets.get(text, 0) + 1

    top = sorted(buckets.items(), key=lambda kv: kv[1], reverse=True)[:3]
    return {"count": count, "top": top, "path": path, "missing": False}


def load_json(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:
            return json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def fmt_int(value: int) -> str:
    return f"{value:,}"


def build_body(cfg: dict, now: dt.datetime) -> str:
    since_day = now.date() - dt.timedelta(days=1)
    start = dt.datetime.combine(since_day, dt.time.min)
    rows = [
        f"NapCat / AstrBot 日报告 — {now:%Y-%m-%d %H:%M}",
        "=" * 46,
        "",
        f"统计区间：{start:%Y-%m-%d %H:%M} 起 24 小时",
        "",
        "【AstrBot token】",
    ]
    stats = token_stats(cfg.get("astrbotDb", DEFAULT_DB), start.timestamp(), now.timestamp())
    if stats["error"]:
        rows.append(f"  读取失败：{stats['error']}")
    else:
        total = stats["new"] + stats["cached"] + stats["output"]
        avg = total // stats["requests"] if stats["requests"] else 0
        rows += [
            f"  请求 {fmt_int(stats['requests'])} 次，合计 {fmt_int(total)} token",
            f"  新增输入 {fmt_int(stats['new'])} · 命中缓存 {fmt_int(stats['cached'])}"
            f" · 输出 {fmt_int(stats['output'])}",
            f"  平均每次 {fmt_int(avg)} token",
        ]
        if stats["top"]:
            rows.append("  消耗最多的会话：")
            for umo, tok in stats["top"]:
                rows.append(f"    {umo} — {fmt_int(tok)}")

    kicks = read_kicks(cfg.get("kickLog", DEFAULT_KICK_LOG), since_day)
    rows += ["", "【被踢记录】"]
    if kicks:
        rows += [f"  {line}" for line in kicks[-10:]]
        rows.append(f"  合计 {len(kicks)} 次")
    else:
        rows.append("  这段时间没有记录到 [KickedOffLine]。")

    restarts = watchdog_restarts(cfg.get("watchdogLog", DEFAULT_WATCHDOG_LOG), since_day)
    rows += ["", "【AstrBot 看护】", f"  僵死强杀重启 {restarts} 次"]

    errs = astrbot_errors(cfg.get("astrbotLog", DEFAULT_ASTRBOT_LOG), start)
    rows += ["", "【AstrBot 错误】"]
    if errs["missing"]:
        rows.append(f"  日志不存在：{errs['path']}")
    elif errs["count"] == 0:
        rows.append("  24 小时内没有 [ERRO] 行。")
    else:
        rows.append(f"  {errs['count']} 条 [ERRO]，按次数排序：")
        for text, hits in errs["top"]:
            rows.append(f"    {hits}× {text}")

    metrics = load_json(cfg.get("metricsFile", DEFAULT_METRICS))
    if metrics:
        rows += [
            "",
            "【当前状态】",
            f"  {metrics.get('state', '?')} · 本次登录 {metrics.get('sessionMin', -1)} 分钟"
            f" · 今日被踢 {metrics.get('kicksToday', 0)} 次",
            f"  下次探针 {metrics.get('nextProbeAt', '?')}（间隔 {metrics.get('probeMin', '?')} 分钟）",
        ]

    rows += ["", "-- 由 daily-report.py 自动生成"]
    return "\n".join(rows)


def send_email(cfg: dict, subject: str, body: str) -> None:
    mail = cfg.get("notifyEmail") or {}
    if not mail.get("enabled", True):
        print("email channel disabled in config", file=sys.stderr)
        return
    host = mail.get("smtp") or "smtp.qq.com"
    port = int(mail.get("port") or 587)
    user = mail.get("user") or ""
    # guardian.config.json calls it "pass"; accept "password" too so the two
    # scripts cannot drift apart again.
    password = mail.get("pass") or mail.get("password") or ""
    to = mail.get("to") or user
    if not (user and password and to):
        raise ValueError("notifyEmail.user/pass/to is incomplete")
    message = EmailMessage()
    message["From"] = user
    message["To"] = to
    message["Subject"] = subject  # keep ASCII for compatible clients
    message.set_content(body, charset="utf-8")
    with smtplib.SMTP(host, port, timeout=20) as smtp:
        smtp.starttls()
        smtp.login(user, password)
        smtp.send_message(message)


def main() -> int:
    parser = argparse.ArgumentParser(description="NapCat + AstrBot daily digest")
    parser.add_argument("--config", default=r"D:\napcat\guardian.config.json")
    parser.add_argument("--dry-run", action="store_true", help="print the body, send nothing")
    parser.add_argument("--out", default="", help="also write the body to this file")
    args = parser.parse_args()

    cfg = load_config(args.config)
    now = dt.datetime.now()
    body = build_body(cfg, now)
    if args.out:
        Path(args.out).write_text(body, encoding="utf-8")
    if args.dry_run:
        print(body)
        return 0
    try:
        send_email(cfg, f"NapCat daily report {now:%Y-%m-%d}", body)
    except Exception as exc:  # noqa: BLE001 - report to caller, guardian logs it
        print(f"send failed: {exc}", file=sys.stderr)
        return 1
    print(f"sent to {cfg.get('notifyEmail', {}).get('to', '?')}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"unexpected error: {exc}", file=sys.stderr)
        sys.exit(2)
