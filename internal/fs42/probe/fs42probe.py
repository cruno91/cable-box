"""cablebox read-only FS42 probe.

Runs inside a pinned FieldStation42 checkout's virtualenv with cwd set to an
FS42 workspace (the directory holding confs/ and runtime/). Emits one JSON
document on stdout. It never writes: the SQLite database is opened with
mode=ro and only upstream *read* helpers are used. Exit code 0 means the probe
ran; callers must inspect the JSON for problems.

Usage (all commands take explicit station names — there is no "all" default):
  fs42probe.py stations
  fs42probe.py catalog NAME
  fs42probe.py schedule NAME [--start ISO] [--end ISO]
  fs42probe.py playpoint NAME --at ISO [--at ISO ...]
  fs42probe.py coverage NAME --start ISO --end ISO
  fs42probe.py extents NAME

Times are naive local wall-clock ISO-8601, matching FS42's native contract.
"""

import argparse
import contextlib
import datetime
import io
import json
import logging
import os
import sqlite3
import sys

PROBE_VERSION = 1


def _quiet_imports():
    # upstream logs on import / StationManager init; keep stdout pure JSON
    logging.disable(logging.CRITICAL)
    sink = io.StringIO()
    with contextlib.redirect_stdout(sink):
        from fs42.station_manager import StationManager
        from fs42.station_io import StationIO
        from fs42.liquid_io import LiquidIO

        sm = StationManager()
    return sm, StationIO, LiquidIO


def _ro_connect(db_path):
    if not os.path.exists(db_path):
        return None
    uri = "file:" + os.path.abspath(db_path) + "?mode=ro"
    return sqlite3.connect(uri, uri=True)


def _parse_time(s):
    return datetime.datetime.fromisoformat(s)


def _opt_time(s):
    return _parse_time(s) if s else None


def _iso(t):
    if t is None:
        return None
    if isinstance(t, str):
        return t
    return t.isoformat(timespec="seconds")


def _plan_entry(e):
    return {
        "path": getattr(e, "path", None),
        "skip": float(getattr(e, "skip", 0) or 0),
        "duration": float(getattr(e, "duration", 0) or 0),
        "content_type": getattr(e, "content_type", None),
        "is_stream": bool(getattr(e, "is_stream", False)),
    }


def cmd_stations(sm, StationIO, _LiquidIO, _args):
    sio = StationIO()
    raw = sio.list_raw_station_configs()
    validations = []
    for item in raw:
        conf = item.get("config", item) if isinstance(item, dict) else item
        if not isinstance(conf, dict) or "station_conf" not in conf:
            continue
        with contextlib.redirect_stdout(io.StringIO()):
            ok, errors = sio.validate_station_config(conf)
        validations.append(
            {
                "network_name": conf["station_conf"].get("network_name"),
                "valid": ok,
                "errors": errors,
            }
        )
    return {
        "db_path": sm.server_conf["db_path"],
        "schema_found": os.path.exists(sio.schema_path),
        "loaded": [
            {
                "network_name": s["network_name"],
                "channel_number": s["channel_number"],
                "network_type": s["network_type"],
                "content_dir": s.get("content_dir"),
            }
            for s in sm.stations
        ],
        "skipped": sm.skipped_stations,
        "validation": validations,
    }


def _require_station(sm, name):
    conf = sm.station_by_name(name)
    if conf is None:
        raise SystemExit(json.dumps({"error": "unknown_station", "network_name": name}))
    return conf


def cmd_catalog(sm, _StationIO, _LiquidIO, args):
    _require_station(sm, args.name)
    con = _ro_connect(sm.server_conf["db_path"])
    entries = []
    if con is not None:
        with contextlib.closing(con):
            cur = con.execute(
                "SELECT id, tag, path, realpath, duration, content_type, title "
                "FROM catalog_entries WHERE station = ? ORDER BY tag, path",
                (args.name,),
            )
            for row in cur.fetchall():
                entries.append(
                    {
                        "id": row[0],
                        "tag": row[1],
                        "path": row[2],
                        "realpath": row[3],
                        "duration": row[4],
                        "content_type": row[5],
                        "title": row[6],
                    }
                )
    by_tag = {}
    for e in entries:
        by_tag[e["tag"]] = by_tag.get(e["tag"], 0) + 1
    return {"network_name": args.name, "count": len(entries), "by_tag": by_tag, "entries": entries}


def _select_blocks(con, name, start=None, end=None, at=None):
    # positional SELECT * rows: exactly what upstream's decoder expects
    sql = "SELECT * FROM liquid_blocks WHERE station = ?"
    params = [name]
    if at is not None:
        sql += " AND start_time <= ? AND end_time > ?"
        params += [at, at]
    if start is not None:
        sql += " AND end_time > ?"
        params.append(start)
    if end is not None:
        sql += " AND start_time < ?"
        params.append(end)
    sql += " ORDER BY start_time"
    # upstream stores/compares timestamps as isoformat(sep=" ") text
    params = [p.isoformat(sep=" ") if isinstance(p, datetime.datetime) else p for p in params]
    return con.execute(sql, params).fetchall()


def _decode(LiquidIO, row):
    # content_cache={} -> no CatalogAPI side lookups (keeps the probe read-only)
    with contextlib.redirect_stdout(io.StringIO()):
        return LiquidIO._build_block_from_row(row, content_cache={})


def _blocks(sm, LiquidIO, name, start=None, end=None):
    con = _ro_connect(sm.server_conf["db_path"])
    if con is None:
        return []
    out = []
    with contextlib.closing(con):
        for row in _select_blocks(con, name, start, end):
            try:
                block = _decode(LiquidIO, row)
            except Exception as ex:  # surface, don't hide
                out.append({"decode_error": str(ex), "start": row[3], "end": row[4]})
                continue
            out.append(
                {
                    "liquid_type": row[2],
                    "start": _iso(block.start_time),
                    "end": _iso(block.end_time),
                    "title": block.title,
                    "sequence_key": block.sequence_key,
                    "plan": [_plan_entry(p) for p in (block.plan or [])],
                }
            )
    return out


def cmd_schedule(sm, _StationIO, LiquidIO, args):
    _require_station(sm, args.name)
    return {"network_name": args.name, "blocks": _blocks(sm, LiquidIO, args.name, _opt_time(args.start), _opt_time(args.end))}


def cmd_coverage(sm, _StationIO, LiquidIO, args):
    _require_station(sm, args.name)
    start, end = _parse_time(args.start), _parse_time(args.end)
    blocks = _blocks(sm, LiquidIO, args.name, start, end)
    gaps, missing_paths, cursor = [], set(), start
    plan_shortfalls = []
    for b in blocks:
        if "decode_error" in b:
            continue
        bs, be = _parse_time(b["start"]), _parse_time(b["end"])
        if bs > cursor:
            gaps.append({"from": _iso(cursor), "to": _iso(bs)})
        cursor = max(cursor, be)
        planned = sum(p["duration"] for p in b["plan"])
        span = (be - bs).total_seconds()
        if planned + 1 < span:
            plan_shortfalls.append({"start": b["start"], "span_s": span, "planned_s": planned})
        for p in b["plan"]:
            if p["path"] and not p["is_stream"] and not os.path.exists(p["path"]):
                missing_paths.add(p["path"])
    if cursor < end:
        gaps.append({"from": _iso(cursor), "to": _iso(end)})
    return {
        "network_name": args.name,
        "window": {"start": args.start, "end": args.end},
        "block_count": len(blocks),
        "decode_errors": [b for b in blocks if "decode_error" in b],
        "gaps": gaps,
        "plan_shortfalls": plan_shortfalls,
        "missing_paths": sorted(missing_paths),
        "ok": not gaps and not missing_paths and not any("decode_error" in b for b in blocks),
    }


def cmd_extents(sm, _StationIO, _LiquidIO, args):
    _require_station(sm, args.name)
    con = _ro_connect(sm.server_conf["db_path"])
    start = end = None
    count = 0
    if con is not None:
        with contextlib.closing(con):
            start, end, count = con.execute(
                "SELECT MIN(start_time), MAX(end_time), COUNT(*) FROM liquid_blocks WHERE station = ?",
                (args.name,),
            ).fetchone()
    return {
        "network_name": args.name,
        "start": _iso(datetime.datetime.fromisoformat(start)) if start else None,
        "end": _iso(datetime.datetime.fromisoformat(end)) if end else None,
        "block_count": count,
    }


def cmd_playpoint(sm, _StationIO, _LiquidIO, args):
    _require_station(sm, args.name)
    # PlayPointQuery's LiquidIO may CREATE TABLE IF NOT EXISTS on init; to stay
    # read-only we fetch the block ourselves and reuse upstream's math.
    with contextlib.redirect_stdout(io.StringIO()):
        from fs42.liquid_manager import play_point_in_block

    from fs42.liquid_io import LiquidIO as _LIO

    results = []
    for at in args.at:
        when = _parse_time(at)
        con = _ro_connect(sm.server_conf["db_path"])
        rows = []
        if con is not None:
            with contextlib.closing(con):
                rows = _select_blocks(con, args.name, at=when)
        if not rows:
            results.append({"at": at, "found": False})
            continue
        block = _decode(_LIO, rows[0])
        pp = play_point_in_block(block, when, sm.station_by_name(args.name))
        if pp is None:
            results.append({"at": at, "found": True, "play_point": None, "block_title": block.title})
            continue
        results.append(
            {
                "at": at,
                "found": True,
                "block_title": pp.block_title,
                "block_start": _iso(block.start_time),
                "index": pp.index,
                "offset_s": pp.offset,
                "entry": _plan_entry(pp.plan[pp.index]),
            }
        )
    return {"network_name": args.name, "results": results}


def main(argv=None):
    p = argparse.ArgumentParser(prog="fs42probe")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("stations")
    c = sub.add_parser("catalog")
    c.add_argument("name")
    s = sub.add_parser("schedule")
    s.add_argument("name")
    s.add_argument("--start")
    s.add_argument("--end")
    v = sub.add_parser("coverage")
    v.add_argument("name")
    v.add_argument("--start", required=True)
    v.add_argument("--end", required=True)
    x = sub.add_parser("extents")
    x.add_argument("name")
    pp = sub.add_parser("playpoint")
    pp.add_argument("name")
    pp.add_argument("--at", action="append", required=True)
    args = p.parse_args(argv)

    sys.path.insert(0, os.environ.get("FS42_HOME", "/opt/fs42"))
    sm, StationIO, LiquidIO = _quiet_imports()
    handler = {
        "stations": cmd_stations,
        "catalog": cmd_catalog,
        "schedule": cmd_schedule,
        "coverage": cmd_coverage,
        "extents": cmd_extents,
        "playpoint": cmd_playpoint,
    }[args.cmd]
    result = handler(sm, StationIO, LiquidIO, args)
    result["probe_version"] = PROBE_VERSION
    json.dump(result, sys.stdout, default=str)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
