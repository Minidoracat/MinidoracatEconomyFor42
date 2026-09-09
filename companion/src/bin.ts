// Parser for Saves/Multiplayer/<server>/global_mod_data.bin.
//
// Layout (GlobalModData.java:290-299 load, :218-266 save):
//   int32 worldVersion, int32 tableCount, then per table:
//     int32 blockSize, string tag, table
// string = int16 byteLength + UTF-8 bytes (GameWindow.StringUTF.save, GameWindow.java:1264-1271)
// table  = int32 count, then count x (keyByte, key, valueByte, value) for worldVersion >= 25
//          (KahluaTableImpl.java:292-311); type bytes: 0 string, 1 double (8 bytes BE),
//          2 nested table, 3 boolean (1 byte)  (KahluaTableImpl.java:313-327)
// The file is written as global_mod_data.tmp then copied over the .bin (not an atomic rename),
// so callers must tolerate parse failures and keep the previous watermark.

export type LuaValue = string | number | boolean | LuaTable;
export interface LuaTable {
  [key: string]: LuaValue;
}

export interface Watermark {
  epoch: string;
  seq: number;
  realmId: string | null;
}

export interface ParsedModData {
  worldVersion: number;
  tables: Map<string, LuaTable>;
}

class Reader {
  pos = 0;
  readonly buf: Buffer;
  constructor(buf: Buffer) {
    this.buf = buf;
  }

  need(n: number): void {
    if (this.pos + n > this.buf.length) throw new RangeError(`truncated at ${this.pos} (+${n} > ${this.buf.length})`);
  }
  int32(): number { this.need(4); const v = this.buf.readInt32BE(this.pos); this.pos += 4; return v; }
  int16(): number { this.need(2); const v = this.buf.readInt16BE(this.pos); this.pos += 2; return v; }
  byte(): number { this.need(1); const v = this.buf[this.pos] ?? 0; this.pos += 1; return v; }
  double(): number { this.need(8); const v = this.buf.readDoubleBE(this.pos); this.pos += 8; return v; }
  string(): string {
    const n = this.int16();
    if (n <= 0) return "";
    this.need(n);
    const s = this.buf.toString("utf8", this.pos, this.pos + n);
    this.pos += n;
    return s;
  }
}

function readValue(r: Reader, type: number): LuaValue {
  switch (type) {
    case 0: return r.string();
    case 1: return r.double();
    case 3: return r.byte() !== 0;
    case 2: return readTable(r);
    default: throw new TypeError(`invalid lua table type ${type} at ${r.pos}`);
  }
}

function readTable(r: Reader): LuaTable {
  const count = r.int32();
  if (count < 0) throw new RangeError(`negative table count at ${r.pos}`);
  const out: LuaTable = Object.create(null);
  for (let i = 0; i < count; i++) {
    const key = readValue(r, r.byte());
    const value = readValue(r, r.byte());
    if (typeof key === "object") throw new TypeError(`table used as a key at ${r.pos}`);
    out[String(key)] = value;
  }
  return out;
}

export function parseGlobalModData(buf: Buffer): ParsedModData {
  const r = new Reader(buf);
  const worldVersion = r.int32();
  if (worldVersion < 25) throw new RangeError(`unsupported worldVersion ${worldVersion}`);
  const size = r.int32();
  const tables = new Map<string, LuaTable>();
  for (let i = 0; i < size; i++) {
    const blockSize = r.int32();
    const start = r.pos;
    const tag = r.string();
    const table = readTable(r);
    if (r.pos - start !== blockSize) {
      throw new RangeError(`block size mismatch for ${tag}: ${r.pos - start} != ${blockSize}`);
    }
    tables.set(tag, table);
  }
  return { worldVersion, tables };
}

/** Durable watermark of the economy table, or null when the table/meta is absent. */
export function economyWatermark(parsed: ParsedModData, tag: string): Watermark | null {
  const meta = parsed.tables.get(tag)?.meta;
  if (typeof meta !== "object" || meta === null) return null;
  const { epoch, seq, realmId } = meta;
  if (typeof epoch !== "string" || typeof seq !== "number") return null;
  return { epoch, seq, realmId: typeof realmId === "string" ? realmId : null };
}

// Test helper: serialize a JS object the same way the engine does (used by the unit tests only).
export function encodeGlobalModData(worldVersion: number, tables: Map<string, LuaTable>): Buffer {
  const chunks: Buffer[] = [];
  const i32 = (n: number): Buffer => { const b = Buffer.alloc(4); b.writeInt32BE(n); return b; };
  const str = (s: string): Buffer => { const b = Buffer.from(s, "utf8"); const l = Buffer.alloc(2); l.writeInt16BE(b.length); return Buffer.concat([l, b]); };
  const value = (v: LuaValue): Buffer => {
    if (typeof v === "string") return Buffer.concat([Buffer.from([0]), str(v)]);
    if (typeof v === "number") { const b = Buffer.alloc(9); b[0] = 1; b.writeDoubleBE(v, 1); return b; }
    if (typeof v === "boolean") return Buffer.from([3, v ? 1 : 0]);
    return Buffer.concat([Buffer.from([2]), table(v)]);
  };
  const table = (obj: LuaTable): Buffer => {
    const entries = Object.entries(obj);
    const parts = [i32(entries.length)];
    for (const [k, v] of entries) {
      const num = Number(k);
      parts.push(Number.isFinite(num) && String(num) === k ? value(num) : value(k));
      parts.push(value(v));
    }
    return Buffer.concat(parts);
  };
  chunks.push(i32(worldVersion), i32(tables.size));
  for (const [tag, obj] of tables) {
    const body = Buffer.concat([str(tag), table(obj)]);
    chunks.push(i32(body.length), body);
  }
  return Buffer.concat(chunks);
}
