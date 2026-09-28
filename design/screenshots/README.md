# Screenshots

Run everything below from this directory.

`docs/screenshot.png` (README) and `docs/social-preview.jpg` (GitHub social
preview) are made from a **synthetic** library, never real recordings. Real
clips can show a desktop overlay, a mixed-reality camera feed, or a path with a
username in it. These tools regenerate both images the same way.

## 1. Demo library

```sh
./make-demo.sh /Users/Shared/Steam/gamerecordings
```

Six clips laid out exactly like Steam's (`video/bg_<appid>_<date>_<time>/` with
`session.mpd`, `init-stream*.m4s`, `chunk-stream*.m4s`), with HEVC tagged `hev1`
and AAC audio. The visuals are ffmpeg test sources: fractals, Game of Life,
Rule 110 and gradients. Needs ffmpeg with `hevc_videotoolbox`.

## 2. App state

The app reads game names and the converted list from
`~/Library/Application Support/Steam Clip Converter/`. Back that folder up,
then write demo versions:

- `GameNames.json`: `2900110`–`2900160` → Mandelbrot Descent, Conway's Garden,
  Spectral Drift, Rule 110 Rally, Seahorse Valley, Spiral Sunset. Cached names
  mean the app never looks these IDs up on Steam.
- `Conversions.json`: mark a couple of clips converted, pointing at empty
  placeholder files that exist.

Pass the library as a launch argument. UserDefaults reads the argument domain
without saving it, so your real folder choice is untouched:

```sh
open -n "../../build/Steam Clip Converter for Mac.app" \
  --args -SteamClipConverter.libraryRoot /Users/Shared/Steam/gamerecordings
```

Also `defaults export com.trevornelson.steamclipconverter backup.plist` first:
moving the window changes the saved window frame.

## 3. Capture

```sh
swiftc -O -o stage stage.swift
x=1960 y=70   # top-left of the window, in global points, on a 2× display
./stage "$x" "$y" 1440 900 "Conway's Garden, " "Seahorse Valley, " \
  && screencapture -x -R"$x,$y,1440,900" raw.png
```

`stage` activates the app, sizes the window, and presses the cards whose
accessibility label starts with each argument. Include the comma: the sidebar
filters use the bare game name. Place the window on a 2× display. Use `-R`
rather than `-l <windowid>`: after the app is activated, `-l` returned 1×
images here even on a Retina display.

## 4. Finish

```sh
magick raw.png \( -size 2880x1800 xc:none -fill white \
    -draw "roundrectangle 0,0,2879,1799,20,20" \) -alpha set -compose DstIn -composite rounded.png
magick rounded.png \( +clone -background black -shadow 38x36+0+22 \) +swap \
    -background none -layers merge +repage -resize 1760x -strip ../../docs/screenshot.png
```

For the social preview, put `rounded.png` and `../app-icon/icon-sequoia-1024.svg`
(as `icon.svg`) next to `social.html`, then render it at 1280×640:

```sh
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
  --force-device-scale-factor=1 --window-size=1280,640 --hide-scrollbars \
  --allow-file-access-from-files --screenshot=social.png "file://$PWD/social.html"
magick social.png -strip -quality 90 ../../docs/social-preview.jpg
```

GitHub has no API for the social preview. Upload it under the repository's
**Settings → General → Social preview**.

Afterwards, restore the Application Support folder and
`defaults import com.trevornelson.steamclipconverter backup.plist`, and delete
the demo library.
