# 开发流程

- main保持可构建；开发使用feat/、fix/、chore/短生命周期分支。
- 通过PR合并，等待Flutter analyze and test与Relay server test检查成功，只用squash合并；不force push main。
- 提交使用feat:、fix:、test:、docs:、chore:等清晰前缀，一次提交聚焦一个变化。
- 运行flutter pub get --enforce-lockfile、flutter analyze、flutter test。只在明确更新依赖时修改pubspec.lock；本机若配置了pub镜像，命令前加PUB_HOSTED_URL=https://pub.dev，避免锁文件的来源被改写。
- 改动前按根目录CLAUDE.md的检查清单：读项目索引与涉及模块的CLAUDE.md，检索人工决策注释；改变文件、职责、流程、库表或限额时在同一提交更新索引。
- UI变更必须在真实应用中检查相关交互和中间帧，模拟器证据不代表真机性能。
- 夹具、截图和PR附件必须是合成数据；不提交真实课表、成绩、账号标识、鉴权数据、日志或本地数据库。tool/verify_edu.dart和verify_grades.dart仅在明确授权的本地环境手动运行，禁止加入CI。README截图用tool/readme_demo.dart的演示数据拍摄。
- 改动数据处理方式（新增收集、发送对象或保留期限）时，同步更新应用内隐私政策（lib/page/legal_page.dart）并修改更新日期。

# 百宝箱媒体验证

当前只接入BugPK；自动/手动是可插拔编排能力，不表示已经集成第二家服务。新增来源实现lib/toolbox/short_video/parse_source.dart端口并在设备级组合根注册；设置服务域名、适配版本和授权版本，不复用教务Cookie。只在用户明确授权后用真实作品联调，离线测试使用合成数据。

tool/verify_toolbox.dart为手动Android原生下载验证入口，不进入正式main或CI。视频播放若使本机Android Emulator在libcuda.so崩溃，可只对模拟器进程设置ANDROID_EMU_MEDIA_DECODER_CUDA=0；这一环境规避不代表真机性能验收。

# 版本与发布

- pubspec.yaml的version是唯一版本号来源，格式为语义版本+递增构建号，所有架构共用同一构建号。变更先写入CHANGELOG.md的Unreleased。
- 完成验证后，由维护者明确批准发布，再更新版本、创建vX.Y.Z标签及Release。普通PR不自动发布APK。
- Alpha包名com.superxd.superxd.alpha、显示SuperXD Alpha，与开发包并装、数据不共享。默认flutter run/build是production flavor（开发包名）；只有显式--flavor alpha才构建Alpha。不要向同一设备安装debug签名的alphaDebug。

构建命令（按架构分包，符号离线保存）：

```sh
ORG_GRADLE_PROJECT_superxdSigningProperties=/仓库外的绝对路径/signing.properties \
  flutter build apk --release --flavor alpha --split-per-abi --split-debug-info=build/release_symbols \
  --dart-define=SUPERXD_RELAY=http://中转服务器地址:端口
```

- 签名配置只从上述外部properties读取，包含storeFile、keyAlias、storePassword、keyPassword；storeFile可相对配置文件。密钥文件和密码保存在仓库外、限制访问并离线备份，禁止写进命令行、日志、Git或Issue。release缺少有效配置直接失败，不回退debug签名。丢失密钥就无法覆盖升级，只能换签名并让用户卸载重装（1.0.0-alpha.2即因此更换）。
- build/release_symbols随版本离线保存，用于还原崩溃堆栈，不打进APK、不上传Release。--analyze-size与--split-debug-info不能同次使用。
- 发布前逐个用apksigner verify --verbose --print-certs验签，检查包名、版本号、ABI与debuggable=false；生成SHA256SUMS，发布后下载附件再校验。Release只上传APK与校验文件。
- 性能比较使用同设备、同构建模式、同数据与显示设置；真机profile才能作为性能验收。字体保持完整字符覆盖和实际字重，不以裁字或假粗体压缩体积。

# 许可与第三方

- 本项目以GPL-3.0分发。贡献的代码同样以GPL-3.0授权。
- lib/theme/curve_geometry.dart不随项目以GPL再授权（见README许可一节），不要把其他代码并入该文件。
- 新增依赖、字体或改编代码时，确认许可与GPL-3.0兼容，并更新assets/third_party_notices.txt；pub依赖的许可由构建自动收集。

# 仓库检查

main受保护：必须通过Flutter analyze and test，且分支须先与main同步。需要新增协作者时由维护者在GitHub明确授权，不共享个人token。安全问题走GitHub私密漏洞报告，不公开提交Issue。
