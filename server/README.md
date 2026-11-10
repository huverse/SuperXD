# SuperXD 中转服务（superxd-relay）

功能性私信的“哑信箱”：只转交端到端密文，看不到课表、界面配置、作品链接或昵称。客户端在 lib/social。
另有一处**代签凭据包的临时信箱**（chaoxing 模块）：学习通代签时对方把凭据包用一次性密钥加密后放这里，取走即删，服务端同样没有解密用的密钥。客户端在 lib/toolbox/chaoxing。
还负责**节日抽奖**（reward 模块）：节日里随机发的支付宝口令或二维码红包只放这里、只在这里抽，客户端凭本机随机生成的参与号抽签，概率模型（平权、按活跃度加权、全天均匀放量）与人工决策见 src/modules/reward/reward_odds.ts。客户端在 lib/device/relay_reward_client.dart，由 lib/application/festivals.dart 编排。
还负责**诊断包**（diagnostic 模块）：用户在开发者选项里点「上传诊断包」并确认后，应用把日志包用开发者的公钥加密再传来，这里只按诊断编号存密文、没有下载接口（开发者经 ssh 取出后在本机用私钥解），30 天后删除，人工决策见 lib/domain/diagnostic_upload.dart。客户端是 lib/device/relay_diagnostic_upload.dart。
还负责**应用内更新**（app_release 模块）：按渠道给出最新版本清单、下载各架构安装包，内容是发版时放进发布目录的文件，不碰数据库。客户端是 lib/device/relay_release_feed.dart，由 lib/application/app_updates.dart 编排。

技术栈：NestJS 12（ESM）+ TypeORM + MySQL 8.4 + Redis 8，swc 构建，Vitest 测试。分层：每个领域模块（device、invite、friend、message、chaoxing）对外只暴露服务与仓储端口（抽象类），TypeORM / Redis 实现可替换；跨领域的编排（扫码加好友、删除设备、数据保留清理）在 pairing 模块；app_release 只读发布目录，reward 只管节日抽奖，diagnostic 只收诊断包，都与其他模块无关。

# 协议 v1

身份与签名
- 设备身份是 Ed25519 签名公钥；设备号 = base64url(sha256(签名公钥) 前 16 字节)，22 个字符。另有 X25519 加密公钥，服务端只存档不使用。
- 每个请求带 x-sxd-device、x-sxd-time（毫秒）、x-sxd-nonce（16 字节 base64url）、x-sxd-signature。签名原文为以下各项换行连接：SXD1、方法、路径含查询串、时间、随机数、请求体 sha256 的 base64url。
- 时间与服务器相差超过 5 分钟返回 CLOCK_SKEW 并附 serverTime；随机数 10 分钟内不能重复（REPLAYED）。验签通过后才占用随机数。
- 没有会话令牌：测试期用 IP + 明文 HTTP 时，截获的请求也无法冒用或重放；正式域名换 HTTPS 后同样适用。
- 双端一致性由 test/vectors/protocol_v1.json 守护，客户端 test/social_protocol_test.dart 读同一份文件。

接口（base64url 一律无填充）
- GET /v1/health：免签名，返回协议版本、服务器时间与构建版本 version（流水线构建的镜像是提交号前 12 位，本地开发为 dev；客户端只读前两项）。
- POST /v1/devices：注册（自签名，请求体带两把公钥），幂等。DELETE /v1/devices：删除本设备及其好友关系与待取消息（用户关闭私信）。
- POST /v1/invites：登记邀请号与邀请公钥，5 分钟有效，同时作废本设备旧邀请。DELETE /v1/invites/:id：作废。
- POST /v1/friends/redeem：扫码方提交邀请号、凭证（邀请私钥对“SXD1-invite、邀请号、扫码方设备号”的签名）与给邀请人的问候密文；关系与问候同一事务写入。邀请有效期内可多人使用。
- GET /v1/friends、DELETE /v1/friends/:peer（双向解除）。
- POST /v1/chaoxing/packs：投递代签凭据包（一次性密钥加过密，base64url，≤2KB），返回取件号（12 字节随机数）与作废口令（16 字节随机数，库里只存 sha256）；**不做设备签名**，拿到取件号的人就是收件人，靠取件号随机性、10 分钟过期与按 IP 限流防滥用。POST /v1/chaoxing/packs/:id/pickup：取件，取走即删，重复取或已过期返回 PACK_NOT_FOUND。POST /v1/chaoxing/packs/:id/revoke：出示方凭作废口令作废（换码时作废上一张），一律回 204，不透露包是否存在。代签接口的请求体在解析前按 8KB 封顶。
- GET /v1/app/releases/:channel?abi=：免签名，读发布目录里的 <渠道>.json，返回版本号、版本名、发布时刻、最低可用版本号、更新说明、发布页与这个架构（arm64-v8a、armeabi-v7a、x86_64）的安装包（下载路径、字节数、SHA-256，没有这个架构时为 null）；没有清单返回 RELEASE_NOT_FOUND，清单写坏了回 INTERNAL 并打印堆栈、不往外发。清单按文件修改时间与大小缓存，换文件即生效。GET /v1/app/files/:name：免签名，下载安装包（文件名只许字母数字与 . _ -、以 .apk 结尾），支持 Range 断点续传，文件不在返回 RELEASE_NOT_FOUND。安装包真伪由客户端核对 SHA-256 与签名证书。
- GET /v1/app/notes：免签名、不带任何标识，返回发布目录里 developer_notes.json 的「开发者的话」（最近 30 封，从新到旧）；还没放时给空列表，写坏了回 INTERNAL 并打印堆栈、不往外发，按修改时间与大小缓存。文件由仓库的 notes 流水线（.github/workflows/notes.yml）经同一个受限账号上传。
- POST /v1/rewards/:campaign/draw：免签名，请求体 {participant, activeDays}（参与号是客户端本机生成的 16 字节随机数的 base64url，只存它的 sha256；activeDays 是近 30 天打开过的天数，0–30）。返回 {result, prize}：won 带奖品（kind 为 password 或 qrcode、content、note），missed 没抽中，closed 活动不存在或不在进行。同一活动同一参与号只抽一次，重复请求返回同一结果（含没抽中），并发也只记一次；抽中且这一小时的放量额度与库存都还有才发奖，发奖在活动行上排队、一份只发给一人。
- POST /v1/diagnostics：免签名，请求体是 application/octet-stream 的诊断包密文（版本、一次性 X25519 公钥、随机数、AES-256-GCM 密文与标签，至少 61 字节、最多 24MB，必须声明长度，分块上传拒收；超限与类型不对的在通用解析前按请求头挡掉），按流写进 RELAY_DIAGNOSTICS_DIR，文件名即诊断编号（8 位 Crockford base32），返回 {id, keepDays}；目录满了回 503 MAILBOX_FULL。服务端没有解密用的密钥，也没有下载接口。
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
- 开发者的话：同一来源每小时 600 次；最多 30 封、标题 40 字、正文 4000 字，文件超过 512KB 拒绝读取（与客户端 lib/domain/developer_note.dart 一致）。
- 节日抽奖：同一来源每小时 3000 次；活动行在进程内缓存 60 秒；活动结束 30 天后由每小时一次的清理任务连同奖品与抽签记录分批删除（多实例抢锁，每轮最多 20 批、每批 1000 行）。
- 诊断包：单个 ≤24MB；同一来源每小时 30 个；保留 30 天，到期由每 10 分钟一次的清理任务删除（多实例抢锁，一小时前中途断掉的残片一并删）；目录合计 ≤2GB、≤2000 个，满了回 503。已用量在 Redis 里原子预占、写盘失败退回，清理任务每轮按目录实际重写（Redis 丢了也由它重建）。
- 按 IP 限流的计数主体：IPv4 按完整地址，IPv6 按 /64 前缀（换地址绕不过去）。
- 发送的每分钟与每天两个窗口在一个 Lua 脚本里按顺序计数（一次往返），超了每分钟的不再计入每天的。
- 验签用的设备公钥在进程内缓存（每实例最多 5 万台、每台 10 分钟，多实例下别的实例删掉的设备最迟 10 分钟内这里也不认）；查库没有的设备号在 Redis 记 60 秒，期间同一设备号直接拒绝、不再查库，注册成功即改记「已注册」，新注册立刻在所有实例生效（人工决策见 src/modules/device/device.service.ts）。每次换随机设备号的刷库挡不住（每个新号仍查一次唯一索引），整体流量要在前置代理或安全组按 IP 限速。
- 备份（scripts/backup_db.sh）：每天一份，只留最新 14 份，见「备份与恢复」。
- Redis 只放可丢的运行态（邀请、随机数、限流计数、写库节流标记、设备号负缓存、诊断包目录已用量、清理任务锁），权威数据只在 MySQL。丢了的后果：邀请需重新出示、限流归零、负缓存清空后每个未注册设备号多查一次库、诊断包已用量由下一轮清理任务按目录重建（在那之前上限偏松）、锁释放后下一轮重抢；随机数丢了则 5 分钟校时窗口内截获的请求可被重放一次。部署用 maxmemory-policy volatile-ttl（内存满时先淘汰寿命最短的 key，随机数与邀请首当其冲），Redis 内存要留足余量。

# 本地开发与测试

- 环境变量见 .env.example，只在 src/config/env.ts 读取，缺必填项启动即失败。
- 起测试库：docker compose -f docker-compose.test.yml up -d --wait（宿主机网络，MySQL 3307、Redis 6380，库在内存里）。
- npm test：类型检查用 npm run typecheck；npm run build && npm run smoke 检查编译产物能在 Node ESM 下加载（类型导入被编译成运行时导入这类问题只在这里暴露，Vitest 测不到；Docker 构建与 CI 都会跑）；e2e 覆盖注册、签名、防重放、校时、未注册设备号的负缓存（只查一次库、注册立刻生效、与注册交错不误记）、扫码加好友（多人、凭证防盗用、作废）、收发幂等、分页、上限、发送的分钟与每天限流、关闭私信与数据保留；代签凭据包（chaoxing_pack.e2e.test.ts）覆盖取走即删、并发只取到一份、大小与格式、2KB 边界与 8KB 请求体上限、提交与取件限流、作废口令、过期与清理不误删、IPv6 按 /64 聚合；应用更新（app_release.e2e.test.ts）覆盖按架构取包、换清单即生效、清单写坏不外发、参数与文件名校验、整包与 Range 下载、限流；诊断包（diagnostic.e2e.test.ts）覆盖原样落盘与 600 权限、没有下载、只收二进制、24MB 与分块在读请求体前拒收、限流、目录满回 503、中途断开不留残片并退回额度、到期清理与已用量校正。
- npm run dev：swc 监听编译，bun 运行并在产物变化时重启。
- 客户端联调：仓库根目录 flutter test tool/verify_social.dart --dart-define=SUPERXD_RELAY=http://127.0.0.1:端口。

# 部署（单机 Docker Compose）

1. 安装 Docker 与 Compose 插件。
2. 复制本目录到服务器（git archive <提交>:server 打包，天然不含 .env、node_modules 与 dist），cp .env.example .env，把三个密码换成随机长串（如 openssl rand -hex 24，只留在服务器上）；RELAY_PUBLIC_PORT 为对外端口。国内服务器：NPM_REGISTRY 改为 https://registry.npmmirror.com；Docker Hub 不通时在 /etc/docker/daemon.json 配 registry-mirrors（如 https://docker.m.daocloud.io、https://docker.1ms.run）。
3. 中转镜像按下面「镜像部署与回滚」加载，再 docker compose up -d --no-build（只在没有流水线镜像时才用 --build 在服务器上构建，小内存机器上约 6 分钟）。首次启动时 MySQL 自动执行 sql/schema.sql 建表；之后的表结构变更由人工执行，服务启动不做 DDL。已有的库按日期执行 sql 下的 upgrade_*.sql（先备份、再执行升级、最后部署新版服务），例如 upgrade_2026_10_08.sql 给 chaoxing_pack 加作废口令哈希列。
4. curl http://服务器:端口/v1/health 应返回 {"protocol":1,...,"version":"<提交号>"}。防火墙（云服务器还有安全组）只放行中转端口，MySQL 与 Redis 不对外。
   小内存机器（2GB 以内）已按 compose 里的参数关闭 MySQL performance_schema、缓冲池 128MB。
   MySQL 与 Redis 镜像在 compose 里固定到补丁版：第一次按固定版本启动（或以后改版本）会换掉服务器上原来的镜像，MySQL 在 8.4 长期支持线内原地升级，先跑一次备份。
5. 客户端构建时传入地址：flutter build apk --flavor alpha --dart-define=SUPERXD_RELAY=http://服务器IP:端口。
6. 应用更新：compose 把本目录下的 releases 只读挂进容器（/srv/releases）。发版时把各架构安装包与 tool/release_manifest.dart 生成的 <渠道>.json 传进 releases，先传安装包、最后传清单（清单一出现客户端就会来下载），再删掉旧版本的安装包；由仓库的发版流水线（.github/workflows/release.yml）自动完成，步骤见仓库根目录 CONTRIBUTING.md。
   节日抽奖：库按 sql/upgrade_2026_10_23.sql 建三张表后再部署；每次节日在服务器上进中转容器执行维护命令（用法见 src/modules/reward/reward_admin.ts 文件头）：create 建活动（编号、带时区的起止时刻、模式、基础概率、加权上限），import 从标准输入导入奖品（每行「口令<TAB>内容」或「二维码<TAB>内容」，可加附言），status 看发放情况。奖品只经标准输入进库，不放进仓库、不落地成文件。
   诊断包：compose 把命名卷 diagnostics 挂到容器 /srv/diagnostics（镜像里这个目录归 node，命名卷第一次创建时沿用，非 root 进程能写），不用改 .env。用户报来诊断编号后，在服务器 /opt/superxd-relay 下 docker compose cp relay:/srv/diagnostics/<诊断编号> /tmp/<诊断编号> 取出，拷回开发者本机用 tool/open_diagnostic.dart 解开（私钥只在开发者本机，见该文件头）；用户要求提前删除时 docker compose exec relay rm /srv/diagnostics/<诊断编号>。
   流水线用的上传账号只能读写 releases：建系统用户（如 superxd-release，不设密码），把 releases 及其中文件交给它；它的 authorized_keys 只放流水线专用的一把密钥，写成 restrict,command="/usr/bin/rrsync /opt/superxd-relay/releases" ssh-ed25519 …，这把密钥只能经 rsync 读写这个目录，不能登录或执行别的命令。私钥只放进 GitHub 的 relay 环境，主机指纹用 ssh-keyscan 取得后一并存入。

换正式域名：在前面加 Nginx 或 Caddy 终止 HTTPS，把 RELAY_TRUST_PROXY 设为 1（按 X-Forwarded-For 取客户端 IP），客户端改用 --dart-define=SUPERXD_RELAY=https://域名 重新构建即可，协议与数据不变。中国大陆服务器使用域名须先完成 ICP 备案。

# 镜像部署与回滚

镜像由流水线构建，服务器只加载（人工决策见 .github/workflows/relay-image.yml）：main 上 server 目录有改动就构建一次，镜像标签与 /v1/health 的 version 都是提交号前 12 位。部署仍由维护者在用户当次授权后手动执行，流水线不接触服务器。

1. 取镜像包（主路径）：在 Actions 的 Relay image 运行页下载产物 superxd-relay-<版本>（含 superxd-relay-<版本>.tar.gz 与 .sha256，保留 30 天），传到服务器的 /opt/superxd-relay/images，sha256sum -c superxd-relay-<版本>.tar.gz.sha256 核对后 docker load -i superxd-relay-<版本>.tar.gz。
   备选：服务器能连上 ghcr.io 时 docker pull ghcr.io/huverse/superxd-relay:<版本>，再 docker tag 成 superxd-relay:<版本>（包默认私有，要先在包设置里改公开或用只读令牌登录）。
2. 同步配置：本次提交的 server 目录（compose、sql、scripts）照第 2 步 git archive 覆盖上去；有新的 upgrade_*.sql 先跑备份再执行。
3. 记下正在跑的镜像（回滚用）：docker inspect -f '{{.Config.Image}}' superxd-relay-relay-1（容器名以 docker compose ps 为准）。
4. 把 .env 里的 RELAY_IMAGE 改成 superxd-relay:<版本>，docker compose up -d --no-build --no-deps relay。--no-build 让标签写错时直接报错，不会在服务器上现场构建；--no-deps 不顺带重建 MySQL 与 Redis。
5. 核对：docker inspect -f '{{.State.Health.Status}}' 容器名 变成 healthy（约半分钟内），curl /v1/health 的 version 等于这次的版本，docker logs 没有报错。
6. 回滚：RELAY_IMAGE 改回第 3 步记下的标签，同样 docker compose up -d --no-build --no-deps relay。所以服务器上至少留着上一个版本的镜像，更早的再用 docker image rm 删；表结构只做加法（upgrade_*.sql 只加表加列），回滚旧镜像不用回退表结构。

不要把 RELAY_BUILD_VERSION 写进 .env：env_file 会把它注入容器，盖掉镜像里的版本。

# 备份与恢复

人工决策见 scripts/backup_db.sh 文件头。只导长期数据：device、friendship 与节日抽奖的 reward_campaign、reward_prize、reward_draw；message（30 天）与 chaoxing_pack（10 分钟）是短期数据，不导。新增长期保存的表要加进脚本里的表清单。

- 备份：scripts/backup_db.sh 在 mysql 容器里用容器自己的账号环境变量执行 mysqldump --single-transaction（一致性快照，不锁表、不停服务），gzip 后写进 compose 目录下的 backups（目录 700、文件 600），文件名带 UTC 时刻，只留最新 BACKUP_KEEP 份（默认 14）。用 root 的 crontab 每天跑一次，如 17 19 * * * /opt/superxd-relay/scripts/backup_db.sh >> /var/log/superxd-relay-backup.log 2>&1（服务器是 UTC，即北京时间 03:17），日志每天三行。
- 异地：只存本机盘只防误删与库损坏，防不了整盘丢失或整机被删。去处还没定；定了以后写一个上传脚本，用 BACKUP_UPLOAD_HOOK=脚本路径 传给备份脚本（以备份文件的绝对路径为参数调用，失败则备份脚本非零退出）。备份里有还没发出的红包口令与二维码内容，传出服务器前必须先加密。
- 恢复：
  1. docker compose stop relay（恢复期间不再有写入）。
  2. scripts/restore_db.sh backups/<文件>.sql.gz --yes：先核对压缩包完整、以 mysqldump 的结束标记收尾，再整表替换备份里的那几张（message 与 chaoxing_pack 不动）。
  3. 备份之后执行过的 upgrade_*.sql 要再执行一遍（备份里是当时的表结构）。
  4. docker compose start relay，等 healthy 后 curl /v1/health。
- 恢复的代价：备份之后才注册的设备、新加的好友关系与抽签记录会丢。客户端目前遇到 UNAUTHORIZED 不会自己重新注册，丢了设备记录的用户要关掉私信再开，而关闭私信先删服务端设备，也会因 UNAUTHORIZED 失败——这一处要客户端另行处理，恢复前先确认。
- 演练：用临时 MySQL（同一固定版本、服务名 mysql）加 COMPOSE_FILE、COMPOSE_PROJECT_NAME 环境变量指向它，造合成数据后备份、删表与删行、恢复，比对 CHECKSUM TABLE；坏的备份（截断、缺结束标记）与不带 --yes 一律被拒。不要拿共用的测试库演练。

# 探活

.github/workflows/relay-health.yml 每 30 分钟从 GitHub 请求一次 /v1/health，隔 30 秒共试 3 次都失败才让工作流失败，由 GitHub 发邮件（发给最后改过它 cron 的人，要在个人设置里开着 Actions 失败通知）。地址取 relay 环境的 RELAY_URL 机密，日志里只有退出码与 health 里的版本。它只发现服务整个挂了或网络不通；公开仓库 60 天没有提交时 GitHub 会停用定时工作流，要在 Actions 页手动启用。容器内的健康检查（Dockerfile 的 HEALTHCHECK 与 compose 的 healthcheck）只把状态标成 unhealthy，不会自动重启。
