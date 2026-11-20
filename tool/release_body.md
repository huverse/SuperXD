# SuperXD {{version}} · 公开测试版

SuperXD 是开源、非官方的校园课表与成绩客户端，目前只对接山东现代学院的 Kingo 教务系统；另附免教务登录的百宝箱（驿站取件、学习通签到、视频解析）。功能和数据可能出错，课表与成绩请以学校系统为准。

## 下载哪个

- 大多数手机：`SuperXD-{{version}}-arm64-v8a.apk`
- 较老的 32 位手机：`armeabi-v7a`；`x86_64` 用于模拟器
- 需要 Android 11 及以上。安装前可用 `SHA256SUMS` 校验：`sha256sum -c SHA256SUMS`
- 想确认安装包确实出自本仓库的发版流水线：装好 [GitHub CLI](https://cli.github.com/) 后对下载的文件（iPhone 包在重新签名之前）运行 `gh attestation verify <文件名> -R huverse/SuperXD`，显示 Verification succeeded 即通过。
- iPhone：`SuperXD-{{version}}-ios-unsigned.ipa`，需要 iOS 16 及以上。没有上架 App Store，包未签名，要用你自己的证书签名后安装（例如全能签）；有新版本时应用会提示，去这里下载后重新签名安装。证书只绑一个固定应用 ID 时签不了小组件与实时活动的扩展，在签名工具里去掉插件再装即可。
- 签名与 1.0.0-alpha.2 起各版相同，可直接覆盖升级，本机数据保留；已装 1.0.0-alpha.4 及以上的也可以在「我的 › 关于 › 检查更新」应用内升级。
- 证书 SHA-256：`{{certificate}}`

## 本版变更

{{changelog}}

完整变更见 [CHANGELOG](https://github.com/huverse/SuperXD/blob/main/CHANGELOG.md)。

## 须知

- 不含广告，不接入任何第三方统计或崩溃上报 SDK；开发者只收每天一份的匿名健康回报（有没有致命错误、启动快慢与卡顿的档位，不带账号与设备编号，选「仅本机」时不发）；扫码在本机识别，不联网。
- 学校教务系统只提供 HTTP 明文连接，请只在可信网络登录。
- 私信、代签、检查更新等用到的开发者中转使用 HTTPS 加密连接；私信与代签凭据包另在本机加密，服务器看不到内容，安装包另核对签名。
- 学习通账号密码只保存在本机系统安全存储，签到数据直接提交给超星学习通。请只登录本人账号或已获本人授权的账号，代签前请确认符合所在学校与课程的要求。
- 快递用拼多多账号查驿站待取件，走的是拼多多的非公开接口，随时可能失效；登录会话只保存在本机系统安全存储。拼多多同一账号不能多台设备同时在线，在这里登录会让其他设备上的拼多多下线。
- 视频解析依赖第三方服务 BugPK，请只处理本人或已获授权的作品。
- 电影院（灰度测试，部分用户可见）：片源与画面来自第三方站点，版权归原权利人；搜索、选集与播放都在手机上直连片源，不支持按片名搜索的片源站，片名经开发者中转查找编号（不保存、不记录）。

问题反馈：[Issues](https://github.com/huverse/SuperXD/issues)（公开可见，请勿附密码、学号、手机号、真实课表成绩）。安全问题请用[私密漏洞报告](https://github.com/huverse/SuperXD/security/advisories/new)。个人信息相关请求请私下联系：QQ 209320162，邮箱 vbhcchhvvvhh@gmail.com。

应用图标为测试期临时图标，画面版权归原权利人所有（©VisualArt's/Key/Charlotte Project），不随本项目 GPL 授权，正式版前替换。

源码提交：`{{commit}}`，以 GPL-3.0 开源。
