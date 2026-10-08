import { isIPv6 } from 'node:net';

// 按来源 IP 限流时的计数主体：IPv4（含 IPv4 映射的 IPv6）按完整地址；IPv6 按 /64 前缀聚合。
// 一个家宽、一台主机通常分到整段 /64，按完整 IPv6 地址计数可以随手换地址绕过限流。
export const rateSubjectOf = (ip: string): string => {
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(ip);
  if (mapped) return mapped[1];
  const address = ip.split('%')[0];
  if (!isIPv6(address)) return ip;
  const [head, tail = ''] = address.split('::');
  const left = head ? head.split(':') : [];
  const right = tail ? tail.split(':') : [];
  const groups = address.includes('::') ? [...left, ...Array<string>(8 - left.length - right.length).fill('0'), ...right] : left;
  return `${groups.slice(0, 4).map((group) => parseInt(group, 16).toString(16)).join(':')}::/64`;
};
