#!/usr/bin/env bash
# Two-channel shared-symlink PoC and FS42 hazard cases. Runs inside the
# sandbox container. Mounts:
#   /mnt/nas         synthetic NAS (mounted read-only)
#   /h               this directory (read-only)
#   /probe           internal/fs42/probe (read-only)
# Writes only inside the container (/ws workspace, /var/lib/fs42-manager).
# stdout: "PASS/FAIL <id> <msg>"; stderr: log. Exit code = failure count.
set -uo pipefail

FS42=/opt/fs42
PY=$FS42/env/bin/python
WS=/ws
GEN=/var/lib/fs42-manager/generations/g1
PROBE="$PY /probe/fs42probe.py"
FAILS=0

pass() { echo "PASS $1 $2"; }
fail() { echo "FAIL $1 $2"; FAILS=$((FAILS+1)); }
check() { # check <id> <desc> <cmd...>
  local id="$1" desc="$2"; shift 2; local out
  if out=$("$@" 2>&1); then pass "$id" "$desc"; else fail "$id" "$desc"; echo "  -> ${out:0:600}" >&2; fi
}
log() { echo "---- $*" >&2; }
fs42() { (cd "$WS" && "$PY" "$FS42/station_42.py" "$@"); }
probe() { (cd "$WS" && FS42_HOME=$FS42 $PROBE "$@"); }
# fs42ok <log> <args...>: success = exit 0 AND no failure report in output
fs42ok() { local logf="$1"; shift; fs42 "$@" > "$logf" 2>&1; local rc=$?; [ $rc -eq 0 ] && ! grep -q "I had failures" "$logf"; }
BUMP_MODE="${BUMP_MODE:-synthetic}"   # empty | synthetic

# ---------------------------------------------------------------- preflight
check P01 "NAS is mounted read-only" bash -c '! touch /mnt/nas/.w 2>/dev/null'
check P02 "NAS sentinel present" test -f /mnt/nas/.cablebox-sentinel
RUNTIME_SUM_BEFORE=$(find $FS42/runtime $FS42/confs -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum)

# ---------------------------------------------------------------- workspace
mkdir -p $WS/confs $WS/runtime
cp $FS42/runtime/{brb.png,standby.png,static.mp4,off_air_pattern.mp4,signoff.mp4} $WS/runtime/
# station_io resolves its JSON schema relative to cwd ("fs42/station_config_schema.json")
ln -s $FS42/fs42 $WS/fs42
cat > $WS/confs/main_config.json <<'EOF'
{"db_path": "runtime/fs42_fluid.db"}
EOF

# link <channel> <pool> <link-name> <nas-relative-target>
link() {
  local dir="$GEN/channels/$1/r1/$2"
  mkdir -p "$dir"
  ln -s "/mnt/nas/$4" "$dir/$3"
}
# alpha: Show A (6), Café (3, uppercase .MKV target), films X/Y/W
for e in 1 2 3 4 5 6; do link alpha tv "Show A - S01E0$e--a0$e.mkv" "tv/Show A/Season 1/Show A - S01E0$e.mkv"; done
for e in 1 2 3; do link alpha tv "Café Show – S01E0$e--c0$e.mkv" "tv/Café Ünïcode Show/Season 1/Café Show – S01E0$e.MKV"; done
link alpha films "Film X (1999)--fx.mkv" "movies/Film X (1999)/Film X (1999) - 480p.mkv"
link alpha films "Film Y (2001)--fy.mkv" "movies/Film Y (2001)/Film Y (2001).mkv"
link alpha films "Film W (1987)--fw.mkv" "movies/Film W (1987)/Film W (1987).mkv"
# beta: overlaps Show A E01-03 and Film X; duplicate basenames from B and C
for e in 1 2 3; do link beta tv "Show A - S01E0$e--a0$e.mkv" "tv/Show A/Season 1/Show A - S01E0$e.mkv"; done
for e in 1 2 3; do link beta tv "episode 0$e--b0$e.mkv" "tv/Show B/Season 01/Disc 1/episode 0$e.mkv"; done
for e in 1 2 3; do link beta tv "episode 0$e--k0$e.mkv" "tv/Show C/S1/episode 0$e.mkv"; done
link beta films "Film X (1999)--fx.mkv" "movies/Film X (1999)/Film X (1999) - 480p.mkv"
link beta films "Film Z--fz.mp4" "movies/Film Z/Film Z.mp4"

station() { # station <name> <number> <content_dir>
  cat > "$WS/confs/$1.json" <<EOF
{"station_conf": {
  "network_name": "$1", "channel_number": $2, "network_type": "standard",
  "schedule_increment": 30, "break_strategy": "end", "commercial_free": true,
  "content_dir": "$3", "bump_dir": "bump",
  "standby_image": "runtime/standby.png", "be_right_back_media": "runtime/brb.png",
  "day_templates": {"daily": {
    "0": {"tags": "tv"}, "1": {"tags": "tv"}, "2": {"tags": "tv"}, "3": {"tags": "tv"},
    "4": {"tags": "tv"}, "5": {"tags": "tv"}, "6": {"tags": "tv"}, "7": {"tags": "tv"},
    "8": {"tags": "tv"}, "9": {"tags": "tv"}, "10": {"tags": "tv"}, "11": {"tags": "tv"},
    "12": {"tags": "tv"}, "13": {"tags": "tv"}, "14": {"tags": "tv"}, "15": {"tags": "tv"},
    "16": {"tags": "tv"}, "17": {"tags": "tv"},
    "18": {"tags": "films"}, "19": {"tags": "films"}, "20": {"tags": "films"},
    "21": {"tags": "films"}, "22": {"tags": "films"}, "23": {"tags": "films"}}},
  "monday": "daily", "tuesday": "daily", "wednesday": "daily", "thursday": "daily",
  "friday": "daily", "saturday": "daily", "sunday": "daily"
}}
EOF
}
# per-channel bump dir: empty, or operator-style filler (synthetic here)
bumps() {
  mkdir -p "$GEN/channels/$1/r1/bump"
  if [ "$BUMP_MODE" = synthetic ]; then
    for f in /mnt/nas/filler/*.mp4; do ln -s "$f" "$GEN/channels/$1/r1/bump/$(basename "$f")"; done
  fi
}
for c in alpha beta gamma delta epsilon zeta; do bumps $c; done
station cm_alpha_5 5 "$GEN/channels/alpha/r1"
station cm_beta_7 7 "$GEN/channels/beta/r1"

log "probe stations"
probe stations > /tmp/stations.json; cat /tmp/stations.json >&2
check S01 "schema file reachable from workspace cwd" jq -e '.schema_found' /tmp/stations.json
check S02 "both stations loaded, none skipped" jq -e '(.loaded|length)==2 and (.skipped|length)==0' /tmp/stations.json
check S03 "both configs pass upstream schema validation" jq -e '[.validation[].valid]|all' /tmp/stations.json

# ---------------------------------------------------------------- catalogs
log "rebuild catalogs (explicit names)"
check C00a "alpha catalog build reports success" fs42ok /tmp/cat_a.log --rebuild_catalog cm_alpha_5 --skip_chapter_scan
check C00b "beta catalog build reports success" fs42ok /tmp/cat_b.log --rebuild_catalog cm_beta_7 --skip_chapter_scan
probe catalog cm_alpha_5 > /tmp/ca.json; probe catalog cm_beta_7 > /tmp/cb.json
jq -c '{count,by_tag}' /tmp/ca.json /tmp/cb.json >&2
check C01 "alpha catalog tv=9 films=3" jq -e '.by_tag.tv==9 and .by_tag.films==3' /tmp/ca.json
check C02 "beta catalog tv=9 films=2 (dup basenames kept distinct)" jq -e '.by_tag.tv==9 and .by_tag.films==2' /tmp/cb.json
check C02b "bump entries cataloged as content_type=bump ($BUMP_MODE)" \
  jq -e --arg m "$BUMP_MODE" '([.entries[]|select(.content_type=="bump")]|length) as $n | if $m=="synthetic" then $n>0 else $n==0 end' /tmp/ca.json
check C03 "catalog path is the generated link, realpath is the NAS original" \
  jq -e '[.entries[] | (.path|startswith("/var/lib/fs42-manager/")) and (.realpath|startswith("/mnt/nas/"))]|all' /tmp/ca.json
check C04 "uppercase .MKV target reached via lowercase link suffix" \
  jq -e '[.entries[]|select(.realpath|endswith(".MKV"))]|length==3' /tmp/ca.json
SHARED=$(jq -r -s '[.[0].entries[]|select(.content_type=="feature")|.realpath] as $a | [.[1].entries[]|select(.content_type=="feature")|.realpath] as $b | [$a[] | select(. as $x | $b | index($x))] | unique | length' /tmp/ca.json /tmp/cb.json)
check C05 "same originals in both stations (Show A x3 + Film X = 4 shared realpaths)" test "$SHARED" = "4"
check C06 "shared originals have distinct per-station catalog rows" \
  bash -c "test \"\$(jq -s '[.[0].entries[]|select(.realpath|contains(\"Film X\"))|.id] + [.[1].entries[]|select(.realpath|contains(\"Film X\"))|.id] | unique | length' /tmp/ca.json /tmp/cb.json)\" = 2"
LINK_BYTES=$(du -s --apparent-size -B1 $GEN | cut -f1)
check C07 "link trees hold no media bytes (<1MiB total, NAS 25MiB)" test "$LINK_BYTES" -lt 1048576
check C08 "no regular files in link trees (symlinks only)" test -z "$(find $GEN -type f)"

# ---------------------------------------------------------------- schedules
NOW=$(date +%Y-%m-%dT%H:%M:%S)
H7=$(date -d '+7 days' +%Y-%m-%dT%H:%M:%S)
log "add_week explicit names at $NOW"
check W00a "alpha add_week reports success" fs42ok /tmp/wk_a.log --add_week cm_alpha_5
check W00b "beta add_week reports success" fs42ok /tmp/wk_b.log --add_week cm_beta_7
probe extents cm_alpha_5 > /tmp/ext_a_week.json; cat /tmp/ext_a_week.json >&2
check W00c "fresh schedule starts at local midnight today" \
  jq -e --arg d "$(date +%Y-%m-%d)T00:00:00" '.start==$d' /tmp/ext_a_week.json
check W00d "add_week ends at next Monday operating-hours start, not now+7d" \
  jq -e --arg m "$(date -d 'next monday' +%Y-%m-%d)" '.end|startswith($m)' /tmp/ext_a_week.json
# ensure_horizon <station>: append whole days until extent covers now+7d
ensure_horizon() {
  local n=0
  while [ $n -lt 10 ]; do
    local end; end=$(probe extents "$1" | jq -r .end)
    [[ "$end" != null && "$end" > "$H7" ]] && return 0
    fs42ok /tmp/day_$1_$n.log --add_day "$1" || return 1
    n=$((n+1))
  done
  return 1
}
check W00e "alpha horizon extended by --add_day to >= now+7d" ensure_horizon cm_alpha_5
check W00f "beta horizon extended by --add_day to >= now+7d" ensure_horizon cm_beta_7
probe coverage cm_alpha_5 --start "$NOW" --end "$H7" > /tmp/cov_a.json
probe coverage cm_beta_7 --start "$NOW" --end "$H7" > /tmp/cov_b.json
jq -c '{block_count,gaps,plan_shortfalls:(.plan_shortfalls|length),missing_paths,ok}' /tmp/cov_a.json /tmp/cov_b.json >&2
check W01 "alpha covers now..+7d, no gaps/missing paths" jq -e '.ok' /tmp/cov_a.json
check W02 "beta covers now..+7d, no gaps/missing paths" jq -e '.ok' /tmp/cov_b.json
probe schedule cm_alpha_5 > /tmp/sched_a.json; probe schedule cm_beta_7 > /tmp/sched_b.json
check W03 "plan paths are generated link paths (not NAS realpaths)" \
  jq -e '[.blocks[].plan[]|select(.content_type=="feature")|.path|startswith("/var/lib/fs42-manager/")] | length>0 and all' /tmp/sched_a.json
# same original airing at overlapping times on both channels?
python3 - /tmp/sched_a.json /tmp/sched_b.json > /tmp/overlap.json <<'PYEOF'
import json, os, sys, datetime as dt
def spans(p):
    out = []
    for b in json.load(open(p))["blocks"]:
        t = dt.datetime.fromisoformat(b["start"])
        for e in b["plan"]:
            d = e["duration"]
            if e["content_type"] == "feature":
                out.append((os.path.realpath(e["path"]), t, t + dt.timedelta(seconds=d)))
            t += dt.timedelta(seconds=d)
    return out
a, b = spans(sys.argv[1]), spans(sys.argv[2])
hits = [(ra, str(sa)) for ra, sa, ea in a for rb, sb, eb in b if ra == rb and sa < eb and sb < ea]
print(json.dumps({"overlap_count": len(hits), "examples": hits[:3]}))
PYEOF
cat /tmp/overlap.json >&2
pass W04 "same-original concurrent airing observed: $(jq .overlap_count /tmp/overlap.json) overlaps (informational: separate roots impose no exclusion)"

# ---------------------------------------------------------------- play points
T1=$(date -d 'tomorrow 10:07:30' +%Y-%m-%dT%H:%M:%S)
T2=$(date -d 'tomorrow 20:45:00' +%Y-%m-%dT%H:%M:%S)
probe playpoint cm_alpha_5 --at "$T1" --at "$T2" > /tmp/pp_a.json; cat /tmp/pp_a.json >&2
check PP1 "play point at 10:07:30 resolves to a tv link with offset" \
  jq -e '.results[0].found and (.results[0].entry.path|contains("/alpha/r1/tv/")) and .results[0].offset_s>=0' /tmp/pp_a.json
check PP2 "play point at 20:45 resolves to a films link" \
  jq -e '.results[1].found and (.results[1].entry.path|contains("/alpha/r1/films/"))' /tmp/pp_a.json
# cross-check upstream math independently: block start + sum(prev durations) + offset == T1
python3 - /tmp/sched_a.json "$T1" <<'PYEOF' && pass PP3 "independent plan walk agrees with upstream play point" || fail PP3 "independent plan walk disagrees"
import json, sys, datetime as dt
at = dt.datetime.fromisoformat(sys.argv[2])
for b in json.load(open(sys.argv[1]))["blocks"]:
    s, e = dt.datetime.fromisoformat(b["start"]), dt.datetime.fromisoformat(b["end"])
    if s <= at < e:
        t = s
        for p in b["plan"]:
            if t + dt.timedelta(seconds=p["duration"]) > at:
                pp = json.load(open("/tmp/pp_a.json"))["results"][0]
                ok = pp["entry"]["path"] == p["path"] and abs(pp["offset_s"] - (at - t).total_seconds()) < 0.01
                sys.exit(0 if ok else 1)
            t += dt.timedelta(seconds=p["duration"])
sys.exit(1)
PYEOF

# ---------------------------------------------------------------- failure semantics
fs42 --add_week cm_does_not_exist > /tmp/bad.log 2>&1; rc=$?
check F01 "unknown station: CLI exit code is 0 (exit code alone is insufficient)" test "$rc" = "0"
check F02 "unknown station: failure only visible in output text" grep -q "I had failures" /tmp/bad.log
check F03 "unknown station: no schedule created for others as side effect" \
  bash -c "test \"\$(cd $WS && FS42_HOME=$FS42 $PROBE schedule cm_alpha_5 | jq '.blocks|length')\" = \"\$(jq '.blocks|length' /tmp/sched_a.json)\""

# reset deletes coverage for one station only
fs42 --delete_schedules cm_beta_7 > /tmp/reset.log 2>&1
probe coverage cm_beta_7 --start "$NOW" --end "$H7" > /tmp/cov_b2.json
probe coverage cm_alpha_5 --start "$NOW" --end "$H7" > /tmp/cov_a2.json
check R01 "delete_schedules removes beta coverage entirely (does not regenerate)" jq -e '.block_count==0 and (.ok|not)' /tmp/cov_b2.json
check R02 "alpha coverage untouched by beta reset" jq -e '.ok' /tmp/cov_a2.json
fs42 --add_week cm_beta_7 > /dev/null 2>&1

# ---------------------------------------------------------------- hazards (separate stations)
link gamma tv "Show A - S01E01--a01.mkv" "tv/Show A/Season 1/Show A - S01E01.mkv"
link gamma tv "Café Upper--cu.MKV" "tv/Café Ünïcode Show/Season 1/Café Show – S01E01.MKV"   # uppercase link suffix
link gamma tv "Broken--bk.mkv" "movies/Broken (2000)/Broken (2000).mkv"                 # corrupt target
station cm_gamma_9 9 "$GEN/channels/gamma/r1"
fs42 --rebuild_catalog cm_gamma_9 --skip_chapter_scan > /tmp/cat_g.log 2>&1; rc=$?
probe catalog cm_gamma_9 > /tmp/cg.json; jq -c '{count,by_tag}' /tmp/cg.json >&2
check H01 "uppercase link suffix (.MKV) is NOT cataloged by direct-child glob" \
  jq -e '[.entries[]|select(.path|endswith(".MKV"))]|length==0' /tmp/cg.json
check H02 "corrupt target silently skipped (catalog count < link count) with exit $rc" jq -e '[.entries[]|select(.content_type=="feature")]|length==1' /tmp/cg.json

link delta tv "Show A - S01E01--a01.mkv" "tv/Show A/Season 1/Show A - S01E01.mkv"
link delta tv "Missing--ms.mkv" "tv/Show A/Season 1/NOPE.mkv"                          # dangling link
station cm_delta_11 11 "$GEN/channels/delta/r1"
fs42 --rebuild_catalog cm_delta_11 --skip_chapter_scan > /tmp/cat_d.log 2>&1; rc=$?
probe catalog cm_delta_11 > /tmp/cd.json; jq -c '{count,by_tag}' /tmp/cd.json >&2
if grep -q "I had failures" /tmp/cat_d.log; then
  pass H03 "dangling link fails the catalog build (rc=$rc, failure only in text) — preflight required"
else
  fail H03 "dangling link did not report failure (count=$(jq .count /tmp/cd.json), rc=$rc)"
fi

mkdir -p $GEN/channels/epsilon/r1
ln -s "/mnt/nas/tv/Show B" "$GEN/channels/epsilon/r1/tv"                                 # directory symlink
station cm_epsilon_13 13 "$GEN/channels/epsilon/r1"
fs42 --rebuild_catalog cm_epsilon_13 --skip_chapter_scan > /tmp/cat_e.log 2>&1
probe catalog cm_epsilon_13 > /tmp/ce.json; jq -c '{count,by_tag}' /tmp/ce.json >&2
check H04 "directory symlink followed recursively (pulls nested NAS content) — banned in MVP" jq -e '.by_tag.tv==3' /tmp/ce.json

mkdir -p $GEN/channels/zeta/r1/tv
station cm_zeta_15 15 "$GEN/channels/zeta/r1"   # films tag dir missing entirely
link zeta tv "Show A - S01E01--a01.mkv" "tv/Show A/Season 1/Show A - S01E01.mkv"
fs42 --rebuild_catalog cm_zeta_15 --skip_chapter_scan > /tmp/cat_z.log 2>&1; rc_c=$?
fs42 --add_day cm_zeta_15 > /tmp/wk_z.log 2>&1; rc_s=$?
probe coverage cm_zeta_15 --start "$NOW" --end "$(date -d '+1 day' +%Y-%m-%dT%H:%M:%S)" > /tmp/cov_z.json
jq -c '{block_count,gaps:(.gaps|length),plan_shortfalls:(.plan_shortfalls|length),ok}' /tmp/cov_z.json >&2
if grep -q "I had failures" /tmp/wk_z.log || ! jq -e '.ok' /tmp/cov_z.json >/dev/null; then
  pass H05 "empty tag dir is not schedulable: failure text or coverage gap (rc catalog=$rc_c schedule=$rc_s)"
else
  fail H05 "empty tag dir produced a clean schedule"
fi

# ---------------------------------------------------------------- isolation
RUNTIME_SUM_AFTER=$(find $FS42/runtime $FS42/confs -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum)
check I01 "pinned install runtime/ and confs/ untouched (workspace isolation)" test "$RUNTIME_SUM_BEFORE" = "$RUNTIME_SUM_AFTER"
check I02 "workspace DB created in workspace runtime" test -f $WS/runtime/fs42_fluid.db
check I03 "no mpv / player process started" bash -c '! for f in /proc/[0-9]*/cmdline; do tr "\\0" " " < "$f" 2>/dev/null; echo; done | grep -qE "(^|/)mpv |field_player\.py"'

# save evidence for the host
mkdir -p /evidence && cp /tmp/*.json /tmp/*.log /evidence/ 2>/dev/null
echo "SUMMARY fails=$FAILS"
exit $FAILS
