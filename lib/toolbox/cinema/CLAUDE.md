# toolbox/cinema 电影院

定位：百宝箱里的在线影视（灰度测试，功能开关 toolbox.cinema 开着才出现）：多源搜索、选集、播放与云解析，规则写法借鉴 Kazumi（GPL-3.0，出处见 assets/third_party_notices.txt）。搜索、选集、解析与取流全在手机上直连第三方片源，自建中转只发签名的片源规则包，另替片名目录型的源（不给按片名搜的，如 wsy）查片名对应的编号（服务端 src/modules/cinema_catalog）；规则包不进公开仓库，维护者本机签名后上传（tool/cinema_rules.dart、tool/cinema_publish.sh）。四项用户选择与服务器负担的取舍见 cinema_service.dart 文件头的人工决策。

# 文件职责

- cinema_rule.dart：规则包的外部输入边界 decodeCinemaPackage（验签后的载荷字节 → CinemaPackage）：规则 CinemaRule 是 Kazumi 的 API 模式（请求模板 CinemaRequest、搜索 CinemaSearchConfig、选集 CinemaChapterConfig 的 delimited 与 nested 两种）加电影院的扩展（规则 id、海报年份备注路径）；云解析 CinemaParser（回复的业务码按字符串比，地址可按 CinemaCipher 的 AES-128-CBC 解密）。11-20 起片名目录型的源放在顶层 catalogRules（CinemaCatalogConfig：给中转抓片名用的 update 请求，带 @hours、@page，手机只核对写法；搜索请求用 @ids），解出来接在普通源后面、同一个列表；1.0.0-alpha.34 不认这个字段、照旧只用普通源。JSONPath 只认 Kazumi 限定的写法（validateCinemaJsonPath）；上限 cinemaRuleLimit（两种合计）、cinemaParserLimit、cinemaPackageMaxBytes，不合格整包不用。
- cinema_rule_engine.dart：规则引擎（移植 Kazumi 的 ApiRuleStrategy，纯计算）：prepareCinemaRequest 填 @变量（url 里按 URL 编码、表单按 form 编码），parseCinemaSearch、parseCinemaChapters（只留能直接播的媒体地址，空线路整条不要，相对地址按选集请求补全，集名缺省按序号起名），parseCinemaParserReply；回复不看 Content-Type 直接按 JSON 解。
- cinema_models.dart：搜到的一条 CinemaHit、聚合后的一部片 CinemaTitle（各源的海报按先后留着，取不到换下一家）、选集 CinemaRoad 与 CinemaEpisode、失败 CinemaFailure（paused 是连续失败暂停着的）、边搜边给的快照 CinemaSearchResult（pending 是还没回来的源数）、看过的 CinemaHistory；片名折叠 cinemaFold（去空白、全角折半角、小写，没有 NFKC 时只折这两类）与聚合键 cinemaTitleKey（折叠加四位年份）、媒体地址判定 cinemaMediaUrl。
- cinema_http.dart：对外请求封装（经共用内核 CampusHttp，模块 cinema）：默认桌面浏览器 UA、不带 Referer（规则写了才带）；接口 15 秒、2MB，云解析 30 秒，清单 25 秒、8MB；本机代理取清单时自己跟跳转（最多 5 跳，拿最终地址补相对路径）；不自动重试。
- cinema_playlist.dart：m3u8 改写（纯计算）：子清单与 AES 密钥回到本机代理，分片与初始化段换成绝对地址交给播放器直连；腾讯 CDN 域名前置的还原 cinemaUnwrapHost；规则开了 adBlocker 时按不连续分段去广告（同 Kazumi 的 M3u8AdFilter），去掉的段里换过的密钥照旧补给后面的正片。
- cinema_proxy.dart：手机上的本机代理 CinemaProxy：只监听 127.0.0.1 随机端口，路径带随机令牌；p 取清单并改写，k 取密钥（16 字节，按地址记最多 64 把）；分片的路径首段像域名时探一次原地址，取不到而换主机取得到才换。视频字节不经代理也不经服务器。
- cinema_cloud_parse.dart：云解析 CinemaCloudParse：输入本身是媒体直链时不发给任何人；结果只在内存留 3 分钟、最多 32 条，「重新解析」跳过缓存；decryptCinemaUrl 是 AES-128-CBC 加 PKCS7（key、iv 是原文字节）。上游对不支持的地址也回成功并给提示影片，照样显示标题并播放（沿用懒猫交接里用户的决定，[人工决策] 在文件内）。
- cinema_store.dart：本机库 cinema.db（单实例、回滚遗留事务）：上次验签通过的规则包、同意记录（按规则 id 与接口主机）、看过的记录（最多 cinemaHistoryLimit 条、cinemaHistoryLifetime 没再看的删掉）。
- cinema_catalog.dart：片名目录型的源 CinemaCatalog（[人工决策] 在文件头）：片名 POST 给中转（不进地址）拿回最多 catalogHitLimit 个编号（decodeCatalogIds 是外部输入边界），再把编号一次发给这个源取详情，按中转给的先后排；没配中转时报错、进暂不可用。手机上不下载、不存目录。
- cinema_service.dart：服务 CinemaService：规则包（本机缓存，两次拉取至少隔一小时，版本只升不降，minClient 高于本机构建号的不换，拉不到照旧用本机的）、同意、多源并行搜索（最多 6 路、每源 20 条，边搜边给快照，按片名加年份聚合、按第一次出现的先后排只往后加，失败的进 failures；片名目录型的源经 CinemaCatalog 问中转）、连续失败暂停（pauseAfter 次后暂停 pauseFor，只在内存，resume 立即恢复，[人工决策] 在常量上）、选集、交给播放器的地址（m3u8 经本机代理）；清除数据删整个 cinema 目录。四项用户选择与服务器负担的取舍在文件头 [人工决策]。
- cinema_page.dart：首页：找片（看过的、搜索结果（边搜边显示，写还在搜几个源）、暂不可用的源，有暂停着的给「重试暂停的源」）与解析两段；第一次搜、第一次用云解析前征得同意（片名目录型的源写明片名经开发者服务器查找、不保存）；中转写了时长券而当前账号没换时显示兑换卡（人工决策见 domain/pass.dart）。
- cinema_detail_page.dart：选集页：选片源、选线路、点一集播放，上次看到的那集标成选中、可接着看。
- cinema_player_page.dart：播放页（media_kit）：竖屏上面画面（高度跟片子的真实比例，竖片最多占屏高 cinemaPortraitMaxHeight）下面选集与换源（按集名在新源里找同一集）、重新载入（云解析的重新解析）、15 秒还在缓冲提示换源；每 10 秒、换集与离开时记看到哪（进度还没动时不记）；全屏在同一页里切（画面与控件经 GlobalKey 挪过去），横片转真横屏、退出回竖屏（[人工决策] 在清单的 MainActivity 与 ios/Runner/Info.plist）。
- cinema_player_controls.dart：播放器控件与手势 CinemaPlayerControls（[人工决策] 在文件头，借鉴 Kazumi 与主流平台）：单击显隐、双击暂停继续、长按倍速、左右滑调进度（松手才跳）、左半边上下滑亮度（只改本应用窗口，离开恢复）、右半边音量；上栏倍速与画面比例 CinemaFit，下栏播放、下一集、带缓冲段的进度、选集（全屏）、全屏；全屏可锁定；跳过片头、从头播放、播完倒数 cinemaAutoNext 连播下一集。不用 media_kit 自带的控件（它的转圈会叠在我们的加载动画上）。
- cinema_poster.dart：列表一行 CinemaPosterRow 与海报 CinemaPoster（经百宝箱的小网络图，只认公网 https，按先后取、取不到换下一张）；formatCinemaDuration。

# 关键规则

- 第三方：片名、播放页地址直接发给规则包里的站点与云解析，各在第一次使用前征得同意，新加的源或换了主机的要重新同意；只搜同意过的源。
- 播放：控件全部自己画（Video 用 NoVideoControls），加载动画只有一份；libmpv 的同步 FFI 调用跑在界面线程上，解码线程卡住会连带界面无响应；不要改用 mediacodec_embed 这类直出 Surface 的输出（11-19 模拟器上解码器等不到消费者，返回时卡死），用 media_kit 默认配置。
- 不自动重试（跨模块不变量 9）；超时与上限都在 cinema_http.dart。
- 规则包与时长券都不写进灰度配置：旧版本解析灰度配置是严格的，多一个字段整份拒收。
- 保留：看过的最多 50 条、180 天；云解析结果只在内存 3 分钟；规则包只留一份；手机不存片名目录（在中转上，保留见 server/README.md）；源的连续失败与暂停只在内存。
- 片名目录型的源：片名只发给中转（请求体里，中转不落库、不写日志），源只收到编号；隐私政策第六节写明（修订 12）。

# 测试

- cinema_test.dart：规则包校验（含 catalogRules）、规则引擎（搜索与苹果 CMS 选集的四条交接向量、相对地址）、聚合键、域名前置、清单改写与去广告、云解析（业务码数字与字符串、缓存与重新解析、解不开）、本机库的保留、服务（规则包缓存与只升不降、拉不到用本机的、搜索聚合与失败、边搜边给快照、连续失败暂停与重试、片名目录型的源问中转再只发编号给源、中转回复的外部输入边界、没配中转时进暂不可用、选集与播放地址、清除数据）、本机代理（令牌、改写、密钥只取一次、跳转、502）、灰度开关藏起入口。
- 时长券在 pass_test.dart（客户端）与 server/test/pass.e2e.test.ts；中转的片名目录在 server/test/cinema_catalog.e2e.test.ts。
- 播放器控件要真的 libmpv，只在设备上验（手势、全屏转向、亮度音量、连播）；全屏转向的守护在 shell_layout_test.dart。
- 真实片源只在本机手动验（探针脚本放 build/superxd_verify，不进仓库）；播放画面模拟器上是黑的（软件渲染），画面只认真机。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/toolbox/cinema
- 本目录的标记位于：电影院的四项选择与服务器负担（cinema_service.dart 文件头）、边搜边显示与连续失败暂停（cinema_service.dart 的 pauseAfter）、片名目录型的源（cinema_catalog.dart 文件头）、播放器重做（cinema_player_controls.dart 文件头）、云解析的提示影片照样播（cinema_cloud_parse.dart）。
