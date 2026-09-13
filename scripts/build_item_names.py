# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Build the mod's own English item-name dictionary from the game's official EN translation.

    uv run --no-project python -B scripts/build_item_names.py --pz-path "D:/SteamLibrary/steamapps/common/ProjectZomboid"
    PZ_PATH=... uv run --no-project python -B scripts/build_item_names.py
    uv run --no-project python -B scripts/build_item_names.py --check      # parse what is shipped

Source (the only truth for an English item name):
    <pz>/media/lua/shared/Translate/EN/ItemName.json      keys are already fullTypes ("Base.Axe")

Output:
    42/media/MinidoracatEconomy_item_names_en.json        UTF-8, no BOM, LF, keys sorted

Why this file exists: after OnScriptsLoaded, ScriptItem.getDisplayName() returns the *translated*
name (Item.java:493-495 reads the Translator entry), so on a Chinese client there is no English
name anywhere in memory. The client reads this dictionary through getModFileReader
(LuaManager.java:5971-6000, UTF-8 InputStreamReader) and layers each activated MOD's own
media/lua/shared/Translate/EN/ItemName.json on top of it, so "canned corn" and "Base.CannedCorn"
find the same item as the localised name does.

Layout contract with the runtime reader (client/MinidoracatEconomy/ECItemNames.lua): exactly one
entry per line, so the client can parse the file a bounded number of lines per tick instead of
decoding 230 KB in a single frame. Values are written with real UTF-8 (never \\uXXXX) and only
the escapes JSON requires.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_PATH = ROOT / "MOD/MinidoracatEconomyFor42/Contents/mods/MinidoracatEconomyFor42/42/media/MinidoracatEconomy_item_names_en.json"
SOURCE_REL = Path("media/lua/shared/Translate/EN/ItemName.json")

# A fullType is <module>.<name>; anything else in the translation file is not an item id we can
# ever be asked about, so it is reported and dropped instead of widening the dictionary.
FULLTYPE_RE = re.compile(r"^[A-Za-z0-9_]+\.[A-Za-z0-9_.\-]+$")
NAME_MAX = 200


def resolve_pz_path(arg: str | None) -> Path:
    raw = arg or os.environ.get("PZ_PATH")
    if not raw:
        sys.exit(
            "no game path: pass --pz-path <ProjectZomboid install dir> or set PZ_PATH.\n"
            "  (the same variable scripts/PZ_Test.ps1 uses; nothing is hardcoded here)"
        )
    path = Path(raw.strip().strip('"'))
    if not (path / SOURCE_REL).is_file():
        sys.exit(f"not a Project Zomboid install (no {SOURCE_REL.as_posix()}): {path}")
    return path


def load_source(pz_path: Path) -> dict[str, str]:
    text = (pz_path / SOURCE_REL).read_bytes().decode("utf-8-sig")
    doc = json.loads(text)
    if not isinstance(doc, dict):
        sys.exit(f"{SOURCE_REL.as_posix()} is not a JSON object")
    return doc


def clean(doc: dict[str, object]) -> tuple[dict[str, str], list[str]]:
    out: dict[str, str] = {}
    dropped: list[str] = []
    for key, value in doc.items():
        if not isinstance(key, str) or not FULLTYPE_RE.match(key):
            dropped.append(f"{key!r}: not a fullType")
            continue
        if not isinstance(value, str):
            dropped.append(f"{key}: value is {type(value).__name__}")
            continue
        name = value.strip()
        if not name:
            dropped.append(f"{key}: empty name")
            continue
        if len(name) > NAME_MAX:
            dropped.append(f"{key}: name longer than {NAME_MAX} chars")
            continue
        # a control character would need a \n / \t escape and break the one-entry-per-line layout
        if any(ord(ch) < 0x20 for ch in name):
            dropped.append(f"{key}: control character in name")
            continue
        out[key] = name
    return out, dropped


def render(entries: dict[str, str]) -> bytes:
    return (json.dumps(entries, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def check(path: Path) -> int:
    if not path.is_file():
        print(f"[check] missing: {path}")
        return 1
    raw = path.read_bytes()
    problems = []
    if raw[:3] == b"\xef\xbb\xbf":
        problems.append("has a UTF-8 BOM")
    if b"\r" in raw:
        problems.append("has CR bytes (must be LF only)")
    text = raw.decode("utf-8")
    doc = json.loads(text)
    lines = text.split("\n")
    # the runtime reader needs one entry per line: line 1 is "{", the last data line has no comma
    entry_lines = 0
    for line in lines:
        stripped = line.strip()
        if stripped in ("{", "}", ""):
            continue
        if re.match(r'^"[^"\\]+": ".*"(,)?$', stripped):
            entry_lines += 1
        else:
            problems.append(f"line not one plain entry: {line[:60]!r}")
    if entry_lines != len(doc):
        problems.append(f"{entry_lines} entry lines for {len(doc)} keys")
    bad_keys = [k for k in doc if not FULLTYPE_RE.match(k)]
    if bad_keys:
        problems.append(f"{len(bad_keys)} keys are not fullTypes, e.g. {bad_keys[:3]}")
    print(f"[check] {path.name}: {len(doc)} entries, {len(raw)} bytes")
    for sample in ("Base.CannedCorn", "Base.Axe", "Base.Nails"):
        if sample in doc:
            print(f"[check]   {sample} -> {doc[sample]!r}")
    for problem in problems:
        print(f"[check] PROBLEM: {problem}")
    return 1 if problems else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pz-path", help="Project Zomboid install dir (default: $PZ_PATH)")
    parser.add_argument("--check", action="store_true", help="validate the shipped dictionary, write nothing")
    args = parser.parse_args()

    if args.check:
        return check(OUT_PATH)

    pz_path = resolve_pz_path(args.pz_path)
    entries, dropped = clean(load_source(pz_path))
    if not entries:
        sys.exit("source dictionary produced no usable entries")
    payload = render(entries)
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    previous = OUT_PATH.read_bytes() if OUT_PATH.is_file() else b""
    OUT_PATH.write_bytes(payload)
    print(f"[build] source: {(pz_path / SOURCE_REL).as_posix()}")
    print(f"[build] wrote {OUT_PATH.relative_to(ROOT).as_posix()}: {len(entries)} entries, {len(payload)} bytes"
          + (" (unchanged)" if payload == previous else ""))
    for note in dropped[:10]:
        print(f"[build] dropped {note}")
    if len(dropped) > 10:
        print(f"[build] dropped {len(dropped) - 10} more")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
