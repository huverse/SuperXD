import { Logger } from '@nestjs/common';
import { isIPv4 } from 'node:net';
import { IPv4, loadHeaderFromFile, loadVectorIndexFromFile, newWithVectorIndex, type Searcher } from 'ip2region.js';

// 来源 IP 的大致属地（省市一级），只在本机查离线库 ip2region（github.com/lionsoul2014/ip2region，Apache-2.0 或 MIT 任选，官方 JS 查询库 ip2region.js），
// 不调任何外部接口。数据文件 ip2region_v4.xdb 约 11MB，镜像构建时按固定提交下载并核对 sha256（Dockerfile），更新时改那里的提交号与校验和；
// 只用 IPv4 那份（中转只有 IPv4 地址，IPv6 那份 37MB 用不上，IPv6 来源一律查不出）。按向量索引查（常驻内存约 512KB，每次读文件几下），只在扫码登录出示二维码时查。
// 没配 RELAY_IP_REGION_DB（本地开发、测试）或文件读不了时一律查不出，不挡扫码登录。查到什么、IP 原文都不进日志。
// 账号模块按 env 的 ipRegionDb 建一份（account.module.ts 的 useFactory）。
export class IpRegion {
  private readonly logger = new Logger('IpRegion');
  private readonly searcher: Searcher | null;

  constructor(dbPath: string | null) {
    this.searcher = dbPath === null ? null : this.open(dbPath);
  }

  private open(dbPath: string): Searcher | null {
    try {
      if (loadHeaderFromFile(dbPath).ipVersion !== IPv4.id) throw new Error('不是 IPv4 的 xdb');
      return newWithVectorIndex(IPv4, dbPath, loadVectorIndexFromFile(dbPath));
    } catch (error) {
      console.error(error);
      this.logger.error('[IpRegion] action=open errorType=' + (error instanceof Error ? error.constructor.name : typeof error));
      return null;
    }
  }

  // 查不出（没有库、IPv6、保留地址、库里没有）返回空；查询出错打印堆栈后同样为空。
  async regionOf(ip: string): Promise<string | null> {
    const searcher = this.searcher;
    const address = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(ip)?.[1] ?? ip;
    if (searcher === null || !isIPv4(address)) return null;
    try {
      return regionLabel(await searcher.search(address));
    } catch (error) {
      console.error(error);
      this.logger.error('[IpRegion] action=search errorType=' + (error instanceof Error ? error.constructor.name : typeof error));
      return null;
    }
  }
}

// 离线库的一行是「国家|省份|城市|运营商|国家代码」，缺的项写 0：国内写省加市（直辖市、特别行政区只写一次），国外只写国家，保留地址为空；最长 32 字。
export const regionLabel = (raw: string): string | null => {
  const [country = '', province = '', city = '', , code = ''] = raw.split('|');
  const known = (part: string) => part !== '' && part !== '0' && part !== 'Reserved';
  if (!known(country)) return null;
  if (code !== 'CN') return country.slice(0, 32);
  const parts = [province, city].filter(known);
  const label = parts.length === 2 && parts[0] === parts[1] ? parts[0] : parts.join('');
  return (label === '' ? country : label).slice(0, 32);
};
