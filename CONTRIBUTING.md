# 开发流程

- main保持可构建；开发使用feat/、fix/、chore/短生命周期分支。
- 通过PR合并，等待Flutter analyze and test检查成功，推荐squash；不force push main。
- 提交使用feat:、fix:、test:、docs:、chore:等清晰前缀，一次提交聚焦一个变化。
- 运行flutter pub get --enforce-lockfile、flutter analyze、flutter test。只在明确更新依赖时修改pubspec.lock。
- UI变更必须在真实应用中检查相关交互和中间帧，模拟器证据不代表真机性能。
- 夹具必须是合成数据；不提交真实课表、成绩、账号标识、鉴权数据、截图、日志或本地数据库。tool/verify_edu.dart和verify_grades.dart仅在明确授权的本地环境手动运行，禁止加入CI。

# 版本与发布

- pubspec.yaml的version是唯一版本号来源，格式为语义版本+递增构建号。变更先写入CHANGELOG.md的Unreleased。
- 完成验证后，由维护者明确批准发布，再更新版本、创建vX.Y.Z标签及Release。普通PR不自动发布APK。
- 发布前配置正式签名并安全保管；签名文件、密码和崩溃符号不进入Git。
- 原字体与第三方声明保持完整；项目私有不等于可忽略第三方许可。本项目未提供统一开源授权。

# 仓库检查

GitHub分支保护取决于仓库计划与权限；不能启用时也遵守PR和CI流程。需要新增协作者时由维护者在GitHub明确授权，不共享个人token。
