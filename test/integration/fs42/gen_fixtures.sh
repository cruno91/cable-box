#!/usr/bin/env bash
# Generate the synthetic NAS library inside the sandbox container, under $1
# (default /mnt/nas). Cases covered:
#   - spaces + Unicode in directory and file names
#   - uppercase original extension (.MKV) — links must use lowercase suffix
#   - duplicate basenames across shows ("episode 01.mkv")
#   - nested season folders
#   - two versions of one movie (mkv 480p + mp4 240p)
#   - a zero-length/corrupt file that FS42 must skip
#   - filler clips and a mount sentinel file
# Videos are tiny (64x48, 1 fps) but have real durations.
set -euo pipefail
ROOT="${1:-/mnt/nas}"

mk() { # mk <path> <seconds> <label> [container]
  local out="$1" secs="$2" label="$3" fmt="${4:-}"
  mkdir -p "$(dirname "$out")"
  [ -s "$out" ] && return 0
  local fmtargs=()
  [ -n "$fmt" ] && fmtargs=(-f "$fmt")
  ffmpeg -nostdin -loglevel error -y \
    -f lavfi -i "testsrc=size=64x48:rate=1:duration=${secs}" \
    -f lavfi -i "anullsrc=channel_layout=mono:sample_rate=8000" \
    -t "$secs" -shortest \
    -c:v libx264 -preset ultrafast -crf 51 -g 600 \
    -c:a aac -b:a 8k \
    -metadata title="$label" "${fmtargs[@]}" "$out"
}

EP=1320    # 22 min
MOVIE=5400 # 90 min

# Show A: clean layout, 6 episodes
for e in 1 2 3 4 5 6; do
  mk "$ROOT/tv/Show A/Season 1/Show A - S01E0${e}.mkv" $EP "Show A S01E0${e}"
done
# Show B: duplicate basenames vs Show C, nested extra folder level
for e in 1 2 3; do
  mk "$ROOT/tv/Show B/Season 01/Disc 1/episode 0${e}.mkv" $EP "Show B E${e}"
  mk "$ROOT/tv/Show C/S1/episode 0${e}.mkv" $EP "Show C E${e}"
done
# Unicode + spaces + uppercase extension + en dash
for e in 1 2 3; do
  mk "$ROOT/tv/Café Ünïcode Show/Season 1/Café Show – S01E0${e}.MKV" $EP "Cafe E${e}" matroska
done
# Movies, including two versions of one title
mk "$ROOT/movies/Film X (1999)/Film X (1999) - 480p.mkv" $MOVIE "Film X 480p"
mk "$ROOT/movies/Film X (1999)/Film X (1999) - 240p.mp4" $MOVIE "Film X 240p"
mk "$ROOT/movies/Film Y (2001)/Film Y (2001).mkv" 6000 "Film Y"
mk "$ROOT/movies/Film Z/Film Z.mp4" 5700 "Film Z"
mk "$ROOT/movies/Film W (1987)/Film W (1987).mkv" 5100 "Film W"
# corrupt file: valid name, garbage bytes
mkdir -p "$ROOT/movies/Broken (2000)"
[ -s "$ROOT/movies/Broken (2000)/Broken (2000).mkv" ] || head -c 4096 /dev/urandom > "$ROOT/movies/Broken (2000)/Broken (2000).mkv"
# Synthetic filler/bumpers (stand-in for operator-owned filler; test only)
for n in 1 2 3 4 5 6; do
  mk "$ROOT/filler/bump-${n}.mp4" $((15 * n)) "bump ${n}"
done
mk "$ROOT/filler/bump-60.mp4" 60 "bump 60"
mk "$ROOT/filler/bump-120.mp4" 120 "bump 120"
# sentinel used by mount detection tests
echo "cablebox-fixture-nas" > "$ROOT/.cablebox-sentinel"

find "$ROOT" -type f | sort
du -sh "$ROOT"
