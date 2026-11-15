import { IpRegion, regionLabel } from 'src/common/ip_region';

// 扫码登录给批准方看的属地（人工决策见 src/modules/account/account.service.ts 的 startJoin）：ip2region 离线库查出的一行写成省市一级。

describe('属地写法', () => {
  it('国内写省加市（直辖市、特别行政区只写一次），国外写国家，保留地址与查不到的为空', () => {
    expect(regionLabel('中国|广东省|深圳市|电信|CN')).toBe('广东省深圳市');
    expect(regionLabel('中国|北京市|北京市|联通|CN')).toBe('北京市');
    expect(regionLabel('中国|香港特别行政区|0|和记环球电讯|CN')).toBe('香港特别行政区');
    expect(regionLabel('中国|0|0|0|CN')).toBe('中国');
    expect(regionLabel('United States|California|0|Google LLC|US')).toBe('United States');
    expect(regionLabel('Reserved|Reserved|Reserved|0|0')).toBeNull();
    expect(regionLabel('0|0|0|0|0')).toBeNull();
    expect(regionLabel('')).toBeNull();
    expect(regionLabel('x'.repeat(80) + '|0|0|0|ZZ')).toHaveLength(32);
  });

  it('没配离线库时查不出（不联网、不报错）；IPv6 与认不出的地址为空', async () => {
    const empty = new IpRegion(null);
    expect(await empty.regionOf('114.114.114.114')).toBeNull();
    expect(await empty.regionOf('::1')).toBeNull();
  });
});

// 本机有离线库时（RELAY_IP_REGION_DB 指向 ip2region_v4.xdb）顺带核对真实查询；CI 不带数据文件，跳过。
describe.runIf(process.env.RELAY_IP_REGION_DB)('真实离线库', () => {
  it('查得出国内与 IPv4 映射的地址，内网为空', async () => {
    const region = new IpRegion(process.env.RELAY_IP_REGION_DB!);
    expect(await region.regionOf('114.114.114.114')).toBe('江苏省南京市');
    expect(await region.regionOf('::ffff:202.96.134.133')).toBe('广东省深圳市');
    expect(await region.regionOf('127.0.0.1')).toBeNull();
    expect(await region.regionOf('240e::1')).toBeNull();
  });
});
