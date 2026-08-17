# Handoff: Steam Clip Converter for Mac — app icon

## Overview
An app icon for **Steam Clip Converter for Mac** (`com.trevornelson.steamclipconverter`),
in two treatments: a macOS Sequoia (macOS 11–15) squircle icon, and the same artwork
prepared for macOS 26 Liquid Glass across its light, dark, clear and tinted appearances.

Chosen direction: **3b — tilted strip, controller lifted.** A horizontal film strip canted
8° with sprocket rows top and bottom, and a game-controller silhouette floating above it in
the picture area, casting a soft shadow onto the strip.

The repository currently ships no icon: `make-app.sh` writes an `Info.plist` with no
`CFBundleIconFile` key and copies nothing into `Contents/Resources`. Both are addressed below.

## About the design files
The files in this bundle are **design references**. `preview.html` is an HTML prototype
showing intended appearance, not production code. The shippable artwork is the **SVG
geometry** — `icon-sequoia-1024.svg` and `layers/*.svg` — which should be rasterised
(`make-icon.sh`) or imported into Apple's Icon Composer rather than reimplemented by hand.

## Fidelity
**High-fidelity.** Colours, geometry and proportions are final. Every coordinate below is
exact. One approximation is flagged deliberately: the container corner is drawn as a
185.4pt rounded rect, not Apple's true superellipse — see "Known approximations".

## The artwork

### Coordinate system
All glyph geometry is authored on a **100 × 100 artboard**. On the 1024 icon canvas that
artboard is placed with `transform="translate(256.5 256.5) scale(5.109)"`, i.e. it occupies
the centre 511 × 511 px (62% of the 824 px content square).

### Layer 1 — film strip (back)
```
<g transform="rotate(-8 50 50)">
  rect  x=2  y=26  w=96  h=50  rx=8
  sprockets (knockouts): w=9 h=6 rx=2
    top row    y=29    x = 6, 19.5, 33, 46.5, 60, 73.5, 87
    bottom row y=67    x = 6, 19.5, 33, 46.5, 60, 73.5, 87
</g>
```
In the flat single-colour renderings the strip is painted at **52% opacity** so it reads as
further back, and a **3.1u knockout gap** is punched around the controller silhouette
(the controller path stroked at `stroke-width=6.89` inside the controller's own transform)
so the two shapes stay separate when both are one colour.

### Layer 2 — controller (front)
Placed with `transform="translate(50 46) scale(0.9) translate(-50 -56)"`.

Silhouette path (artboard units, before that transform):
```
M30 38H70C78 38 84 42 86 50L90 62C92 69 87 74 82 71L72 63H28L18 71C13 74 8 69 10 62L14 50C16 42 22 38 30 38Z
```
Detail knockouts, same transform:
```
d-pad     rect x=29.5 y=45.5 w=5  h=13 rx=1.5
          rect x=25.5 y=49.5 w=13 h=5  rx=1.5
buttons   circle r=2.8 at (68, 46.6) (68, 57.4) (62.6, 52) (73.4, 52)
centre    rect x=46.5 y=49.5 w=7 h=5 rx=2.5
```

### Layer 3 — cast shadow (between the two)
The controller path, filled `#000` at **42% opacity**, Gaussian blur `stdDeviation=3.4`
(group units), offset `translate(0 7.78)` — i.e. 7u down on the artboard.

## Renderings

| Appearance | Container | Glyph paint |
|---|---|---|
| Sequoia | squircle, `linear-gradient(178deg, #5BDDEC 0%, #17A5C6 52%, #0B7591 100%)`, radius 185.4 on 824, top specular `radial-gradient(#fff 45% → transparent)` | `#FFFFFF` |
| Liquid Glass · light | `linear-gradient(155deg, rgba(255,255,255,.94), rgba(226,241,247,.78))`, `backdrop-filter: blur(14px) saturate(1.5)` | `#0E7C99` |
| Liquid Glass · dark | `linear-gradient(155deg, rgba(86,102,114,.62), rgba(24,30,36,.86))`, `backdrop-filter: blur(14px) saturate(1.3)` | `#7FE9F7` |
| Liquid Glass · clear | `linear-gradient(155deg, rgba(255,255,255,.26), rgba(255,255,255,.10))`, `backdrop-filter: blur(10px) saturate(1.7) brightness(1.06)` | `rgba(255,255,255,.96)` |
| Liquid Glass · tinted | `linear-gradient(155deg, #3B444C, #22282E)` | `#F2F6F8` |

Glass edge treatment used in the prototype (all four glass appearances):
`box-shadow: 0 10px 26px rgba(10,40,52,.20), inset 0 1.5px 2px rgba(255,255,255,.95), inset 0 0 0 1px rgba(255,255,255,.7)`.
On a real macOS 26 build these are **not** hand-authored — the system draws the glass,
specular edge and appearance switching from a layered `.icon` file.

## Shipping it

### macOS 15 and earlier (what this repo builds today)
```sh
./make-icon.sh          # needs one of: rsvg-convert (brew install librsvg), magick, inkscape
```
Produces `AppIcon.icns` (16 → 1024, with @2x). Then two edits to `make-app.sh`:

1. after the `cp "$BIN" …` line:
   ```sh
   cp design_handoff_app_icon/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
   ```
2. inside the `Info.plist` heredoc:
   ```xml
   <key>CFBundleIconFile</key><string>AppIcon</string>
   ```
Re-signing already happens at the end of `make-app.sh`; the icon must be in place **before**
`codesign` runs, which the order above satisfies. The Dock caches aggressively — `killall Dock`
after a rebuild if the old generic icon persists.

### macOS 26 (Liquid Glass)
A flat `.icns` still renders on macOS 26, but it gets no glass, no dark/clear/tinted
adaptation, and no parallax. To get those, the icon must be a layered **`.icon`** file
authored in **Icon Composer** (ships with Xcode 26):

1. New document, macOS, 1024.
2. Import `layers/strip.svg` as the back layer, `layers/controller.svg` in front of it.
   Both are 1024-canvas SVGs with the geometry already positioned — no nudging needed.
3. Back layer: opacity ≈ 55%, so it recedes the way the flat version does.
   Front layer: enable the built-in shadow — that replaces the baked shadow in the flat art,
   and lets the system re-cast it per appearance.
4. Leave both layers as monochrome fills and let Icon Composer's tinting drive the glyph
   colour; set the light-appearance background to the Sequoia gradient
   (`#5BDDEC → #17A5C6 → #0B7591`, top to bottom, 2° off vertical).
5. Export/save `Steam Clip Converter.icon` and reference it via `CFBundleIconName`.

Note the layered SVGs deliberately **omit** the knockout gap and the baked shadow — those
exist only to fake depth in a single-colour rendering. Icon Composer provides both for real.

## Known approximations
- **Corner shape.** `rx=185.4` on an 824 square approximates Apple's superellipse. For
  pixel-exact output, clip the artwork with the mask from Apple's macOS icon template
  instead of the rounded rect in `icon-sequoia-1024.svg`.
- **Content inset.** Sequoia's 824-in-1024 content square is applied; the glyph then sits at
  62% of that square. Tune the `scale(5.109)` factor if the mark should read heavier.
- **Small sizes.** At 16 px the four face buttons and centre pill fill in. If 16 px legibility
  matters more than fidelity, ship a simplified 16/32 variant: drop the face buttons and the
  centre pill, keep the d-pad, and thicken the knockout gap to ~4u.

## Design tokens
```
Aqua light      #5BDDEC
Aqua mid        #17A5C6
Aqua deep       #0B7591
Glyph on glass  #0E7C99   (light)   #7FE9F7 (dark)   #F2F6F8 (tinted)
Graphite light  #3B444C
Graphite deep   #22282E
Canvas          1024 · content square 824 · corner radius 185.4
Glyph artboard  100 × 100 placed at 256.5, scale 5.109
Strip opacity   0.52   ·   Shadow #000 at 0.42, blur 3.4, dy 7
```

## Assets
No third-party assets, fonts or images. All geometry is original vector work authored for
this icon; nothing is derived from Valve or Steam artwork, and no Steam colour or shape is
referenced.

## Files
```
icon-sequoia-1024.svg   ship-ready Sequoia icon, container + glyph
glyph-mono.svg          glyph only, transparent background, single colour (#fff)
layers/strip.svg        film strip alone, 1024 canvas — Icon Composer back layer
layers/controller.svg   controller alone, 1024 canvas — Icon Composer front layer
make-icon.sh            SVG → AppIcon.icns
preview.html            all five appearances side by side (design reference only)
```
Source of truth in the design project: `App Icon.dc.html`, option **3b** (turn 3, top row).
