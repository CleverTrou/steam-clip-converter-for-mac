#!/bin/bash
# Builds a synthetic Steam Game Recording library for README screenshots.
# Layout matches Steam's: <root>/video/bg_<appid>_<yyyyMMdd>_<HHmmss>/
#   session.mpd, init-stream{0,1}.m4s, chunk-stream{0,1}-NNNNN.m4s
# Video is HEVC tagged hev1 (as Steam writes it); audio is AAC.
set -euo pipefail
ROOT="${1:?root}"

# Refuse a real library: the gamerecording.pb written below replaces Steam's.
if [ -d "$ROOT" ] && [ -n "$(ls -A "$ROOT")" ]; then
    echo "$ROOT isn't empty; use a new or empty folder." >&2
    exit 1
fi
mkdir -p "$ROOT/video"

clip() { # appid date time WxH seconds lavfi-source
    local dir="$ROOT/video/bg_$1_$2_$3"
    rm -rf "$dir"; mkdir -p "$dir"
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "$6" \
        -f lavfi -i "sine=frequency=196:sample_rate=48000,aformat=channel_layouts=stereo" \
        -t "$5" -map 0:v -map 1:a \
        -vf "scale=s=$4:flags=lanczos,format=yuv420p" -r 30 \
        -c:v hevc_videotoolbox -b:v 18M -tag:v hev1 \
        -force_key_frames "expr:gte(t,n_forced*3)" \
        -c:a aac -b:a 160k \
        -f dash -seg_duration 3 -use_template 1 -use_timeline 0 \
        "$dir/session.mpd"
    printf '%-40s %s\n' "$(basename "$dir")" "$(du -sh "$dir" | cut -f1)"
}

clip 2900110 20260919 213204 3840x2160 48 "mandelbrot=size=1280x720:rate=30:start_scale=3:end_scale=0.0006:end_pts=1600:outer=normalized_iteration_count"
clip 2900120 20260921 194511 2560x1440 83 "life=size=320x180:rate=30:mold=12:life_color=#39d98a:death_color=#0b1a2e:mold_color=#1f6feb:ratio=0.2,scale=s=2560x1440:flags=neighbor"
clip 2900130 20260922 221740 1920x1080 36 "gradients=size=1920x1080:rate=30:speed=0.02:nb_colors=5:type=radial"
clip 2900140 20260924 180233 1920x1080 27 "cellauto=size=480x270:rate=30:rule=110:random_fill_ratio=0.5:scroll=1,negate,colorchannelmixer=rr=0.2:gg=0.6:bb=1,scale=s=1920x1080:flags=neighbor"
clip 2900150 20260925 203318 3840x2160 64 "mandelbrot=size=1280x720:rate=30:start_x=-0.7436447860:start_y=0.1318252536:start_scale=2.5:end_scale=0.0003:end_pts=2200:inner=period"
clip 2900160 20260926 172905 2560x1440 21 "gradients=size=1280x720:rate=30:speed=0.05:nb_colors=3:type=spiral"

# Timelines, so some cards show event ticks: <root>/timelines/<id>.json per
# session, indexed by <root>/gamerecording.pb (layout in SteamTimeline.swift).
python3 -I - "$ROOT" <<'PY'
import calendar, json, os, sys, time

root = sys.argv[1]
# Recording folder, ms of session before the clip starts, clip length (ms),
# and events as (ms into the clip, title).
sessions = [
    ("bg_2900120_20260921_194511", 41_000, 83_000,
     [(6_000, "Glider gun built"), (29_000, "Population: 1,000"), (52_000, "Still life"), (71_000, "Extinction averted")]),
    ("bg_2900150_20260925_203318", 18_500, 64_000,
     [(12_000, "Entered Seahorse Valley"), (38_000, "Zoom depth: 10,000×"), (57_000, "Spiral found")]),
    ("bg_2900110_20260919_213204", 9_000, 48_000,
     [(20_000, "Minibrot discovered"), (41_000, "Escape radius exceeded")]),
]

def varint(n):
    out = bytearray()
    while True:
        out.append((n & 0x7F) | (0x80 if n > 0x7F else 0))
        n >>= 7
        if not n:
            return bytes(out)

def field(number, value):
    if isinstance(value, int):
        return varint(number << 3) + varint(value)
    data = value.encode() if isinstance(value, str) else value
    return varint(number << 3 | 2) + varint(len(data)) + data

os.makedirs(f"{root}/timelines", exist_ok=True)
index = b""
for folder, offset, length, events in sessions:
    _, appid, day, hms = folder.split("_")
    # Folder names are UTC; the session started `offset` before the clip.
    start = calendar.timegm(time.strptime(day + hms, "%Y%m%d%H%M%S")) - offset // 1000
    timeline_id = "timeline_" + appid + time.strftime("%Y%m%d_%H%M%S", time.gmtime(start))
    end = offset + length + 6_000
    entries = [{"id": str(i + 1), "time": str(offset + t), "type": "event", "title": title,
                "description": "", "priority": 40, "duration": "0"}
               for i, (t, title) in enumerate(events)]
    with open(f"{root}/timelines/{timeline_id}.json", "w") as f:
        json.dump({"daterecorded": str(start), "starttime": "0", "endtime": str(end), "entries": entries}, f, indent="\t")
    recording = field(1, folder) + field(2, offset) + field(3, length)
    index += field(1, field(1, timeline_id) + field(2, int(appid)) + field(3, start) + field(4, end) + field(5, recording))
    print(f"{timeline_id:40} {len(events)} events -> {folder}")

with open(f"{root}/gamerecording.pb", "wb") as f:
    f.write(index)
PY
