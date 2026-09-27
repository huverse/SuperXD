# SuperXD

校园课表与成绩应用。

## Android 发布与占用核验

本地分发按设备架构构建，避免把三套原生库交给每个用户：

```sh
flutter build apk --release --split-per-abi --split-debug-info=build/release_symbols
```

常见 Android 真机使用 `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`，模拟器按设备 ABI 选择。上架使用 `flutter build appbundle`，本仓库不会自动上传。

`build/release_symbols` 中的符号须随版本离线保存，用于还原崩溃堆栈，不打进APK。`--analyze-size` 与 `--split-debug-info` 不能同次使用。

同架构体积分析（独立构建）：

```sh
flutter build apk --release --target-platform android-arm64 --analyze-size
```

性能比较使用同设备、同构建模式、同数据与显示设置；真机 profile 才能作为发布性能验收，不能用多次热重启的 debug 进程内存与冷启动 release 对比。云雾、加载与图标动效保持原设计；字体完整字符覆盖和实际字重不以裁字、系统替代或假粗体压缩。当前字体保真候选未通过验证，原文件保留。

发布签名尚沿用本地 debug key；外部分发前须由维护者配置正式签名。

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

## 百宝箱媒体验证

当前只接入BugPK；自动/手动是可插拔编排能力，不表示已经集成第二家服务。解析历史默认关闭，媒体直链只短时缓存；下载到Download/SuperXD，移除记录不删除导出文件。图集/实况按接口返回项处理，不合成系统Live Photo，不支持DRM或HLS合并。

新增来源实现lib/toolbox/short_video/parse_source.dart端口并在设备级组合根注册；设置服务域名、适配版本和授权版本，不复用教务Cookie。只在用户明确授权后用真实作品联调，离线测试使用合成数据。

tool/verify_toolbox.dart为手动Android原生下载验证入口，不进入正式main或CI。视频播放若使本机Android Emulator 37.1.11在libcuda.so的cuMemcpy2D_v2崩溃，可只对模拟器进程设置ANDROID_EMU_MEDIA_DECODER_CUDA=0；不修改应用或清除AVD数据，此环境规避不代表真机性能验收。

## 版本管理

main保持可验证状态，功能在短分支开发并通过PR合并。CI只做静态检查和离线测试，不访问真实教务、不自动发布。详见[贡献流程](CONTRIBUTING.md)和[变更记录](CHANGELOG.md)。

assets/fixtures仅包含合成数据；真实账户数据、截图、日志、密钥及构建产物不提交。第三方许可见assets/third_party_notices.txt与各字体许可。本项目未另行授予统一开源许可。
