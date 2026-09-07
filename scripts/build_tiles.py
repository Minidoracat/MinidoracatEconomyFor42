# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Build the mod's world-object tiles from source art.

    uv run scripts/build_tiles.py            # assets/tiles/<set>/{S,E,N,W}.png -> pack + tiledef + icons
    uv run scripts/build_tiles.py --check    # parse what is shipped and print the entries

Output (all under the mod's 42/media/):
    texturepacks/MinidoracatEconomy.pack     texture pack, format version 1 (PZPK header):
                                             TexturePackDevice.java:87-150 / TexturePackPage.java:103-151
    MinidoracatEconomy_tiles.tiles           tile definitions, "tdef" version 1:
                                             IsoWorld.java:622-760 (LoadTileDefinitions)
    ../../mod.info needs:  pack=MinidoracatEconomy   tiledef=MinidoracatEconomy_tiles <FILE_NUMBER>

Conventions (checked against vanilla Tiles2x.pack and B42 tile mods such as DylansTiles):
    * cells are 128x256 (Core.tileScale == 2 art; texture2x=true is the default option, and a
      128x256 texture is drawn 1:1 there, IsoSprite.java:1566-1572);
    * each entry stores the trimmed opaque rectangle (x, y, w, h in the page) plus its offset in
      the cell (ox, oy) and the cell size (fx, fy);
    * sprite names are <tileset>_<index>; the tiledef gives every index a stable sprite id
      (IsoWorld.getSpriteID) so client and server agree on what a placed object is.

Facing order follows vanilla furniture: 0 = S (front toward lower-left), 1 = E, 2 = N, 3 = W.
Every tileset in TILESETS lands on the same pack page and in the same tiledef (tileset numbers
1, 2, ... in file order; IsoWorld.java:670-701 maps <file, tileset, index> to the sprite id).
"""
from __future__ import annotations

import argparse
import io
import struct
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MEDIA = ROOT / "MOD/MinidoracatEconomyFor42/Contents/mods/MinidoracatEconomyFor42/42/media"
PACK_NAME = "MinidoracatEconomy"
TILEDEF_NAME = "MinidoracatEconomy_tiles"
FILE_NUMBER = 7429            # tiledef file number (100..8189); must be unique across loaded mods
FACES = ["S", "E", "N", "W"]
CELL_W, CELL_H = 128, 256
MAX_W = 124                   # never wider than the tile footprint (vanilla consoles are 114)

# One entry per world object: source folder under assets/tiles/, object height inside the cell
# (one machine, so every facing shares it), the lowest opaque row inside the 256 cell, and the
# build-menu icon (optionally only the top part of the S face: a full-body figure is a smear at
# 64px, her head and tablet are not). The ATM is a box that reaches the front corner of the tile
# like the vanilla consoles (bottom 252); the catgirl stands on a round base centred on the tile,
# so her base rim ends where a floor-centred ellipse does, above the vanilla console front edge.
TILESETS = [
    {"name": "MinidoracatEconomy_terminal", "source": "terminal", "height": 176, "bottom": 252,
     "custom_name": "Economy Terminal", "icon": "terminal_icon.png", "icon_top": 1.0},
    {"name": "MinidoracatEconomy_catgirl", "source": "catgirl", "height": 216, "bottom": 236,
     "custom_name": "Economy Terminal (Catgirl)", "icon": "catgirl_icon.png", "icon_top": 0.42},
]

PROPS = {
    "BlocksPlacement": "",
    "GroupName": "Economy",
    "Material": "Electric",
    "MaterialType": "Metal",
    "solidtrans": "",
}


def fit_face(path: Path, target_h: int, bottom_y: int) -> Image.Image:
    """Trim the alpha bbox, scale to the shared height and seat it on the tile floor."""
    img = Image.open(path).convert("RGBA")
    bbox = img.getbbox()
    if not bbox:
        raise SystemExit(f"{path}: fully transparent")
    img = img.crop(bbox)
    scale = target_h / img.height
    if img.width * scale > MAX_W:
        scale = MAX_W / img.width
    size = (max(1, round(img.width * scale)), max(1, round(img.height * scale)))
    img = img.resize(size, Image.LANCZOS)
    cell = Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0))
    cell.paste(img, ((CELL_W - img.width) // 2, bottom_y - img.height), img)
    return cell


def build_sheet(cells: list[Image.Image]) -> Image.Image:
    sheet = Image.new("RGBA", (CELL_W * len(cells), CELL_H), (0, 0, 0, 0))
    for i, c in enumerate(cells):
        sheet.paste(c, (i * CELL_W, 0))
    return sheet


def u32(v: int) -> bytes:
    return struct.pack("<i", v)


def pstr(s: str) -> bytes:
    b = s.encode("latin-1")
    return u32(len(b)) + b


def write_pack(sheet: Image.Image, cells: list[tuple[str, Image.Image]], out: Path) -> list[tuple]:
    entries = []
    for i, (name, c) in enumerate(cells):
        bbox = c.getbbox() or (0, 0, 1, 1)
        x0, y0, x1, y1 = bbox
        entries.append((name, i * CELL_W + x0, y0, x1 - x0, y1 - y0, x0, y0, CELL_W, CELL_H))
    png = io.BytesIO()
    sheet.save(png, format="PNG", optimize=True)
    png_bytes = png.getvalue()
    page = pstr(f"{PACK_NAME}0") + u32(len(entries)) + u32(1)
    for name, x, y, w, h, ox, oy, fx, fy in entries:
        page += pstr(name) + b"".join(u32(v) for v in (x, y, w, h, ox, oy, fx, fy))
    page += u32(len(png_bytes)) + png_bytes
    data = b"PZPK" + u32(1) + u32(1) + page
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(data)
    return entries


def write_tiledef(out: Path) -> None:
    def line(s: str) -> bytes:
        return s.encode("latin-1") + b"\n"     # IsoWorld.readString: LF only, CR is rejected
    body = b"tdef" + u32(1) + u32(len(TILESETS))
    for number, ts in enumerate(TILESETS, start=1):
        body += line(ts["name"]) + line(f"{ts['name']}.png")
        body += u32(len(FACES)) + u32(1) + u32(number) + u32(len(FACES))
        for face in FACES:
            props = dict(PROPS)
            props["CustomName"] = ts["custom_name"]
            props["Facing"] = face
            body += u32(len(props))
            for k, v in props.items():
                body += line(k) + line(v)
    out.write_bytes(body)


def write_icon(src: Path, out: Path, top: float = 1.0, size: int = 64) -> None:
    """Square build-menu icon (xuiSkin Icon=, loaded by Texture.trygetTexture) from the S face."""
    img = Image.open(src).convert("RGBA")
    img = img.crop(img.getbbox())
    if top < 1.0:
        img = img.crop((0, 0, img.width, max(1, round(img.height * top))))
        img = img.crop(img.getbbox())
    scale = (size - 4) / max(img.width, img.height)
    img = img.resize((max(1, round(img.width * scale)), max(1, round(img.height * scale))), Image.LANCZOS)
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(img, ((size - img.width) // 2, (size - img.height) // 2), img)
    out.parent.mkdir(parents=True, exist_ok=True)
    icon.save(out, optimize=True)


def check() -> None:
    pack = MEDIA / "texturepacks" / f"{PACK_NAME}.pack"
    data = pack.read_bytes()
    pos = 0

    def rint() -> int:
        nonlocal pos
        v = struct.unpack_from("<i", data, pos)[0]
        pos += 4
        return v

    def rstr() -> str:
        nonlocal pos
        n = rint()
        s = data[pos:pos + n].decode("latin-1")
        pos += n
        return s

    assert data[:4] == b"PZPK", "not a version 1 pack"
    pos = 4
    version, pages = rint(), rint()
    print(f"{pack.name}: version {version}, {pages} page(s), {len(data)} bytes")
    for _ in range(pages):
        name, n, mask = rstr(), rint(), rint()
        for _ in range(n):
            en = rstr()
            vals = [rint() for _ in range(8)]
            print(f"  {en}: rect {vals[0]},{vals[1]} {vals[2]}x{vals[3]} offset {vals[4]},{vals[5]} cell {vals[6]}x{vals[7]}")
        plen = rint()
        img = Image.open(io.BytesIO(data[pos:pos + plen]))
        print(f"  page {name}: mask={mask} png {img.size}")
        pos += plen
    tiles = (MEDIA / f"{TILEDEF_NAME}.tiles").read_bytes()
    assert tiles[:4] == b"tdef"
    print(f"{TILEDEF_NAME}.tiles: {len(tiles)} bytes, file number {FILE_NUMBER}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    if args.check:
        check()
        return
    cells: list[tuple[str, Image.Image]] = []
    for ts in TILESETS:
        source = ROOT / "assets/tiles" / ts["source"]
        faces = [fit_face(source / f"{face}.png", ts["height"], ts["bottom"]) for face in FACES]
        build_sheet(faces).save(source / "sheet_preview.png")
        cells += [(f"{ts['name']}_{i}", c) for i, c in enumerate(faces)]
        write_icon(source / "S.png", MEDIA / "ui" / "MinidoracatEconomy" / ts["icon"], ts["icon_top"])
    sheet = build_sheet([c for _, c in cells])
    entries = write_pack(sheet, cells, MEDIA / "texturepacks" / f"{PACK_NAME}.pack")
    write_tiledef(MEDIA / f"{TILEDEF_NAME}.tiles")
    for e in entries:
        print(f"{e[0]}: {e[3]}x{e[4]} at {e[5]},{e[6]}")
    icons = ", ".join(f"ui/MinidoracatEconomy/{ts['icon']}" for ts in TILESETS)
    print(f"wrote {PACK_NAME}.pack, {TILEDEF_NAME}.tiles (file number {FILE_NUMBER}) and {icons}")


if __name__ == "__main__":
    sys.exit(main())
