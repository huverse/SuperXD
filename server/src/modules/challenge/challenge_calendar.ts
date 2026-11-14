// 轮换挑战的周期按业务时区的日界算（时区只来自 env 的 RELAY_BUSINESS_TIME_ZONE，不写死偏移）：每天从当地 0 点起、每周从当地周一 0 点起。
// 返回的是 UTC 绝对时刻；时区数据用运行时自带的 Intl，夏令时切换日也按当地日界换算（先猜再按当时的偏移校正一次）。

const partsOf = (instant: number, timeZone: string) => {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', weekday: 'short' }).formatToParts(new Date(instant));
  const value = (type: string) => parts.find((part) => part.type === type)!.value;
  return { year: Number(value('year')), month: Number(value('month')), day: Number(value('day')), hour: Number(value('hour')), minute: Number(value('minute')), second: Number(value('second')), weekday: value('weekday') };
};

// 当地这个时刻比 UTC 快多少毫秒。
const offsetOf = (instant: number, timeZone: string) => {
  const local = partsOf(instant, timeZone);
  return Date.UTC(local.year, local.month - 1, local.day, local.hour, local.minute, local.second) - Math.floor(instant / 1000) * 1000;
};

// 当地某一天 0 点的 UTC 时刻。
const localMidnight = (year: number, month: number, day: number, timeZone: string) => {
  const guess = Date.UTC(year, month - 1, day);
  const first = guess - offsetOf(guess, timeZone);
  return guess - offsetOf(first, timeZone);
};

const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

export type ChallengePeriod = 'day' | 'week';

// now 所在周期的起止（UTC 毫秒）与起始那天的当地日期（YYYY-MM-DD，拼进挑战编号）。
export const periodOf = (now: number, every: ChallengePeriod, timeZone: string) => {
  const local = partsOf(now, timeZone);
  const back = every === 'week' ? weekdays.indexOf(local.weekday) : 0;
  const first = new Date(Date.UTC(local.year, local.month - 1, local.day - back));
  const next = new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth(), first.getUTCDate() + (every === 'week' ? 7 : 1)));
  return {
    start: localMidnight(first.getUTCFullYear(), first.getUTCMonth() + 1, first.getUTCDate(), timeZone),
    end: localMidnight(next.getUTCFullYear(), next.getUTCMonth() + 1, next.getUTCDate(), timeZone),
    date: first.toISOString().slice(0, 10),
  };
};
