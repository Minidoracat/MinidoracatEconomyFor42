const DAY_MS = 86_400_000;

function formatter(timeZone: string): Intl.DateTimeFormat {
  return new Intl.DateTimeFormat("en-US-u-ca-iso8601-nu-latn", {
    timeZone, year: "numeric", month: "2-digit", day: "2-digit",
  });
}

function formattedDate(format: Intl.DateTimeFormat, timestamp: number): string {
  let year = "", month = "", day = "";
  for (const part of format.formatToParts(timestamp)) {
    if (part.type === "year") year = part.value.padStart(4, "0");
    if (part.type === "month") month = part.value;
    if (part.type === "day") day = part.value;
  }
  return `${year}-${month}-${day}`;
}

export function dateInZone(timestamp: number, timeZone: string): string {
  return formattedDate(formatter(timeZone), timestamp);
}

export function shiftDate(date: string, days: number): string {
  const ms = Date.parse(`${date}T00:00:00.000Z`);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !Number.isFinite(ms)
      || new Date(ms).toISOString().slice(0, 10) !== date) {
    throw new Error(`無效日期：${date}；請使用 YYYY-MM-DD`);
  }
  const shifted = new Date(ms + days * DAY_MS).toISOString().slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(shifted)) throw new Error("日期超出四位數年份範圍");
  return shifted;
}

function offsetAt(format: Intl.DateTimeFormat, timestamp: number): number {
  let year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0, beforeCommonEra = false;
  for (const part of format.formatToParts(timestamp)) {
    if (part.type === "year") year = Number(part.value);
    if (part.type === "month") month = Number(part.value);
    if (part.type === "day") day = Number(part.value);
    if (part.type === "hour") hour = Number(part.value);
    if (part.type === "minute") minute = Number(part.value);
    if (part.type === "second") second = Number(part.value);
    if (part.type === "era") beforeCommonEra = part.value === "BC";
  }
  const local = new Date(0);
  local.setUTCFullYear(beforeCommonEra ? 1 - year : year, month - 1, day);
  local.setUTCHours(hour, minute, second, 0);
  return local.getTime() - Math.floor(timestamp / 1000) * 1000;
}

export function reportPeriod(date: string, timeZone: string): { fromMs: number; toMs: number } {
  shiftDate(date, 1);
  const anchor = Date.parse(`${date}T00:00:00.000Z`);
  const format = new Intl.DateTimeFormat("en-US-u-ca-iso8601-nu-latn", {
    timeZone, year: "numeric", month: "2-digit", day: "2-digit", era: "short",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
  });
  const start = anchor - 3 * DAY_MS, end = anchor + 3 * DAY_MS;
  let segmentStart = start, offset = offsetAt(format, start);
  const intervals: { fromMs: number; toMs: number }[] = [];
  const addSegment = (until: number): void => {
    const fromMs = Math.max(segmentStart, anchor - offset);
    const toMs = Math.min(until, anchor + DAY_MS - offset);
    if (fromMs >= toMs) return;
    const previous = intervals.at(-1);
    if (previous !== undefined && previous.toMs === fromMs) previous.toMs = toMs;
    else intervals.push({ fromMs, toMs });
  };
  // Locate IANA offset transitions hourly, then bisect their exact boundary.
  // Calendar dates themselves can go backwards (e.g. St_Johns midnight DST).
  for (let sample = start + 3600000; sample <= end; sample += 3600000) {
    const nextOffset = offsetAt(format, sample);
    if (nextOffset === offset) continue;
    let low = sample - 3600000, high = sample;
    while (low < high) {
      const mid = low + Math.floor((high - low) / 2);
      if (offsetAt(format, mid) === offset) low = mid + 1;
      else high = mid;
    }
    addSegment(low);
    segmentStart = low;
    offset = nextOffset;
  }
  addSegment(end);
  const interval = intervals[0];
  if (interval === undefined) throw new Error(`${timeZone} 不存在這個日期：${date}`);
  if (intervals.length !== 1) {
    throw new Error(`${timeZone} 的 ${date} 跨日回撥，無法表示為單一日期區間；請改用 UTC 及另一個輸出目錄`);
  }
  return interval;
}
