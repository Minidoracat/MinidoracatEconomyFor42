# -*- coding: utf-8 -*-
"""Economy 專屬的檢查：scripts/verify_mod.py 第 19 項會呼叫；單獨跑 `python scripts/verify_local.py`。
2026-11-26 verify_mod.py 換成家族模板時，從舊副本原樣搬來（門檻與掃描範圍不變）：

 翻譯檔分類              — IG_UI.json／UI.json／Sandbox.json 的鍵要以 IGUI_／UI_／Sandbox_ 開頭（JSON 壞掉也列）
 簡中帳目用「账」         — OpenCC tw2sp 把帳目的「帳」轉成「帐」（帳篷的帐）；CN 不得出現「帐」
 12b. 伺服器身分入口     — getUsername() 是客戶端送的名字；server/、shared/ 只准身分模組
                           （ECIdentity.lua）自由使用，ECServer.lua 只准持平或減少（S.login／
                           S.onlineLogin／S.onlineNames／claimedName 的實作），其他檔一律 0；
                           getOnlinePlayers() 只准 ECServer／ECIdentity（在線迭代必須經
                           S.forEachOnline 的身分過濾）
 12c. recovery 以登入名為範圍 — ECRecovery.lua、ECRecoveryJournal.lua 不准出現 S.principal( 與
                           S.onlinePlayer(（帳號可能有多個登入名＝多個存檔；用 S.login／S.onlineLogin）。
                           `--self-test-identity` 對 12b／12c 植入違規自證
 12d. 物品 modData 通知入口 — syncItemModData 這個名字（直接呼叫、pcall(syncItemModData, …)、別名都算）只准
                           出現在 ECServer.lua（S.syncItem）：持有者還沒有 square 時引擎自己丟例外、吃掉，
                           袋子裡的物品通知不到客戶端（2026-11-14）
 13. 無貨幣類 item 腳本   — 主規格 §7.2 不變量
 14. Lua 煙霧測試         — 跑 scripts/smoke_harness.lua；publish_workshop.py 只跑 verify_mod.py，這是發布路徑上唯一的煙霧測試
 16. 車型英文照抄原版      — ECItemNames 的 VEHICLE_CLASSES 與 "%s (%s Vehicle)" 要等於遊戲 EN IG_UI.json 的
                          IGUI_VehicleType_1..3、IGUI_ItemNameMechanicalType（找不到遊戲檔 SKIP，設定 PZ_PATH）
"""
import json
import os
import re
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

passed, failed, skipped = [], [], []

# 豁免清單與 verify_mod.py 共用：scripts/verify_ignore.txt，每行一個子字串樣式（# 開頭為註解）。
IGNORE_PATTERNS = []
_ign = os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify_ignore.txt")
if os.path.isfile(_ign):
    with open(_ign, encoding="utf-8") as _fh:
        for _line in _fh:
            _line = _line.strip()
            if _line and not _line.startswith("#"):
                IGNORE_PATTERNS.append(_line)


def ok(label):
    passed.append(label)
    print(f"  PASS  {label}")


def fail(label, details=None):
    details = details or []
    kept = [d for d in details if not any(p in d for p in IGNORE_PATTERNS)]
    waived = [d for d in details if any(p in d for p in IGNORE_PATTERNS)]
    for d in waived:
        print(f"  WAIVE {label}: {d}（verify_ignore.txt 豁免）")
    if not kept:
        if waived:
            ok(f"{label}（{len(waived)} 筆豁免）")
        else:
            ok(label)
        return
    failed.append(label)
    print(f"  FAIL  {label}")
    for d in kept:
        print(f"        {d}")


def skip(label, why):
    skipped.append(label)
    print(f"  SKIP  {label} — {why}")


def find_media():
    hits = []
    mod_root = os.path.join(REPO, "MOD")
    if os.path.isdir(mod_root):
        for folder in os.listdir(mod_root):
            p = os.path.join(mod_root, folder, "Contents", "mods")
            if not os.path.isdir(p):
                continue
            for inner in os.listdir(p):
                media = os.path.join(p, inner, "42", "media")
                if os.path.isdir(media):
                    hits.append(media)
    return hits


def iter_files(root, exts):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git",)]
        for name in files:
            if os.path.splitext(name)[1] in exts:
                yield os.path.join(base, name)


# ---- 身分入口（第 12b 項）----
# 家族約定「玩家身分」：伺服器上 getUsername() 是客戶端送來的名字，身分一律問 S.login（登入名）
# 或 S.principal（帳號）。只有 ECServer 的身分輔助函式（S.login 的在線比對、claimedName、
# onlineNames）讀原始名字；其他檔一律 0，要新增就改用那些函式，不是調高這裡的數字。
IDENTITY_MODULE = "ECIdentity.lua"
IDENTITY_ONLINE_OK = {"ECIdentity.lua", "ECServer.lua"}
IDENTITY_BASELINE = {"ECServer.lua": 4}
# ---- recovery 以登入名為範圍（第 12c 項）----
# receipt／hold／journal／pendingOuts 屬於單一存檔（登入名）；帳號可能有多個登入名，拿帳號去找
# 在線玩家會用 A 角色的背包判斷 B 存檔的 pending（合併設計 §3、§9-5、§9-9）。
RECOVERY_LOGIN_FILES = {"ECRecovery.lua", "ECRecoveryJournal.lua"}
_RECOVERY_ACCOUNT_CALL = re.compile(r"\bS\s*\.\s*(principal|onlinePlayer)\s*\(")
_ID_LONG_COMMENT = re.compile(r"--\[(=*)\[.*?\]\1\]", re.DOTALL)
_ID_LONG_STRING = re.compile(r"\[(=*)\[.*?\]\1\]", re.DOTALL)
_ID_SHORT_STRING = re.compile(r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'')


def lua_code_only(src):
    src = _ID_LONG_COMMENT.sub(lambda mm: "\n" * mm.group().count("\n"), src)
    src = _ID_LONG_STRING.sub(lambda mm: "\n" * mm.group().count("\n"), src)
    return "\n".join(_ID_SHORT_STRING.sub('""', line).split("--", 1)[0] for line in src.split("\n"))


def identity_issues(sources):
    """sources: [(檔名, 原始碼)]，只放 server/ 與 shared/ 的檔。"""
    issues = []
    for name, src in sources:
        code = lua_code_only(src)
        if name != IDENTITY_MODULE:
            n = len(re.findall(r"\bgetUsername\s*\(", code))
            allowed = IDENTITY_BASELINE.get(name, 0)
            if n > allowed:
                issues.append(f"{name}: getUsername() {n} 處，超過基準 {allowed}（登入名問 S.login、帳號問 "
                              "S.principal、log 用 S.claimedName）")
        if name not in IDENTITY_ONLINE_OK and re.search(r"\bgetOnlinePlayers\s*\(", code):
            issues.append(f"{name}: 直接呼叫 getOnlinePlayers()（改用 S.forEachOnline／S.onlinePlayer／S.onlineLogin）")
    return issues


def recovery_login_issues(sources):
    """sources: [(檔名, 原始碼)]；只檢查 RECOVERY_LOGIN_FILES。"""
    issues = []
    for name, src in sources:
        if name in RECOVERY_LOGIN_FILES:
            for mm in _RECOVERY_ACCOUNT_CALL.finditer(lua_code_only(src)):
                issues.append(f"{name}: S.{mm.group(1)}(（recovery 以登入名為範圍：用 S.login／S.onlineLogin）")
    return issues


def self_test_identity():
    base = [(name, "local u = p:getUsername()\n" * count) for name, count in IDENTITY_BASELINE.items()]
    cases = (
        ("基準本身", base, False),
        ("ECServer 多一處 getUsername", base + [("ECServer.lua", "x = p:getUsername()\n")], True),
        ("其他檔一處 getUsername", base + [("ECMarket.lua", "x = p:getUsername()\n")], True),
        ("新檔案的 getUsername", base + [("ECNew.lua", "x = p:getUsername()\n")], True),
        ("註解與字串不算", base + [("ECNew.lua", "-- p:getUsername()\nlocal s = \"getOnlinePlayers()\"\n"
                                             "--[[ getUsername() ]]\n")], False),
        ("身分模組自由使用", base + [("ECIdentity.lua", "a = p:getUsername()\nb = getOnlinePlayers()\n")], False),
        ("其他檔直接掃在線玩家", base + [("ECMarket2.lua", "local ps = getOnlinePlayers()\n")], True),
    )
    for label, sources, reject in cases:
        merged = {}
        for name, src in sources:
            merged[name] = merged.get(name, "") + src
        if bool(identity_issues(list(merged.items()))) != reject:
            raise AssertionError(label)
    recovery_cases = (
        ("recovery 用登入名", [("ECRecovery.lua", "local p = S.onlineLogin(u)\nlocal l = S.login(p)\n")], False),
        ("recovery 問帳號", [("ECRecovery.lua", "local a = S.principal(p)\n")], True),
        ("journal 以帳號找在線玩家", [("ECRecoveryJournal.lua", "local p = S.onlinePlayer(u)\n")], True),
        ("recovery 註解與字串不算", [("ECRecovery.lua", "-- S.principal(p)\nlocal s = \"S.onlinePlayer(x)\"\n")], False),
        ("其他檔可問帳號", [("ECMailbox.lua", "local a = S.principal(p)\nlocal q = S.onlinePlayer(a)\n")], False),
    )
    for label, sources, reject in recovery_cases:
        if bool(recovery_login_issues(sources)) != reject:
            raise AssertionError(label)
    print("PASS 身分入口：基準、超出基準、其他檔、新檔、註解與字串、身分模組、直接掃在線玩家；"
          "recovery 登入名範圍：登入名、帳號、在線帳號、註解與字串、其他檔")


if __name__ == "__main__" and "--self-test-identity" in sys.argv:
    self_test_identity()
    sys.exit(0)


MEDIA_DIRS = find_media()
if not MEDIA_DIRS:
    print("找不到 MOD/*/Contents/mods/*/42/media，中止")
    sys.exit(2)

LUA_FILES = [f for m in MEDIA_DIRS for f in iter_files(os.path.join(m, "lua"), {".lua"})
             if os.path.isdir(os.path.join(m, "lua"))]

# ---- 翻譯檔分類 / 簡中帳目 ----
TRANSLATION_PREFIXES = {"IG_UI.json": "IGUI_", "UI.json": "UI_", "Sandbox.json": "Sandbox_"}
for m in MEDIA_DIRS:
    troot = os.path.join(m, "lua", "shared", "Translate")
    if not os.path.isdir(troot):
        continue
    langs = sorted(d for d in os.listdir(troot) if os.path.isdir(os.path.join(troot, d)))
    names = sorted({n for l in langs for n in os.listdir(os.path.join(troot, l)) if n.endswith(".json")})
    broken = []
    for n in names:
        prefix = TRANSLATION_PREFIXES.get(n)
        for l in langs:
            p = os.path.join(troot, l, n)
            if not os.path.isfile(p):
                continue
            try:
                with open(p, encoding="utf-8") as fh:
                    data = json.load(fh)
            except Exception as e:
                broken.append(f"{l}/{n}: {e}")
                continue
            for k in data:
                if prefix and not k.startswith(prefix):
                    broken.append(f"{l}/{n}: {k} 必須放在對應前綴的翻譯檔")
    if broken:
        fail("翻譯 JSON 與檔案分類", broken)
    else:
        ok("翻譯 JSON 與檔案分類")
    # OpenCC tw2sp 把台灣的「帳」（帳號、轉帳、對帳）轉成「帐」（帳篷的帐）；簡中的帳目一律寫「账」。
    # 本 MOD 的「帳」全是帳目，所以 CN 不得出現「帐」（改 CN 後跑一次 .replace("帐", "账")）。
    if "CN" in langs:
        zhang = []
        for n in names:
            p = os.path.join(troot, "CN", n)
            if os.path.isfile(p):
                with open(p, encoding="utf-8") as fh:
                    zhang += [f"CN/{n} {k}" for k, v in json.load(fh).items() if isinstance(v, str) and "帐" in v]
        fail("簡中帳目用「账」不用「帐」", zhang) if zhang else ok("簡中帳目用「账」不用「帐」")

# ---- 12b. 伺服器身分入口 ----
_identity_sources = []
for f in LUA_FILES:
    parts = os.path.normpath(f).split(os.sep)
    if "server" in parts or "shared" in parts:
        with open(f, encoding="utf-8", errors="replace") as fh:
            _identity_sources.append((os.path.basename(f), fh.read()))
_identity = identity_issues(_identity_sources)
fail("伺服器身分入口（getUsername／getOnlinePlayers 只經身分閘門）", _identity) if _identity \
    else ok(f"伺服器身分入口（{len(_identity_sources)} 檔）")

# ---- 12c. recovery 以登入名為範圍 ----
_recovery_login = recovery_login_issues(_identity_sources)
fail("recovery 以登入名為範圍（不准 S.principal／S.onlinePlayer）", _recovery_login) if _recovery_login \
    else ok("recovery 以登入名為範圍（" + "、".join(sorted(RECOVERY_LOGIN_FILES)) + "）")

# ---- 12d. 物品 modData 通知入口 ----
_item_sync = [name for name, src in _identity_sources
              if name != "ECServer.lua" and re.search(r"\bsyncItemModData\b", lua_code_only(src))]
fail("物品 modData 通知只經 S.syncItem（syncItemModData 只准 ECServer.lua）", _item_sync) if _item_sync \
    else ok("物品 modData 通知只經 S.syncItem")

# ---- 13. 不得定義貨幣類 item ----
# 主規格 §7.2 不變量：倖存幣／貓幣只存在於伺服器帳本，沒有可掉落／交易的硬幣道具。
_ITEM_RE = re.compile(r"(?:^|[\s{])item\s+([A-Za-z0-9_]+)", re.MULTILINE)
_COIN_RE = re.compile(r"coin|money|cash|currency|banknote|token", re.IGNORECASE)
coin_items = []
for m in MEDIA_DIRS:
    sdir = os.path.join(m, "scripts")
    if not os.path.isdir(sdir):
        continue
    for f in iter_files(sdir, {".txt"}):
        with open(f, encoding="utf-8", errors="replace") as fh:
            for mm in _ITEM_RE.finditer(fh.read()):
                if _COIN_RE.search(mm.group(1)):
                    coin_items.append(f"{os.path.relpath(f, REPO)}: item {mm.group(1)}")
fail("無貨幣類 item 腳本（§7.2 不變量）", coin_items) if coin_items \
    else ok("無貨幣類 item 腳本（§7.2 不變量）")

# ---- 14. Lua 煙霧測試 ----
_lua = shutil.which("lua")
_harness = os.path.join(REPO, "scripts", "smoke_harness.lua")
if not _lua:
    skip("Lua 煙霧測試（smoke_harness.lua）", "PATH 沒有 lua")
elif not os.path.isfile(_harness):
    skip("Lua 煙霧測試（smoke_harness.lua）", "找不到 scripts/smoke_harness.lua")
else:
    _run = subprocess.run([_lua, _harness], cwd=REPO, capture_output=True, text=True, encoding="utf-8", errors="replace")
    _tail = [ln for ln in (_run.stdout + _run.stderr).splitlines() if ln.strip()][-6:]
    fail("Lua 煙霧測試（smoke_harness.lua）", _tail) if _run.returncode != 0 \
        else ok("Lua 煙霧測試（" + (_tail[-1] if _tail else "ok") + "）")

# ---- 16. 車型英文照抄原版 ----
# 英文欄「Gas Tank - Big (Sports Vehicle)」由 ECItemNames 自己組：Lua 讀不到原版 EN 的譯文（非 EN 客戶端只載入
# 自己語言的翻譯），所以 VEHICLE_CLASSES 與格式字串是原版 EN 的抄本。原版改了英文，這裡就紅，照遊戲檔改 Lua。
PZ_PATH = os.environ.get("PZ_PATH", r"D:\SteamLibrary\steamapps\common\ProjectZomboid")
VEHICLE_LABEL = "車型英文與原版 EN IG_UI.json 相同（ECItemNames）"
_ig_ui = os.path.join(PZ_PATH, "media", "lua", "shared", "Translate", "EN", "IG_UI.json")
_names_lua = [f for f in LUA_FILES if os.path.basename(f) == "ECItemNames.lua"]
if not os.path.isfile(_ig_ui):
    skip(VEHICLE_LABEL, f"找不到 {_ig_ui}（設定 PZ_PATH）")
elif len(_names_lua) != 1:
    fail(VEHICLE_LABEL, [f"找到 {len(_names_lua)} 個 ECItemNames.lua，應該剛好一個"])
else:
    with open(_ig_ui, encoding="utf-8") as fh:  # 原版檔是寬鬆 JSON，只取要的鍵
        _vanilla = dict(re.findall(r'"(IGUI_VehicleType_[123]|IGUI_ItemNameMechanicalType)"\s*:\s*"([^"]*)"', fh.read()))
    with open(_names_lua[0], encoding="utf-8") as fh:
        _src = fh.read()
    _classes = re.search(r"local VEHICLE_CLASSES\s*=\s*\{([^}]*)\}", _src)
    _have = re.findall(r'"([^"]*)"', _classes.group(1)) if _classes else None
    _want = [_vanilla.get(f"IGUI_VehicleType_{n}") for n in (1, 2, 3)]
    _fmt = (_vanilla.get("IGUI_ItemNameMechanicalType") or "").replace("%1", "%s").replace("%2", "%s")
    _formats = re.findall(r'string\.format\("([^"]*Vehicle[^"]*)"', _src)
    _bad = []
    if _have != _want:
        _bad.append(f"VEHICLE_CLASSES 是 {_have}，原版 IGUI_VehicleType_1..3 是 {_want}")
    if _formats != [_fmt]:
        _bad.append(f"車型格式字串是 {_formats}，原版 IGUI_ItemNameMechanicalType 換成 %s 後是 {_fmt!r}")
    fail(VEHICLE_LABEL, _bad) if _bad else ok(VEHICLE_LABEL)

sys.exit(1 if failed else 0)
