# SuperXD

校园课表与成绩应用。

## Android 发布与占用核验

本地分发按设备架构构建，避免把三套原生库交给每个用户：

```sh
ORG_GRADLE_PROJECT_superxdSigningProperties=/安全的绝对路径/signing.properties \
  flutter build apk --release --flavor alpha --split-per-abi --split-debug-info=build/release_symbols \
  --dart-define=SUPERXD_RELAY=http://中转服务器地址:端口
```

SUPERXD_RELAY是私信中转服务地址，只在构建时传入、不写进代码；不传时私信显示“未配置”，其余功能不受影响。测试期可用IP加HTTP，换正式域名后改为https://域名重新构建即可，见server/README.md。

签名配置只从上述外部properties入口读取，包含storeFile、keyAlias、storePassword、keyPassword；storeFile可相对配置文件或为绝对路径。文件和密钥必须保存在仓库外并限制访问，禁止将真实密码写进命令行、日志、Git或Issue。release缺少有效配置直接失败，不回退debug签名。

常见 Android 真机选择arm64-v8a，较老32位设备选择armeabi-v7a，x86_64用于对应模拟器；构建产物在build/app/outputs/flutter-apk。所有架构使用pubspec的同一构建号，后续发布必须递增。AAB仅用于商店，本次私有Alpha不生成或上架。

`build/release_symbols` 中的符号须随版本离线保存，用于还原崩溃堆栈，不打进APK。`--analyze-size` 与 `--split-debug-info` 不能同次使用。

同架构体积分析（独立构建）：

```sh
ORG_GRADLE_PROJECT_superxdSigningProperties=/安全的绝对路径/signing.properties \
  flutter build apk --release --flavor alpha --target-platform android-arm64 --analyze-size
```

性能比较使用同设备、同构建模式、同数据与显示设置；真机 profile 才能作为发布性能验收，不能用多次热重启的 debug 进程内存与冷启动 release 对比。云雾、加载与图标动效保持原设计；字体完整字符覆盖和实际字重不以裁字、系统替代或假粗体压缩。当前字体保真候选未通过验证，原文件保留。

Alpha使用长期专用签名，包名com.superxd.superxd.alpha、显示SuperXD Alpha；与原开发包并装，不共享或迁移账号数据。后续Alpha覆盖升级要求同包名、同签名、递增构建号。密钥和密码由维护者离线备份；丢失密钥不能无损替换签名升级。

默认flutter run/build使用production flavor，保留原开发包名；只有显式--flavor alpha才构建Alpha包。请勿向同一测试设备安装debug签名的alphaDebug，以免与alphaRelease签名冲突。

发布前逐个使用apksigner verify --verbose --print-certs验签，并检查包名、版本号、ABI和debuggable=false；生成SHA256SUMS，发布后下载附件再校验。首次Alpha私有Pre-release仅上传release APK和校验文件，不上传签名配置、keystore、真实测试数据或release_symbols。

## 本地开发

CI使用Flutter 3.47.2 / Dart 3.13.2，依赖锁定在pubspec.lock。

```sh
git clone https://github.com/huverse/SuperXD.git
cd SuperXD
PUB_HOSTED_URL=https://pub.dev flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter run
```

当前工程提供Android宿主。GitHub仓库为私有，clone需要维护者授权；不要把访问token写入URL或项目文件。

私信中转服务在server目录（NestJS + MySQL + Redis），开发、测试与部署见server/README.md；客户端与真实中转联调用tool/verify_social.dart。

项目索引在根目录CLAUDE.md（分层、跨模块不变量、改动前检查清单、测试地图）与lib各模块的CLAUDE.md（文件职责、流程、库表与限额）；新增、删除或搬迁lib文件须同步登记，由test/project_structure_test.dart检查。

## 百宝箱媒体验证

当前只接入BugPK；自动/手动是可插拔编排能力，不表示已经集成第二家服务。解析历史默认开启（仅本机80条/30天，可在设置关闭），媒体直链只短时缓存；下载到Download/SuperXD，移除记录不删除导出文件。图集/实况按接口返回项处理，不合成系统Live Photo，不支持DRM或HLS合并。

新增来源实现lib/toolbox/short_video/parse_source.dart端口并在设备级组合根注册；设置服务域名、适配版本和授权版本，不复用教务Cookie。只在用户明确授权后用真实作品联调，离线测试使用合成数据。

tool/verify_toolbox.dart为手动Android原生下载验证入口，不进入正式main或CI。视频播放若使本机Android Emulator 37.1.11在libcuda.so的cuMemcpy2D_v2崩溃，可只对模拟器进程设置ANDROID_EMU_MEDIA_DECODER_CUDA=0；不修改应用或清除AVD数据，此环境规避不代表真机性能验收。

## 版本管理

main保持可验证状态，功能在短分支开发并通过PR合并。CI只做静态检查和离线测试，不访问真实教务、不自动发布。详见[贡献流程](CONTRIBUTING.md)和[变更记录](CHANGELOG.md)。

assets/fixtures仅包含合成数据；真实账户数据、截图、日志、密钥及构建产物不提交。第三方许可见assets/third_party_notices.txt与各字体许可。本项目未另行授予统一开源许可。
