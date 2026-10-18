# SuperXD 中转服务（superxd-relay）

功能性私信的“哑信箱”：只转交端到端密文，看不到课表、界面配置、作品链接或昵称。客户端在 lib/social。
另有一处**代签凭据包的临时信箱**（chaoxing 模块）：学习通代签时对方把凭据包用一次性密钥加密后放这里，取走即删，服务端同样没有解密用的密钥。客户端在 lib/toolbox/chaoxing。
还负责**应用内更新**（app_release 模块）：按渠道给出最新版本清单、下载各架构安装包，内容是发版时放进发布目录的文件，不碰数据库。客户端是 lib/device/relay_release_feed.dart，由 lib/application/app_updates.dart 编排。

技术栈：NestJS 12（ESM）+ TypeORM + MySQL 8.4 + Redis 8，swc 构建，Vitest 测试。分层：每个领域模块（device、invite、friend、message、chaoxing）对外只暴露服务与仓储端口（抽象类），TypeORM / Redis 实现可替换；跨领域的编排（扫码加好友、删除设备、数据保留清理）在 pairing 模块；app_release 只读发布目录，与其他模块无关。

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
- POST /v1/chaoxing/packs：投递代签凭据包（一次性密钥加过密，base64url，≤2KB），返回取件号（12 字节随机数）与作废口令（16 字节随机数，库里只存 sha256）；**不做设备签名**，拿到取件号的人就是收件人，靠取件号随机性、10 分钟过期与按 IP 限流防滥用。POST /v1/chaoxing/packs/:id/pickup：取件，取走即删，重复取或已过期返回 PACK_NOT_FOUND。POST /v1/chaoxing/packs/:id/revoke：出示方凭作废口令作废（换码时作废上一张），一律回 204，不透露包是否存在。代签接口的请求体在解析前按 8KB 封顶。
- GET /v1/app/releases/:channel?abi=：免签名，读发布目录里的 <渠道>.json，返回版本号、版本名、发布时刻、最低可用版本号、更新说明、发布页与这个架构（arm64-v8a、armeabi-v7a、x86_64）的安装包（下载路径、字节数、SHA-256，没有这个架构时为 null）；没有清单返回 RELEASE_NOT_FOUND，清单写坏了回 INTERNAL 并打印堆栈、不往外发。清单按文件修改时间与大小缓存，换文件即生效。GET /v1/app/files/:name：免签名，下载安装包（文件名只许字母数字与 . _ -、以 .apk 结尾），支持 Range 断点续传，文件不在返回 RELEASE_NOT_FOUND。安装包真伪由客户端核对 SHA-256 与签名证书。
- POST /v1/messages：投递密文，按（发送方, clientId）幂等，只能发给好友。GET /v1/messages?after=&limit=&wait=：按 id 游标取；wait（0–25 秒）为长轮询，没有消息时挂起到有新消息、到时或客户端断开。POST /v1/messages/ack：确认即删除。

长轮询
- 先登记等待再查库，查询前后到达的消息都能唤醒，不会漏。投递（含扫码问候，事务提交后）经 Redis 发布订阅频道 {前缀}mail_notify 广播收件设备号，各实例只唤醒自己持有的请求；通知丢了只是等到超时再取，不丢消息。
- 上限：每设备同时挂起 2 个（再来让最早的先返回），每实例 2 万个（超出立即返回空，客户端按最小 5 秒间隔重来）；挂起只占内存与空闲连接，不占数据库连接。
- 前面有 Nginx 等代理时，读超时须大于 35 秒（如 proxy_read_timeout 60s），否则长轮询会被代理提前掐断。

错误响应统一为 {code, message, ...}，code 登记在 src/common/relay_error.ts，客户端 lib/social/relay_client.dart 的 RelayCode 保持一致（代签与应用更新的客户端各按自己用到的码分支，见 relay_error.ts 头部）。

# 上限与保留（src/common/relay_limits.ts）

- 好友每设备 500；单条密文 256KB；每设备待取 1000 条，超出返回 MAILBOX_FULL。
- 发送每设备每分钟 30 条、每天 500 条；同一 IP 每小时注册 20 台新设备；兑换邀请每设备每分钟 10 次。
- 取走并确认的消息立即删除；未取走的 30 天后删除；设备 400 天不活跃连同关系与信箱删除。清理任务每 10 分钟一次，多实例抢分布式锁，消息每批 1000 行、每轮最多 20 批；不活跃设备每批最多 1000 台，按 10 台一个事务连带删除（每台最多约 2000 行好友关系与消息），单个事务行数有界。
- 代签凭据包：单条 ≤2KB，取件号 10 分钟有效，取走即删；同一来源每小时最多提交 1000 个、取件与作废各 3000 次（校园网 NAT 共用出口，见 relay_limits.ts 的人工决策）。过期即取不到，清理任务每 10 分钟一轮删除过期的包（最迟约 20 分钟内删掉）。
- 应用更新：同一来源每小时查清单 600 次、安装包请求 300 次（含断点续传的分段请求）；每个实例同时最多 32 个下载，超出回 503 RATE_LIMITED（retryAfter 60）；清单文件超过 64KB 拒绝读取。发布目录只放当前版本的清单与安装包，发新版时删掉旧包（每个渠道约 3 个安装包、共 300MB 上下）。
- 按 IP 限流的计数主体：IPv4 按完整地址，IPv6 按 /64 前缀（换地址绕不过去）。
- Redis 只放可丢的运行态（邀请、随机数、限流计数、写库节流标记、清理任务锁），权威数据只在 MySQL。丢了的后果：邀请需重新出示、限流归零、锁释放后下一轮重抢；随机数丢了则 5 分钟校时窗口内截获的请求可被重放一次。部署用 maxmemory-policy volatile-ttl（内存满时先淘汰寿命最短的 key，随机数与邀请首当其冲），Redis 内存要留足余量。

# 本地开发与测试

- 环境变量见 .env.example，只在 src/config/env.ts 读取，缺必填项启动即失败。
- 起测试库：docker compose -f docker-compose.test.yml up -d --wait（宿主机网络，MySQL 3307、Redis 6380，库在内存里）。
- npm test：类型检查用 npm run typecheck；npm run build && npm run smoke 检查编译产物能在 Node ESM 下加载（类型导入被编译成运行时导入这类问题只在这里暴露，Vitest 测不到；Docker 构建与 CI 都会跑）；e2e 覆盖注册、签名、防重放、校时、扫码加好友（多人、凭证防盗用、作废）、收发幂等、分页、上限、关闭私信与数据保留；代签凭据包（chaoxing_pack.e2e.test.ts）覆盖取走即删、并发只取到一份、大小与格式、2KB 边界与 8KB 请求体上限、提交与取件限流、作废口令、过期与清理不误删、IPv6 按 /64 聚合；应用更新（app_release.e2e.test.ts）覆盖按架构取包、换清单即生效、清单写坏不外发、参数与文件名校验、整包与 Range 下载、限流。
- npm run dev：swc 监听编译，bun 运行并在产物变化时重启。
- 客户端联调：仓库根目录 flutter test tool/verify_social.dart --dart-define=SUPERXD_RELAY=http://127.0.0.1:端口。

# 部署（单机 Docker Compose）

1. 安装 Docker 与 Compose 插件。
2. 复制本目录到服务器，cp .env.example .env，把三个密码换成随机长串（如 openssl rand -hex 24，只留在服务器上）；RELAY_PUBLIC_PORT 为对外端口。国内服务器：NPM_REGISTRY 改为 https://registry.npmmirror.com；Docker Hub 不通时在 /etc/docker/daemon.json 配 registry-mirrors（如 https://docker.m.daocloud.io、https://docker.1ms.run）。
3. docker compose up -d --build。首次启动时 MySQL 自动执行 sql/schema.sql 建表；之后的表结构变更由人工执行，服务启动不做 DDL。已有的库按日期执行 sql 下的 upgrade_*.sql（先执行升级再部署新版服务），例如 upgrade_2026_10_08.sql 给 chaoxing_pack 加作废口令哈希列。
4. curl http://服务器:端口/v1/health 应返回 {"protocol":1,...}。防火墙（云服务器还有安全组）只放行中转端口，MySQL 与 Redis 不对外。
   小内存机器（2GB 以内）已按 compose 里的参数关闭 MySQL performance_schema、缓冲池 128MB。
5. 客户端构建时传入地址：flutter build apk --flavor alpha --dart-define=SUPERXD_RELAY=http://服务器IP:端口。
6. 应用更新：compose 把本目录下的 releases 只读挂进容器（/srv/releases）。发版时把各架构安装包与 tool/release_manifest.dart 生成的 <渠道>.json 传进 releases，先传安装包、最后传清单（清单一出现客户端就会来下载），再删掉旧版本的安装包；由仓库的发版流水线（.github/workflows/release.yml）自动完成，步骤见仓库根目录 CONTRIBUTING.md。
   流水线用的上传账号只能读写 releases：建系统用户（如 superxd-release，不设密码），把 releases 及其中文件交给它；它的 authorized_keys 只放流水线专用的一把密钥，写成 restrict,command="/usr/bin/rrsync /opt/superxd-relay/releases" ssh-ed25519 …，这把密钥只能经 rsync 读写这个目录，不能登录或执行别的命令。私钥只放进 GitHub 的 relay 环境，主机指纹用 ssh-keyscan 取得后一并存入。

换正式域名：在前面加 Nginx 或 Caddy 终止 HTTPS，把 RELAY_TRUST_PROXY 设为 1（按 X-Forwarded-For 取客户端 IP），客户端改用 --dart-define=SUPERXD_RELAY=https://域名 重新构建即可，协议与数据不变。中国大陆服务器使用域名须先完成 ICP 备案。
