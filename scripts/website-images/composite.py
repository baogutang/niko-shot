#!/usr/bin/env python3
"""Compose the app chrome rendered by DesignSnapshotTests into the website images.

HUD panels render offscreen without their behind-window blur, so the blur and the material's dark fill
are recreated here from the real backdrop underneath each panel.
"""
import json, pathlib, sys
from PIL import Image, ImageFilter

snap, scene, out = (pathlib.Path(a) for a in sys.argv[1:4])
S = 2

def glass(base, png, rect, tint=(24, 24, 26, 150)):
    x, y = int(rect["x"] * S), int(rect["y"] * S)
    panel = Image.open(png).convert("RGBA")
    mask = panel.getchannel("A").point(lambda a: 255 if a > 0 else 0)
    # Window shadow: soft, slightly below.
    shadow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", panel.size, (0, 0, 0, 80)), (x, y + 10), mask)
    base.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(22)))
    patch = base.crop((x, y, x + panel.width, y + panel.height)).filter(ImageFilter.GaussianBlur(28))
    patch.alpha_composite(Image.new("RGBA", panel.size, tint))
    patch.alpha_composite(panel)
    base.paste(patch, (x, y), mask)

# Hero: selection over the practice note with the toolbar below it.
hero = Image.open(snap / "overlay.png").convert("RGBA")
glass(hero, snap / "toolbar.png", json.loads((snap / "toolbar.json").read_text())["toolbar"])
hero.crop((64 * S, 160 * S, 864 * S, 510 * S)).convert("RGB").save(out / "app-capture.png", optimize=True)

# Long capture: document window, viewport mask, live preview and HUD.
frames = json.loads((snap / "scroll.json").read_text())
for theme, suffix in (("light", ""), ("dark", "-dark")):
    base = Image.open(scene / f"scene-{theme}.png").convert("RGBA")
    base.alpha_composite(Image.open(snap / "scroll-mask.png").convert("RGBA"))
    glass(base, snap / f"scroll-preview{suffix}.png", frames["preview"])
    glass(base, snap / "scroll-hud.png", frames["hud"])
    base.convert("RGB").save(out / f"app-scroll{suffix}.png", optimize=True)
print("done")
