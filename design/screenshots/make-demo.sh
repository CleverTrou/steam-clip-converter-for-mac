#!/bin/bash
# Builds a synthetic Steam Game Recording library for README screenshots.
# Layout matches Steam's: <root>/video/bg_<appid>_<yyyyMMdd>_<HHmmss>/
#   session.mpd, init-stream{0,1}.m4s, chunk-stream{0,1}-NNNNN.m4s
# Video is HEVC tagged hev1 (as Steam writes it); audio is AAC.
set -euo pipefail
ROOT="${1:?root}"
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
