# chaoxing 学习通签到

定位：百宝箱里的一个工具，对接超星学习通的课堂签到。账号是学习通账号，与教务账号无关；协议按参考项目 ChaoxingSignFaker 的接口行为用 Dart 独立重写，不复制它的代码，也不依赖它的任何域名与服务。框架契约（注册表、服务、清除数据、下载）见上一级 lib/toolbox/CLAUDE.md。

# 文件职责

- 协议与数据：
  - chaoxing_models.dart：活动、课程、详情、账号模型与错误码 ChaoxingFailure；otherId 到 ChaoxingSignType 的映射（0 是「普通签到」，详情 ifphoto=1 才要照片）。上游没给开始时间时为空，如实当未知、不拿现在顶替，列表统一按 chaoxingNewestFirst 排。
  - chaoxing_crypto.dart：学习通固定的传输加密（AES-128-CBC）、MD5/SHA-256、设备公钥（设备信息 RSA 分块加密与 clientId 还原）与设备码的 AES-ECB。
  - chaoxing_device.dart：设备信息端口 ChaoxingDeviceProbe，按学习通客户端的字段与顺序组设备信息并 RSA 加密；按 OAID 算设备码，取不到返回空，由调用方退回固定随机码。
  - chaoxing_device_channel.dart：端口的原生实现（通道 superxd/chaoxing_device，见 ChaoxingDevice.kt，两个调用各有 3 秒兜底超时），由 toolbox_runtime.dart 注入。单独成文件是为了让协议链路不依赖 Flutter，tool/verify_chaoxing.dart 才能用纯 Dart 跑。
  - chaoxing_http.dart：请求封装与 Cookie 会话 ChaoxingCookieJar；模拟的客户端 ChaoxingClientProfile（学习通、学在西电、自定义 UA 与包名），UA 随它走。默认超时 15 秒（登录与用户信息 30 秒，见 chaoxing_client.dart 的人工决策）、响应上限 1MB、日志只记路径。
  - chaoxing_client.dart：登录、用户信息、重登与设备码。带得上设备信息就 POST（clientId 靠它下发），否则 GET；解析学校单位，登录后把会话 fid 改回所选单位。
  - chaoxing_activity.dart：课程列表（只认带 cataName 的频道）、活动列表与详情、按班级号查班级名（gas/clazz）、签到前的班级检查。
  - chaoxing_signer.dart：preSign（302 或「校验失败」即不在班级；403 按会话过期报，由 accounts.run 重登一次再重发）后紧跟 analysis → analysis2；各签到类型的提交参数逐项照学习通客户端（绕过模式同端点不带 signCode，[人工决策] 见 ChaoxingSignSubmission）；success2 按失败处理，迟到按截止时间判断。
  - chaoxing_batch.dart：多人连签 ChaoxingBatchSigning：按勾选顺序逐个签、相邻间隔 200 毫秒；选了「仍然签到」的人跳过检查；位置刚出界时收紧偏移再试；连续扫码一人失败就停队，但已签过、不在班级、登录过期只跳过这个人。
  - chaoxing_lessons.dart：学习通课表（kb.chaoxing.com）的解析与推断：当前节次前后 30 分钟内的课按课名相似度对上课程，找 20 分钟内刚发起的进行中签到（不知道开始时间的不算）。周次与日界按校园时区。
  - chaoxing_location.dart：坐标模型、坐标系转换（提交口径 BD-09）、随机偏移与位置负载。
  - chaoxing_photo.dart：拍照签到：上传前随机裁剪、旋转再裁齐（同一张照片反复用会被教师端比对出来），再传云盘拿 objectId。
  - chaoxing_qrcode.dart：课堂签到二维码的解析（SIGNIN: 内嵌串与带 enc 的链接）与过期查询。
  - chaoxing_captcha.dart：滑块验证码：取配置与底图、按 280 宽的坐标空间提交拖动位置、换一次性 validate（按签到对象各自的会话取）。
  - chaoxing_face.dart：人脸识别签到：用设备公钥从 clientId 还原设备信息、算 signToken 换一次性 faceEnc；也取学习通里存着的人脸照片 objectId 与原图地址。
  - chaoxing_im.dart：群聊签到走环信：DES 解出登录下发的环信密码换令牌、列群、拉漫游消息，用极简 protobuf 取签到附件；群按名字合并、置顶在前，只拉给定几个群的漫游。
  - chaoxing_credential_pack.dart：代签凭据包（手机号、密文密码、昵称、对方设备码、最多 5 张人脸照片 objectId）的编解码与一次性密钥封装（AES-256-GCM），以及二维码取件票（SXDC1:）。第 2 版加了人脸照片，第 1 版照样能解；包来自别人的二维码，一律按外部输入逐项校验。
  - chaoxing_pack_client.dart：代签凭据包的自建中转客户端：投递换取件号与作废口令、凭号取件（取走即删）、凭口令作废（老版本中转不给口令时跳过）。没配中转时代签入口不显示；chaoxingTicketLifetime（10 分钟）与中转一致。
- 本机数据与服务：
  - chaoxing_service.dart：学习通的服务 ChaoxingService（实现 ToolboxService）：打开、关闭与清除库、安全存储、设备通道与代签中转客户端。清除数据删掉安全存储 superxd_chaoxing 命名空间的全部凭据与 chaoxing.db，不动学习通云盘与已导出的文件。serviceId（chaoxing）就是工具 id，也是同意记录的键。
  - chaoxing_store.dart：chaoxing.db：账号索引（学校单位、设备码来源、备注名与排序、登录已失效标记）、收藏位置、按班级记住的签到位置、人脸照片索引、设置、置顶课程与群、账号标签、「这附近不再问」的地点与课表缓存。打开时按上限裁剪，删账号时连带清掉它的置顶、课表缓存与人脸照片索引；表结构只在 onUpgrade 按版本迁移；destroy 删库（清除数据用）。
  - chaoxing_vault.dart：密码与 Cookie 的存放，Secure 版用系统安全存储（命名空间 superxd_chaoxing，deleteAll 只清这个命名空间），测试用内存版。
  - chaoxing_accounts.dart：账号闭环：登录、恢复会话、补用户信息、切换学校单位、修复（重输密码）、删除、主账号与模拟客户端。
    - 会话过期自动重登一次并重放该次请求，重登被学习通拒绝时记「登录已失效」（[人工决策] 在 run）；主账号排第一（[人工决策] 在 list）。
    - 重新登录、修复与再导入保留备注名与排序；标签校验 saveTag；本人设备码优先用 OAID 算的，取不到沿用原码，新账号才生成固定随机码。
- 状态与流程：
  - chaoxing_controller.dart：页面状态：打开进主账号；账号切换按代次丢弃切换前的异步结果；登录与切换账号在会话开好就返回，列表在后台加载，加载完（成败都算）再后台刷新用户信息（人工决策在 _loadThenRefreshAccount）；登录失败返回原因交给表单显示，不写首页的 error；刷新课程与活动（最多并发三个课程请求，进行中与往期按 status 分；刷新不占账号忙，有一轮在拉就等它，只认最新一轮的结果）；改学校单位或客户端先存好就返回，再清空列表重拉（[人工决策] 在 _reloadActivities）；课表推断（有课时每 5 秒重查这节课，最多 2 分钟）；扫码打开签到；收藏位置与「这附近不再问」（500 米内有就不问）。人脸照片与代签码交给两个子控制器（构造注入，不反向依赖本类）。
  - chaoxing_face_controller.dart：人脸照片子控制器：列表、上传（可只上传给这次用）、预览缓存（总字节封顶 20MB）、保存到本机、学习通默认照片的读取与重处理。
  - chaoxing_delegate_controller.dart：代签码子控制器：出示（封包投递换取件票与作废口令）与取件导入（解封后用对方设备码登录确认，按代签账号存入）；代签码只带真实设备码（[人工决策] 在文件内）。
  - chaoxing_sign_flow.dart：一个人的完整签到流程 ChaoxingSignFlow（签到前检查、拍照上传、人脸、提交，验证码、换码与位置收紧重试）；会话与存储经 ChaoxingSignContext 注入。签到输入与回调类型也定义在这里。
  - chaoxing_qr_feed.dart：连续扫码时的最新二维码 ChaoxingQrFeed：要新码时有更新的就直接给，没有就等下一次扫到，取景页关掉以「已取消」结束。
- 界面：
  - chaoxing_page.dart：首页与登录表单（先取同意再登录；失败原因在表单里原地显示，「登录其他账号」的弹层等登录结果、成功才关）：首页分「可能正在签到」与「进行中的签到」两组，底下是往期、群聊签到、按课程三个入口（排列见文件内人工决策）；账号操作在⋯菜单；顶栏「扫签到二维码」直接打开那场签到（课程列表里没有也能签）；刷新只有下拉一个入口，同一时刻只转一个加载（人工决策在文件内）。
  - chaoxing_sign_sheet.dart：签到弹层：
    - 先取详情再按类型要输入（详情读不到时原地给重试，只重读详情）；签到码与手势可选校验方式；多个账号时可多选签到对象，每人一行原地显示状态，点某一行的重试或强制签到会先把这个人勾上。
    - 打开即检查，勾选的人全被拦时按原因弹窗：「仍然签到」放行并强制这个人、只关弹窗，「为其他账号签到」把没签的勾上、留在页面（[人工决策] 在文件内）。
    - 二维码签到连续扫码；位置默认与签完问收藏见人工决策；开签前现拍的人脸只给这次用，签好再问存不存。
  - chaoxing_sign_location.dart：签到弹层里的位置选择（嵌着的地图、位置名称、收藏的选择标签、手动输入与管理收藏）；地图用不了时直接摊开经纬度并写明原因；状态归签到弹层。
  - chaoxing_map_page.dart：高德地图选点：嵌在签到弹层里的 ChaoxingInlineMap 与全屏页 ChaoxingMapPage（带着弹层已选的位置打开即选中；favorite 模式给管理收藏添加用，不预选）。范围圈按内容缓存，定位回报只在拿来选点时记日志。key 走构建参数 SUPERXD_AMAP_KEY，不写进源码；key 没配或不在 arm 设备上时不出地图入口。地图按 GCJ-02 画；默认选中顺序、不画精度圈、系统定位没开的提示（「去打开」经原生 LocationSettings.kt 跳系统定位设置）与平面卫星切换见文件内人工决策。
  - chaoxing_code_cells.dart：签到码格子 ChaoxingCodeCells：真正的输入框（EditableText，自己不接点按）藏在格子底下，点格子或缝隙都经 requestKeyboard 叫键盘（键盘被收起后输入框仍聚焦，只 requestFocus 不会再弹）；输错标红保留到重新输入（[人工决策] 在文件头）。
  - chaoxing_gesture_field.dart：手势签到的 3×3 图案输入：用原始指针事件，不走手势竞技场（弹层的拖动关闭抢不走）；画错的图案标红留到下一次按下（[人工决策] 在文件头）。
  - chaoxing_captcha_dialog.dart：滑块验证弹窗，底图上拖缺口块，不通过自动换一张。
  - chaoxing_image_pick.dart：人脸照片取图（相册或拍摄，进 3:4 裁剪页）、现场拍摄与相册一次选多张；取图用注入的 ToolboxImagePick，留下的文件读成字节后即删（人脸属于生物特征，不在缓存留存）。
  - chaoxing_face_sheet.dart：人脸照片弹层：预览、用过几次、⋯里保存到本机与删除；「用学习通里存的那张」先重处理再入列表（[人工决策] 在文件内）。
  - chaoxing_account_sheet.dart：多账号管理弹层：主账号置顶不可拖，其余合成一个列表拖动排序；⋯里改备注名、设置标签、设为主账号与删除；登录已失效的行点警示图标重输密码修复；说明行只标例外（[人工决策] 见 chaoxing_store.dart 的 ownerLabel）。
  - chaoxing_tag_sheet.dart：账号标签的显示、管理与设置；颜色名与主题的 tagColors 一一对应（[人工决策] 在文件头）。
  - chaoxing_location_sheet.dart：收藏位置的管理弹层：地图能用时可在全屏地图上添加（起名必填，满 50 个不能再加，[人工决策] 在文件头），改名与删除。
  - chaoxing_share_page.dart：出示代签码页：二维码与倒计时（从发出投递时起算，只会比中转早到点）；重新生成、改附带照片或离开本页时作废上一张。
  - chaoxing_settings_sheet.dart：签到设置弹层（学校单位、模拟的客户端；点了就勾上，存的时候两组都不禁用，也不等列表）与修复账号时重输密码的对话框。
  - chaoxing_sign_notices.dart：签到弹层里的时间提示与签退提示；往期活动照样能签、提示可能记为迟到（[人工决策] 在文件内）。
  - chaoxing_activity_card.dart：各页共用的活动卡片、签到入口 ChaoxingSignLauncher、一组签到的列表页 ChaoxingActivitiesPage 与二级页刷新按钮；整页读取失败用 theme 的 CampusLoadError。
  - chaoxing_group_page.dart：群聊签到：先列群（一次请求、最多 200 个，可搜、可置顶、同名合并），点进一项才拉那几个群的消息（[人工决策] 在文件头）。
  - chaoxing_history_page.dart：往期签到页（status 不为 1 的活动），复用主列表那一次拉取，不额外请求；列表没读到时显示加载或原因与重试，不写「还没有」。
  - chaoxing_course_page.dart：按课程查看：可搜课名、老师与学校，可置顶，同名课程合并；课程没读到时同上。

# 关键规则

- 学习通改版时只动 chaoxing_activity.dart 与 chaoxing_signer.dart：活动列表、preSign 与提交结果的解析都集中在这两处。
- 签到流程与参数逐项对齐参考项目（2026-10-07 二次对照）：用户信息 POST 设备信息、preSign 用列表级 ext 并紧跟 analysis → analysis2、success2 按失败、迟到按截止时间、二维码坐标固定 -1、人脸只在位置与二维码签到上带、签到前查班级。参考项目里关掉的「签到习惯推荐」不做。
- 凭据：不碰教务凭据与 cookie；学习通密码与 cookie 只进系统安全存储，业务库只存账号索引；本机不存签到记录与群消息。
- 扫码页在 page 层，百宝箱用组合根注入的 ToolboxQrScan（单次）与 ToolboxQrWatch（连续）取二维码原文，不依赖 page。
- 设备信息与 OAID 只在学习通签到时取，加密后只发给学习通，不在本机另存。OAID 库自带的电话状态、存储、写设置与广告 ID 权限在清单里移除；它带入的华为、荣耀广告标识 SDK 在隐私政策「学习通签到用到的第三方 SDK」单列，增删这类 SDK 时同步改隐私政策。
- 依赖仓库按组限定（android/build.gradle.kts 的 thirdPartyRepositoryGroups）：JitPack 只给 OAID 库与 uCrop，华为、荣耀仓库只给各自的组；新增走这几个仓库的依赖先登记它的组。
- 位置：提交口径 BD-09，WGS-84、GCJ-02 先在 chaoxing_location.dart 换算，再按小范围随机偏移（超范围时收紧到 0.00001 重试一次）；手输坐标按高德 GCJ-02；坐标系尚未用真账号校准。定位只在打开位置签到时申请（仅使用期间、不后台定位）；隐私政策有「地图选点」一节，学习通同意说明为第 4 版。
- 代签：
  - 凭据包用一次性随机密钥加密，密钥只在二维码里、不进服务器；密文经自建中转暂存，取件号一次性、10 分钟过期、取走即删；出示方换码或离开出示页即作废上一张（[人工决策] 见服务端 chaoxing_pack.service.ts）。
  - 投递、取件与作废各 15 秒超时、密文上限 2KB，除时钟偏差校正后的一次重发外不重试。
  - 导入的账号按他人账号对待（is_other_user），带对方的设备码；本机库里已有本人账号时拒绝导入自己的码；附带人脸照片要出示方勾选，默认不带。
- 人脸：照片存在学习通云盘，本机只记 objectId 与使用情况；签到时选了就用选的，否则随机挑一张（没通过过的先避开）；一张都没有时开签前补给（学习通里有默认照片先问重处理，否则现拍）。clientId 与环信密码只在用户信息接口下发，环信密码不落库；缺 clientId 时人脸提交不带设备签名。经原生通道取真机设备信息换 clientId 的路径还没验。
- 群聊：环信令牌、群列表与漫游消息每次现拉；列群不拉消息，点进一项才拉那几个群（工作量只随这次看的群增长）。
- 上限（常量在 chaoxing_store.dart，打开库时裁剪）：账号 21 个（自己登录的与代签的合计）、收藏位置 50、每人人脸照片 5、每个账号置顶课程 100、置顶的群 200、账号标签 20（名字 12 个字以内）、按班级记住的签到位置 200 个班、「这附近不再问」的地点 50、学习通课表缓存每个账号一行且 7 天过期。
- 地图要 arm 原生库：真机，或带 ARM 转译的 x86_64 模拟器装 arm64 包时加 adb install --abi arm64-v8a；release 的混淆与清单要求见根 CLAUDE.md「已知约束」。

# 测试

- chaoxing_protocol_test.dart：协议、设备信息与设备码、学校单位、课表推断与坐标转换、人脸公钥与签名。
- chaoxing_store_test.dart：本机库、上限与升级。chaoxing_batch_test.dart：多人连签的顺序、间隔、停止与强制。
- chaoxing_map_test.dart：嵌着的地图（系统定位没开、默认选点跟着变准、精度圈不画）。
- chaoxing_ui_test.dart：界面流程（登录、各类签到、多人连签、代签导入、群聊、标签、人脸照片、签完问收藏），用 chaoxing_fake_server.dart 与 chaoxing_fake_hub.dart。
- chaoxing_pack_test.dart、chaoxing_delegate_test.dart：凭据包编解码，两台设备之间的出示与导入（chaoxing_fake_hub.dart 是内存中转）。
- chaoxing_regression_test.dart：审查整改与真机反馈的回归。chaoxing_im_test.dart：DES、protobuf 附件解析与环信链路。
- 手动入口（只在授权的测试账号上运行，运行方式见文件头）：tool/verify_chaoxing.dart（真实学习通，输出脱敏）、tool/verify_chaoxing_map.dart（要 SUPERXD_AMAP_KEY）、tool/verify_chaoxing_pack.dart（经真实中转往返，只用合成凭据）。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/toolbox/chaoxing
- 标记位于：签到码与手势输错的反馈（chaoxing_code_cells.dart、chaoxing_gesture_field.dart）、绕过模式（chaoxing_signer.dart）、往期提示（chaoxing_sign_notices.dart）、预检弹窗与签完问收藏（chaoxing_sign_sheet.dart）、地图默认选点与定位提示（chaoxing_map_page.dart）、收藏管理（chaoxing_location_sheet.dart）、账号说明只标例外（chaoxing_store.dart）、主账号与登录已失效（chaoxing_accounts.dart）、账号管理（chaoxing_account_sheet.dart）、标签（chaoxing_tag_sheet.dart）、群聊先列群（chaoxing_group_page.dart）、人脸照片先重处理（chaoxing_face_sheet.dart）、代签码只带真实设备码（chaoxing_delegate_controller.dart）、首页入口排列、刷新只留下拉与加载只显示一处（chaoxing_page.dart）、超时（chaoxing_client.dart）、刷新不挡活动列表、按 status 分进行中和往期、改单位或客户端清空重拉（chaoxing_controller.dart）、活动名与类型名相同只显示一个（chaoxing_models.dart）。
