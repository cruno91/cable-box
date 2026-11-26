#!/usr/bin/env bash
# Activation (stopped-state snapshot) and rollback. Runs inside the sandbox
# container; same mounts as run_poc.sh.
#
#   /prod  : stand-in for the Pi's live FS42 workspace, with an UNMANAGED
#            station (legacy_3) and one managed station (cm_alpha_5 @ r1)
#   /cand  : isolated candidate workspace built from a SQLite .backup of /prod
#
# Change set: cm_alpha_5 r1 -> r2 (new link tree), add cm_beta_7, add cm_low_2
# (lower number than the current selection, so the saved index shifts).
set -uo pipefail

FS42=/opt/fs42; PY=$FS42/env/bin/python
GEN=/var/lib/fs42-manager/generations
FAILS=0
pass() { echo "PASS $1 $2"; }
fail() { echo "FAIL $1 $2"; FAILS=$((FAILS+1)); }
check() { local id="$1" desc="$2"; shift 2; local out; if out=$("$@" 2>&1); then pass "$id" "$desc"; else fail "$id" "$desc"; echo "  -> ${out:0:600}" >&2; fi; }
fs42in() { local ws="$1"; shift; (cd "$ws" && "$PY" "$FS42/station_42.py" "$@"); }
fs42ok() { local ws="$1" logf="$2"; shift 2; fs42in "$ws" "$@" > "$logf" 2>&1; local rc=$?; [ $rc -eq 0 ] && ! grep -q "I had failures" "$logf"; }
probe() { local ws="$1"; shift; (cd "$ws" && FS42_HOME=$FS42 "$PY" /probe/fs42probe.py "$@"); }
H7=$(date -d '+7 days' +%Y-%m-%dT%H:%M:%S); NOW=$(date +%Y-%m-%dT%H:%M:%S)

mkws() {
  mkdir -p "$1/confs" "$1/runtime"
  cp $FS42/runtime/{brb.png,standby.png} "$1/runtime/"
  ln -sfn $FS42/fs42 "$1/fs42"
  echo '{"db_path": "runtime/fs42_fluid.db"}' > "$1/confs/main_config.json"
}
link() { local d="$1/$2"; mkdir -p "$d"; ln -s "/mnt/nas/$4" "$d/$3"; }
filler() { mkdir -p "$1/bump"; for f in /mnt/nas/filler/*.mp4; do ln -s "$f" "$1/bump/$(basename "$f")"; done; }
station() { # station <ws> <name> <number> <content_dir>
  local tmp; tmp=$(mktemp "$1/confs/.tmp.XXXX")
  cat > "$tmp" <<EOF
{"station_conf": {"network_name": "$2", "channel_number": $3, "network_type": "standard",
 "schedule_increment": 30, "break_strategy": "end", "commercial_free": true,
 "content_dir": "$4", "bump_dir": "bump",
 "standby_image": "runtime/standby.png", "be_right_back_media": "runtime/brb.png",
 "day_templates": {"d": {$(for h in $(seq 0 23); do t=tv; [ $h -ge 18 ] && t=films; printf '"%d": {"tags": "%s"}' $h $t; [ $h -lt 23 ] && printf ', '; done)}},
 "monday": "d", "tuesday": "d", "wednesday": "d", "thursday": "d", "friday": "d", "saturday": "d", "sunday": "d"}}
EOF
  mv -f "$tmp" "$1/confs/$2.json"   # atomic within confs/
}
ensure_horizon() { # <ws> <station>
  local n=0 end
  while [ $n -lt 12 ]; do
    end=$(probe "$1" extents "$2" | jq -r .end)
    [[ "$end" != null && "$end" > "$H7" ]] && return 0
    fs42ok "$1" /tmp/day.log --add_day "$2" || return 1
    n=$((n+1))
  done
  return 1
}
# hash of every row in every station-scoped table, for the given station
station_digest() { # <db> <station>
  local db="$1" st="$2" out=""
  for t in $(sqlite3 "file:$db?mode=ro" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"); do
    if sqlite3 "file:$db?mode=ro" "PRAGMA table_info($t)" | cut -d'|' -f2 | grep -qx station; then
      out+="$t:$(sqlite3 "file:$db?mode=ro" "SELECT * FROM $t WHERE station='$st' ORDER BY 1" | sha256sum | cut -c1-16) "
    fi
  done
  echo "$out"
}
sqlite_backup() { # <src> <dst> : online-safe copy + integrity check
  sqlite3 "file:$1?mode=ro" ".backup '$2'" && [ "$(sqlite3 "$2" 'PRAGMA integrity_check')" = ok ]
}

# ============================================================ 1. live state
mkws /prod
LEG=/opt/legacy-content            # unmanaged station's own content root
link $LEG tv "legacy ep1.mkv" "tv/Show C/S1/episode 01.mkv"
link $LEG tv "legacy ep2.mkv" "tv/Show C/S1/episode 02.mkv"
link $LEG films "legacy film.mkv" "movies/Film W (1987)/Film W (1987).mkv"
filler $LEG
station /prod legacy_3 3 $LEG
R1=$GEN/g1/channels/alpha/r1
for e in 1 2 3; do link $R1 tv "Show A - S01E0$e--a0$e.mkv" "tv/Show A/Season 1/Show A - S01E0$e.mkv"; done
link $R1 films "Film X (1999)--fx.mkv" "movies/Film X (1999)/Film X (1999) - 480p.mkv"
filler $R1
station /prod cm_alpha_5 5 $R1
for s in legacy_3 cm_alpha_5; do
  fs42ok /prod /tmp/p_cat_$s.log --rebuild_catalog $s --skip_chapter_scan || fail L0 "prod catalog $s"
  ensure_horizon /prod $s || fail L0 "prod horizon $s"
done
echo '{"channel_index": 1}' > /prod/runtime/player_state.json      # viewer is on ch5
LEGACY_BEFORE=$(station_digest /prod/runtime/fs42_fluid.db legacy_3)
for s in legacy_3 cm_alpha_5; do
  check L02-$s "live $s has coverage now..+7d before any change" bash -c "cd /prod && FS42_HOME=$FS42 $PY /probe/fs42probe.py coverage $s --start $NOW --end $H7 | jq -e '.ok and .block_count>0'"
done
ALPHA_BEFORE=$(station_digest /prod/runtime/fs42_fluid.db cm_alpha_5)
check L01 "live lineup loads 2 stations" bash -c "cd /prod && FS42_HOME=$FS42 $PY /probe/fs42probe.py stations | jq -e '(.loaded|length)==2'"

# ============================================================ 2. candidate (stopped-state snapshot)
# In production the player, schedule agent and API are stopped before this copy.
mkws /cand
check A01 "snapshot via sqlite .backup passes integrity_check" sqlite_backup /prod/runtime/fs42_fluid.db /cand/runtime/fs42_fluid.db
cp /prod/confs/legacy_3.json /cand/confs/                     # unmanaged configs carried verbatim
R2=$GEN/g2/channels/alpha/r2
for e in 4 5 6; do link $R2 tv "Show A - S01E0$e--a0$e.mkv" "tv/Show A/Season 1/Show A - S01E0$e.mkv"; done
link $R2 films "Film Y (2001)--fy.mkv" "movies/Film Y (2001)/Film Y (2001).mkv"
filler $R2
station /cand cm_alpha_5 5 $R2
B1=$GEN/g2/channels/beta/r1
for e in 1 2 3; do link $B1 tv "Show A - S01E0$e--a0$e.mkv" "tv/Show A/Season 1/Show A - S01E0$e.mkv"; done
link $B1 films "Film X (1999)--fx.mkv" "movies/Film X (1999)/Film X (1999) - 480p.mkv"
filler $B1
station /cand cm_beta_7 7 $B1
L1=$GEN/g2/channels/low/r1
for e in 1 2; do link $L1 tv "Café Show – S01E0$e--c0$e.mkv" "tv/Café Ünïcode Show/Season 1/Café Show – S01E0$e.MKV"; done
link $L1 films "Film Z--fz.mp4" "movies/Film Z/Film Z.mp4"
filler $L1
station /cand cm_low_2 2 $L1

# changed managed stations only: catalog rebuild (also deletes that station's schedule), then horizon
for s in cm_alpha_5 cm_beta_7 cm_low_2; do
  check A02-$s "candidate catalog $s" fs42ok /cand /tmp/c_cat_$s.log --rebuild_catalog $s --skip_chapter_scan
done
check A03 "rebuild_catalog deleted the snapshot's cm_alpha_5 schedule" \
  bash -c "cd /cand && FS42_HOME=$FS42 $PY /probe/fs42probe.py extents cm_alpha_5 | jq -e '.block_count==0'"
for s in cm_alpha_5 cm_beta_7 cm_low_2; do
  check A04-$s "candidate horizon $s" ensure_horizon /cand $s
  check A05-$s "candidate coverage ok $s" bash -c "cd /cand && FS42_HOME=$FS42 $PY /probe/fs42probe.py coverage $s --start $NOW --end $H7 | jq -e .ok"
done
check A06 "unmanaged legacy_3 rows byte-identical in candidate" test "$(station_digest /cand/runtime/fs42_fluid.db legacy_3)" = "$LEGACY_BEFORE"
check A07 "candidate cm_alpha_5 plans reference only r2 links" \
  bash -c "cd /cand && FS42_HOME=$FS42 $PY /probe/fs42probe.py schedule cm_alpha_5 | jq -e '[.blocks[].plan[]|select(.content_type==\"feature\")|.path|contains(\"/alpha/r2/\")]|length>0 and all'"

# ============================================================ 3. promote
TS=$(date +%Y%m%dT%H%M%S); BK=/prod/backups/$TS
mkdir -p $BK/confs
check P01 "live DB backed up with integrity_check" sqlite_backup /prod/runtime/fs42_fluid.db $BK/fs42_fluid.db
cp -a /prod/confs/. $BK/confs/; cp -a /prod/runtime/player_state.json $BK/
# selected channel: old index -> channel number (old lineup) -> new index (new lineup)
OLD_NUMS=$(cd /prod && FS42_HOME=$FS42 $PY /probe/fs42probe.py stations | jq -c '[.loaded[].channel_number]')
NEW_NUMS=$(cd /cand && FS42_HOME=$FS42 $PY /probe/fs42probe.py stations | jq -c '[.loaded[].channel_number]')
SEL_NUM=$(jq -n --argjson o "$OLD_NUMS" --argjson i "$(jq .channel_index /prod/runtime/player_state.json)" '$o[$i]')
NEW_IDX=$(jq -n --argjson n "$NEW_NUMS" --argjson c "$SEL_NUM" '$n|index($c) // 0')
echo "selected ch=$SEL_NUM old=$OLD_NUMS new=$NEW_NUMS -> index $NEW_IDX" >&2
# DB: same-filesystem copy then atomic rename (no process holds it: stopped)
cp /cand/runtime/fs42_fluid.db /prod/runtime/.fs42_fluid.db.new && mv -f /prod/runtime/.fs42_fluid.db.new /prod/runtime/fs42_fluid.db
rm -f /prod/runtime/fs42_fluid.db-wal /prod/runtime/fs42_fluid.db-shm
for f in cm_alpha_5 cm_beta_7 cm_low_2; do cp /cand/confs/$f.json /prod/confs/.$f.json.new && mv -f /prod/confs/.$f.json.new /prod/confs/$f.json; done
echo "{\"channel_index\": $NEW_IDX}" > /prod/runtime/.ps.new && mv -f /prod/runtime/.ps.new /prod/runtime/player_state.json

check P02 "fresh process sees 4 stations, none skipped" bash -c "cd /prod && FS42_HOME=$FS42 $PY /probe/fs42probe.py stations | jq -e '(.loaded|length)==4 and (.skipped|length)==0'"
for s in legacy_3 cm_alpha_5 cm_beta_7 cm_low_2; do
  check P03-$s "post-promotion coverage+paths ok $s" bash -c "cd /prod && FS42_HOME=$FS42 $PY /probe/fs42probe.py coverage $s --start $NOW --end $H7 | jq -e .ok"
done
check P04 "unmanaged legacy_3 preserved through promotion" test "$(station_digest /prod/runtime/fs42_fluid.db legacy_3)" = "$LEGACY_BEFORE"
check P05 "saved selection still ch5 by number after lower-number insert" \
  bash -c "test \"\$(cd /prod && FS42_HOME=$FS42 $PY /probe/fs42probe.py stations | jq --argjson i \$(jq .channel_index /prod/runtime/player_state.json) '.loaded[\$i].channel_number')\" = 5"
check P06 "r1 tree retained after promotion (old schedules/backups may reference it)" test -L "$R1/tv/Show A - S01E01--a01.mkv"

# ============================================================ 4. rollback
cp $BK/fs42_fluid.db /prod/runtime/.rb.db && mv -f /prod/runtime/.rb.db /prod/runtime/fs42_fluid.db
rm -f /prod/confs/cm_beta_7.json /prod/confs/cm_low_2.json
cp $BK/confs/cm_alpha_5.json /prod/confs/.a.new && mv -f /prod/confs/.a.new /prod/confs/cm_alpha_5.json
cp $BK/player_state.json /prod/runtime/player_state.json
check B01 "rollback: fresh process sees original 2 stations" bash -c "cd /prod && FS42_HOME=$FS42 $PY /probe/fs42probe.py stations | jq -e '(.loaded|length)==2'"
check B02 "rollback: legacy_3 identical" test "$(station_digest /prod/runtime/fs42_fluid.db legacy_3)" = "$LEGACY_BEFORE"
check B03 "rollback: cm_alpha_5 rows identical to pre-deploy" test "$(station_digest /prod/runtime/fs42_fluid.db cm_alpha_5)" = "$ALPHA_BEFORE"
check B04 "rollback: r1 link paths resolve, coverage ok" bash -c "cd /prod && FS42_HOME=$FS42 $PY /probe/fs42probe.py coverage cm_alpha_5 --start $NOW --end $H7 | jq -e .ok"

mkdir -p /evidence && sqlite3 /prod/runtime/fs42_fluid.db .schema > /evidence/fs42_schema.sql 2>/dev/null
echo "SUMMARY fails=$FAILS"
exit $FAILS
