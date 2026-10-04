# SuperXD 中转服务（superxd-relay）

功能性私信的“哑信箱”：只转交端到端密文，看不到课表、界面配置、作品链接或昵称。客户端在 lib/social。

技术栈：NestJS 12（ESM）+ TypeORM + MySQL 8.4 + Redis 8，swc 构建，Vitest 测试。分层：每个领域模块（device、invite、friend、message）对外只暴露服务与仓储端口（抽象类），TypeORM / Redis 实现可替换；跨领域的编排（扫码加好友、删除设备、数据保留清理）在 pairing 模块。

# 协议 v1

身份与签名
- 设备身份是 Ed25519 签名公钥；设备号 = base64url(sha256(签名公钥) 前 16 字节)，22 个字符。另有 X25519 加密公钥，服务端只存档不使用。
- 每个请求带 x-sxd-device、x-sxd-time（毫秒）、x-sxd-nonce（16 字节 base64url）、x-sxd-signature。签名原文为以下各项换行连接：SXD1、方法、路径含查询串、时间、随机数、请求体 sha256 的 base64url。
- 时间与服务器相差超过 5 分钟返回 CLOCK_SKEW 并附 serverTime；随机数 10 分钟内不能重复（REPLAYED）。验签通过后才占用随机数。
- 没有会话令牌：测试期用 IP + 明文 HTTP 时，截获的请求也无法冒用或重放；正式域名换 HTTPS 后同样适用。
- 双端一致性由 test/vectors/protocol_v1.json 守护，客户端 test/social_protocol_test.dart 读同一份文件。

接口（base64url 一律无填充）
- GET /v1/health：免签名，返回协议版本与服务器时间。
- POST /v1/devices：注册（自签名，请求体带两把公钥），幂等。DELETE /v1/devices：删除本设备及其好友关系与待取消息（用户关闭私信）。
- POST /v1/invites：登记邀请号与邀请公钥，5 分钟有效，同时作废本设备旧邀请。DELETE /v1/invites/:id：作废。
- POST /v1/friends/redeem：扫码方提交邀请号、凭证（邀请私钥对“SXD1-invite、邀请号、扫码方设备号”的签名）与给邀请人的问候密文；关系与问候同一事务写入。邀请有效期内可多人使用。
- GET /v1/friends、DELETE /v1/friends/:peer（双向解除）。
- POST /v1/messages：投递密文，按（发送方, clientId）幂等，只能发给好友。GET /v1/messages?after=&limit=：按 id 游标取。POST /v1/messages/ack：确认即删除。

错误响应统一为 {code, message, ...}，code 登记在 src/common/relay_error.ts，客户端 lib/social/relay_client.dart 的 RelayCode 保持一致。

# 上限与保留（src/common/relay_limits.ts）

- 好友每设备 500；单条密文 256KB；每设备待取 1000 条，超出返回 MAILBOX_FULL。
- 发送每设备每分钟 30 条、每天 500 条；同一 IP 每小时注册 20 台新设备；兑换邀请每设备每分钟 10 次。
- 取走并确认的消息立即删除；未取走的 30 天后删除；设备 400 天不活跃连同关系与信箱删除。清理任务每 10 分钟一次，多实例抢分布式锁，每批 1000 行、每轮最多 20 批。
- Redis 只放可丢的运行态（邀请、随机数、限流计数、写库节流标记），丢了的后果是邀请需重新出示、限流归零；权威数据只在 MySQL。

# 本地开发与测试

- 环境变量见 .env.example，只在 src/config/env.ts 读取，缺必填项启动即失败。
- 起测试库：docker compose -f docker-compose.test.yml up -d --wait（宿主机网络，MySQL 3307、Redis 6380，库在内存里）。
- npm test：类型检查用 npm run typecheck；e2e 覆盖注册、签名、防重放、校时、扫码加好友（多人、凭证防盗用、作废）、收发幂等、分页、上限、关闭私信与数据保留。
- npm run dev：swc 监听编译，bun 运行并在产物变化时重启。
- 客户端联调：仓库根目录 flutter test tool/verify_social.dart --dart-define=SUPERXD_RELAY=http://127.0.0.1:端口。

# 部署（单机 Docker Compose）

1. 安装 Docker 与 Compose 插件。
2. 复制本目录到服务器，cp .env.example .env，把三个密码换成随机长串（如 openssl rand -hex 24，只留在服务器上）；RELAY_PUBLIC_PORT 为对外端口。国内服务器：NPM_REGISTRY 改为 https://registry.npmmirror.com；Docker Hub 不通时在 /etc/docker/daemon.json 配 registry-mirrors（如 https://docker.m.daocloud.io、https://docker.1ms.run）。
3. docker compose up -d --build。首次启动时 MySQL 自动执行 sql/schema.sql 建表；之后的表结构变更由人工执行，服务启动不做 DDL。
4. curl http://服务器:端口/v1/health 应返回 {"protocol":1,...}。防火墙（云服务器还有安全组）只放行中转端口，MySQL 与 Redis 不对外。
   小内存机器（2GB 以内）已按 compose 里的参数关闭 MySQL performance_schema、缓冲池 128MB。
5. 客户端构建时传入地址：flutter build apk --flavor alpha --dart-define=SUPERXD_RELAY=http://服务器IP:端口。

换正式域名：在前面加 Nginx 或 Caddy 终止 HTTPS，把 RELAY_TRUST_PROXY 设为 1（按 X-Forwarded-For 取客户端 IP），客户端改用 --dart-define=SUPERXD_RELAY=https://域名 重新构建即可，协议与数据不变。中国大陆服务器使用域名须先完成 ICP 备案。
