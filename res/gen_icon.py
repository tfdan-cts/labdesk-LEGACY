#!/usr/bin/env python3
"""Rebuild platform icons from the approved master. Requires Pillow.

Run python res/gen_icon.py --check to verify assets without writing.
"""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import sys

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parent.parent
MASTER = ROOT / "res/icon-master.png"
MASTER_SHA256 = "2d6c1d10ea3e94c3810ef84bc3e3cf5b34d0e47f5b1495fceff8a21ea8eeed56"
BACKGROUND = (17, 23, 27)
ICO_SIZES = (16, 24, 32, 48, 64, 128, 256)
TRAY_SIZES = (16, 24, 32, 48, 64)


def encoded(image, format="PNG", **options):
    result = io.BytesIO()
    image.save(result, format=format, **options)
    return result.getvalue()


def generate():
    source = MASTER.read_bytes()
    if hashlib.sha256(source).hexdigest() != MASTER_SHA256:
        raise ValueError("The icon master does not match the approved SHA-256.")
    master = Image.open(io.BytesIO(source)).convert("RGBA")
    if master.size != (1254, 1254):
        raise ValueError("The approved master must remain 1254 by 1254 pixels.")
    outputs = {}

    def icon(size):
        return master.resize((size, size), Image.Resampling.LANCZOS)

    def png(path, image):
        outputs[path] = encoded(image)

    def template(image, color=(255, 255, 255)):
        # Template APIs ignore RGB. Luminance retains the chrome/glyph detail
        # instead of turning the master's opaque dark face into a solid badge.
        mask = ImageChops.multiply(image.convert("L"), image.getchannel("A"))
        result = Image.new("RGBA", image.size, (*color, 0))
        result.putalpha(mask)
        return result

    for path, size in {
        "res/icon.png": 1024,
        "res/mac-icon.png": 1024,
        "res/32x32.png": 32,
        "res/64x64.png": 64,
        "res/128x128.png": 128,
        "res/128x128@2x.png": 256,
    }.items():
        png(path, icon(size))
    png("res/mac-tray-dark-x2.png", template(icon(60)))
    png("res/mac-tray-light-x2.png", template(icon(48), (0, 0, 0)))

    def ico(sizes):
        return encoded(icon(max(sizes)), "ICO", sizes=[(s, s) for s in sizes],
                       append_images=[icon(s) for s in sizes[:-1]])

    outputs["res/icon.ico"] = ico(ICO_SIZES)
    outputs["flutter/windows/runner/resources/app_icon.ico"] = outputs["res/icon.ico"]
    outputs["res/tray-icon.ico"] = ico(TRAY_SIZES)
    icns = encoded(icon(1024), "ICNS")
    # Pillow supplies Retina entries but omits the native 16/32/64px slots.
    for code, size in ((b"icp4", 16), (b"icp5", 32), (b"icp6", 64)):
        payload = encoded(icon(size))
        icns += code + struct.pack(">I", len(payload) + 8) + payload
    outputs["flutter/macos/Runner/AppIcon.icns"] = (
        icns[:4] + struct.pack(">I", len(icns)) + icns[8:])

    data_uri = "data:image/png;base64," + base64.b64encode(source).decode("ascii")
    for path, size in {"res/icon-master.svg": 1254, "res/scalable.svg": 1254,
                       "flutter/assets/icon.svg": 1254, "res/logo.svg": 26}.items():
        outputs[path] = (
            '<svg xmlns="http://www.w3.org/2000/svg" '
            'xmlns:xlink="http://www.w3.org/1999/xlink" '
            f'width="{size}" height="{size}" viewBox="0 0 1254 1254">'
            f'<image width="1254" height="1254" xlink:href="{data_uri}"/>'
            '</svg>\n').encode("utf-8")

    # Keep the existing lettering pixels. Only the left 54-pixel badge slot
    # changes, so rebuilding does not depend on fonts or redraw the wordmark.
    for name in ("logo.png", "logo_light.png", "logo_dark.png"):
        path = "flutter/assets/" + name
        wordmark = Image.open(ROOT / path).convert("RGBA")
        if wordmark.size != (300, 60):
            raise ValueError(f"Unexpected wordmark dimensions: {path}")
        wordmark.paste((0, 0, 0, 0), (0, 0, 54, 60))
        wordmark.alpha_composite(icon(54), (0, 3))
        png(path, wordmark)

    catalog = ROOT / "flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for row in json.loads((catalog / "Contents.json").read_text())["images"]:
        name = row["filename"]
        if Path(name).name != name:
            raise ValueError("AppIcon filenames must stay inside their catalog.")
        size = round(float(row["size"].split("x")[0]) * float(row["scale"][:-1]))
        matte = Image.new("RGB", (size, size), BACKGROUND)
        image = icon(size)
        matte.paste(image, mask=image.getchannel("A"))
        png((catalog / name).relative_to(ROOT).as_posix(), matte)

    android = "flutter/android/app/src/main/res/"
    for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96,
                          "xxhdpi": 144, "xxxhdpi": 192}.items():
        directory = android + "mipmap-" + density + "/"
        png(directory + "ic_launcher.png", icon(size))
        png(directory + "ic_launcher_round.png", icon(size))
        # Adaptive icons use a 108dp canvas and a 66dp safe foreground area.
        canvas = round(size * 108 / 48)
        inset_size = round(size * 66 / 48)
        foreground = Image.new("RGBA", (canvas, canvas))
        offset = (canvas - inset_size) // 2
        foreground.alpha_composite(icon(inset_size), (offset, offset))
        png(directory + "ic_launcher_foreground.png", foreground)
        png(directory + "ic_launcher_monochrome.png", template(foreground))
        png(directory + "ic_stat_logo.png", template(icon(size // 2)))
    outputs[android + "values/ic_launcher_background.xml"] = (
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        '    <color name="ic_launcher_background">#11171B</color>\n'
        '</resources>\n').encode("utf-8")
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        path = android + "mipmap-anydpi-v26/" + name
        text = (ROOT / path).read_text(encoding="utf-8")
        text, count = re.subn(
            r'<monochrome android:drawable="@mipmap/ic_launcher_(foreground|monochrome)"/>',
            '<monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>', text)
        if count != 1:
            raise ValueError(f"Unexpected adaptive icon definition: {path}")
        outputs[path] = text.encode("utf-8")

    # Sciter embeds two PNGs in this function. Replace those exact literals;
    # preserve its public API, platform branches, comments and all other code.
    path = "src/ui.rs"
    text = (ROOT / path).read_text(encoding="utf-8")
    anchor = "pub fn get_icon() -> String {"
    if text.count(anchor) != 1:
        raise ValueError("Expected exactly one get_icon() anchor in src/ui.rs.")
    start = text.index(anchor)
    end = text.index("\n}\n", start) + 2
    block = text[start:end]
    if block.count('#[cfg(target_os = "macos")]') != 1 or block.count(
            '#[cfg(not(target_os = "macos"))]') != 1:
        raise ValueError("Unexpected get_icon() platform branches.")
    mac = Image.new("RGBA", (160, 160))
    mac.alpha_composite(icon(128), (16, 16))
    replacements = iter((mac.resize((128, 128), Image.Resampling.LANCZOS), icon(128)))
    block, count = re.subn(
        r'"data:image/png;base64,[A-Za-z0-9+/=]+"',
        lambda _: '"data:image/png;base64,' + base64.b64encode(
            encoded(next(replacements))).decode("ascii") + '"', block)
    if count != 2:
        raise ValueError("Expected exactly two embedded get_icon() PNG literals.")
    outputs[path] = (text[:start] + block + text[end:]).encode("utf-8")
    return outputs


def verify_formats(outputs):
    for path in outputs:
        if path.endswith(".png"):
            with Image.open(ROOT / path) as image:
                image.load()
                with Image.open(io.BytesIO(outputs[path])) as expected:
                    assert image.size == expected.size, path
                if "/ios/" in path:
                    assert image.mode == "RGB", path
                else:
                    assert image.mode == "RGBA", path
                    assert image.getchannel("A").getextrema()[0] == 0, path
    for path, sizes in (("res/icon.ico", ICO_SIZES),
                        ("flutter/windows/runner/resources/app_icon.ico", ICO_SIZES),
                        ("res/tray-icon.ico", TRAY_SIZES)):
        with Image.open(ROOT / path) as image:
            assert image.ico.sizes() == {(s, s) for s in sizes}, path
            for size in image.ico.sizes():
                frame = image.ico.getimage(size)
                assert frame.mode == "RGBA" and frame.getchannel("A").getextrema()[0] == 0, path
    with Image.open(ROOT / "flutter/macos/Runner/AppIcon.icns") as image:
        assert {(16, 16, 1), (32, 32, 1), (64, 64, 1), (512, 512, 2)}.issubset(
            image.info["sizes"])
        for size in image.info["sizes"]:
            frame = image.icns.getimage(size)
            assert frame.size == (size[0] * size[2], size[1] * size[2])
            assert frame.mode == "RGBA" and frame.getchannel("A").getextrema()[0] == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify without writing")
    args = parser.parse_args()
    outputs = generate()
    differences = [path for path, data in outputs.items()
                   if not (ROOT / path).exists() or (ROOT / path).read_bytes() != data]
    if args.check and differences:
        print("Out-of-date icon assets:\n" + "\n".join(differences), file=sys.stderr)
        return 1
    if not args.check:
        for path, data in outputs.items():
            target = ROOT / path
            if not target.resolve().is_relative_to(ROOT):
                raise ValueError(f"Icon output escaped repository: {path}")
            target.write_bytes(data)
    verify_formats(outputs)
    print(f"Verified {len(outputs)} outputs; approved master SHA-256 {MASTER_SHA256}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
