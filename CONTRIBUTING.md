# 开发流程

- main保持可构建；开发使用feat/、fix/、chore/短生命周期分支。
- 通过PR合并，等待Flutter analyze and test与Relay server test检查成功，只用squash合并；不force push main。
- 提交使用feat:、fix:、test:、docs:、chore:等清晰前缀，一次提交聚焦一个变化。
- 运行flutter pub get --enforce-lockfile、flutter analyze、flutter test。只在明确更新依赖时修改pubspec.lock；本机若配置了pub镜像，命令前加PUB_HOSTED_URL=https://pub.dev，避免锁文件的来源被改写。
- 改动前按根目录CLAUDE.md的检查清单：读项目索引与涉及模块的CLAUDE.md，检索人工决策注释；改变文件、职责、流程、库表或限额时在同一提交更新索引。
- UI变更必须在真实应用中检查相关交互和中间帧，模拟器证据不代表真机性能。
- 夹具、截图和PR附件必须是合成数据；不提交真实课表、成绩、账号标识、鉴权数据、日志或本地数据库。tool/verify_edu.dart和verify_grades.dart仅在明确授权的本地环境手动运行，禁止加入CI。README截图用tool/readme_demo.dart的演示数据拍摄。
- 改动数据处理方式（新增收集、发送对象或保留期限）时，同步更新应用内隐私政策（lib/page/legal_page.dart）：改对应功能一节，新增 SDK、系统权限或上限时同时改附录一至三，并修改更新日期。有实质变化时把 legalRevision 加一、改写 legalChanges，已装用户升级后打开会看到一次更新提示。新增系统安全存储的命名空间要同时加进 android/app/src/main/res/xml 下的两份备份规则。

# 百宝箱媒体验证

当前只接入BugPK；自动/手动是可插拔编排能力，不表示已经集成第二家服务。新增来源实现lib/toolbox/short_video/parse_source.dart端口并在设备级组合根注册；设置服务域名、适配版本和授权版本，不复用教务Cookie。只在用户明确授权后用真实作品联调，离线测试使用合成数据。

tool/verify_toolbox.dart为手动Android原生下载验证入口，不进入正式main或CI。视频播放若使本机Android Emulator在libcuda.so崩溃，可只对模拟器进程设置ANDROID_EMU_MEDIA_DECODER_CUDA=0；这一环境规避不代表真机性能验收。

# 版本与发布

- pubspec.yaml的version是唯一版本号来源，格式为语义版本+递增构建号，所有架构共用同一构建号。变更先写入CHANGELOG.md的Unreleased。
- 发版由流水线.github/workflows/release.yml全自动完成：升版本PR合并到main即构建与发布，不再要网页批准；发版的关口是合并升版本PR本身，普通PR不发布APK（[人工决策]在工作流文件头）：
  1. 开升版本PR：pubspec.yaml的version改成新版本名、构建号加一；CHANGELOG.md的Unreleased改成「## <版本名> - <日期>」，最前面加「### 更新说明」，写几行面向用户的话（每条一行，合计不超过4000字），它就是应用内更新弹窗里的说明。test/release_changelog_test.dart检查最新版本节取得出更新说明。
  2. 合并到main后，流水线核对：还没有v<版本名>标签、构建号比上一版大、CHANGELOG有版本节和更新说明，都满足才构建；只改pubspec其他内容不会触发。
  3. 接着自动：构建三个架构的Alpha包；逐个核对签名证书（等于工作流里的RELEASE_CERT_SHA256、只有一个签名者）、包名、版本号、不可调试与架构；生成SHA256SUMS、Release正文（tool/release_body.md套CHANGELOG版本节）与版本清单alpha.json；打标签发GitHub Release并下载回来校验；经受限账号传中转（先包、最后清单，再删旧包）；在公网逐架构核对清单与断点下载。
  4. 某步失败在Actions里重跑失败的作业：已有的Release不再重建，中转上传可以重复执行。
- 替换已发的版本（发出后才发现问题）：版本名不变、构建号加一，合并升版本PR之前先删掉这个版本的Release与标签（gh release delete v<版本名> --cleanup-tag），流水线按新提交重发、覆盖中转上同名安装包；装着旧构建号的在应用内会收到更新。
- 试跑：在Actions里手动运行Release（默认勾选dry_run），只构建、核对、生成清单并试连中转，不发Release、不改中转。改了发版流程、签名或构建配置后先试跑。
- 机密在仓库Settings › Environments：release环境（只限受保护分支，不设审批人）放SIGNING_KEYSTORE与SIGNING_PROPERTIES（仓库外alpha.jks与signing.properties的base64）、AMAP_KEY、RELAY_URL；relay环境（只限受保护分支）放RELAY_URL、RELAY_SSH_TARGET、RELAY_SSH_KEY、RELAY_KNOWN_HOSTS（受限账号见server/README.md部署第6步）。
- Alpha包名com.superxd.superxd.alpha、显示SuperXD Alpha，与开发包并装、数据不共享。默认flutter run/build是production flavor（开发包名）；只有显式--flavor alpha才构建Alpha。不要向同一设备安装debug签名的alphaDebug。

本机构建（排查问题或流水线不可用时；按架构分包，符号离线保存）：

```sh
ORG_GRADLE_PROJECT_superxdSigningProperties=/仓库外的绝对路径/signing.properties \
  flutter build apk --release --flavor alpha --split-per-abi --split-debug-info=build/release_symbols \
  --dart-define=SUPERXD_RELAY=http://中转服务器地址:端口 --dart-define=SUPERXD_AMAP_KEY=<高德key>
```

- 签名配置只从上述外部properties读取，包含storeFile、keyAlias、storePassword、keyPassword；storeFile可相对配置文件。密钥文件和密码在仓库外限制访问并离线备份（流水线用的是release环境里的副本），禁止写进命令行、日志、Git或Issue。release缺少有效配置直接失败，不回退debug签名。丢失密钥就无法覆盖升级，只能换签名并让用户卸载重装（1.0.0-alpha.2即因此更换）；换签名时同步改工作流的RELEASE_CERT_SHA256与release环境的机密。
- 符号文件build/release_symbols用于还原崩溃堆栈，不打进APK、不上传Release；流水线把它存为Actions产物release-symbols（保留90天），发版后下载到仓库外离线保存。--analyze-size与--split-debug-info不能同次使用。
- 本机发版时照流水线的核对逐项手做：apksigner verify --print-certs验签，检查包名、版本号、ABI与debuggable=false；生成SHA256SUMS，发布后下载附件再校验；dart run tool/release_changelog.dart取更新说明与Release正文，dart run tool/release_manifest.dart生成alpha.json，先传安装包、最后传清单、再删旧包，用 curl <中转地址>/v1/app/releases/alpha?abi=arm64-v8a 核对。
- 应用内更新（从1.0.0-alpha.4起）：客户端只认与已装应用同签名、同包名、版本号一致的安装包，换签名的版本无法应用内更新。
- 强制更新：只有旧版已无法正常使用（服务端接口不兼容、严重问题）或维护者明确要求时，才在升版本PR里调高工作流的RELEASE_MIN_SUPPORTED（最低可用构建号），已装版本低于它的用户会看到关不掉的更新弹窗。这个值只升不降、平时不动，不低于它的版本之间的更新都可选。
- 性能比较使用同设备、同构建模式、同数据与显示设置；真机profile才能作为性能验收。字体保持完整字符覆盖和实际字重，不以裁字或假粗体压缩体积。

# 许可与第三方

- 本项目以GPL-3.0分发。贡献的代码同样以GPL-3.0授权。
- lib/theme/curve_geometry.dart不随项目以GPL再授权（见README许可一节），不要把其他代码并入该文件。
- 新增依赖、字体或改编代码时，确认许可与GPL-3.0兼容，并更新assets/third_party_notices.txt；pub依赖的许可由构建自动收集。

# 仓库检查

main受保护：必须通过Flutter analyze and test，且分支须先与main同步。需要新增协作者时由维护者在GitHub明确授权，不共享个人token。安全问题走GitHub私密漏洞报告，不公开提交Issue。
