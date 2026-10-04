import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/glass_panel.dart';

// [人工决策-2026-09-28 01:15:35] 本轮仅私有Alpha内测，告知真实数据流和未验收边界；不冒充学校官方服务或稳定版承诺。
const _testingSections = [
  (
    title: 'Alpha 内测说明',
    body: 'SuperXD Alpha 仅供受邀测试者使用，不是学校官方客户端，也不是稳定版本。功能、缓存或第三方服务可能出现错误，请以学校系统的课表和成绩为准，不将本应用作为唯一记录。',
  ),
  (
    title: '安装与升级',
    body: 'Alpha 与开发版使用独立应用标识，数据互不共享。更新同一 Alpha 包时请保留原签名与数据；卸载或清除应用数据会删除应用私有记录，公共下载目录中的媒体文件不会自动删除。重要信息请自行妥善保存。',
  ),
  (
    title: '账号与内容使用',
    body: '仅使用本人或已获授权的教务账号；不要尝试绕过学校的验证码、权限或访问限制。百宝箱仅处理本人或已获授权的作品，接口公开不代表作品版权或再分发授权。',
  ),
  (
    title: '网络与服务边界',
    body: '当前教务系统使用 HTTP 明文连接，账号、验证码和会话在传输中可能被网络中间方读取，请只在可信网络使用。BugPK 与媒体服务器由第三方提供，支持范围、时效和可用性可能变化；遇到失败可取消或稍后重试。私信中转服务由维护者自建，测试期可能使用 IP 地址与 HTTP 明文连接：分享内容已端到端加密，但设备号、好友关系、消息大小与时间在传输中可被网络中间方看到。',
  ),
  (
    title: '本轮测试范围',
    body: '视频与图集的核心解析、下载和本地打开已进行样本验收，不保证所有平台和作品可用。实况和音频按维护者安排未完成本轮端到端验收；旧版 Android、iOS、真机性能及声音听感不属于本轮通过结论。',
  ),
  (
    title: '反馈与退出测试',
    body: '受邀测试者可在私有仓库 https://github.com/huverse/SuperXD/issues 反馈问题。请勿上传密码、Cookie、验证码、真实课表/成绩或未经脱敏截图；不愿继续测试可停止使用并按系统提供的方式清除 Alpha 数据。',
  ),
];

const _privacySections = [
  (
    title: '适用范围',
    body: '本说明适用于当前 SuperXD Alpha 内测包，说明应用实际处理的数据。Alpha 使用独立本地数据空间，不读取开发版的账号或数据库。当前未集成广告、用户行为统计或自动崩溃上报 SDK；操作系统、学校或第三方服务仍可能产生其自身日志。',
  ),
  (
    title: '教务账号与本地记录',
    body: '登录时，账号、密码、验证码等必要数据发送到学校教务服务。当前服务为 HTTP 明文，传输不具备 HTTPS 的机密性。会话、课表、成绩及编辑历史存于本机，账号之间分别隔离；课表历史按每学期最多100版保留。课表“导出到日历”时，该学期的课程名称、地点、教师和上课时间写成日历文件，交给你选择的日历应用（没有可导入的日历时改由你在系统分享中选择应用），之后由该应用保存和处理；本机缓存只保留最近一次导出的文件，下次导出时替换。桌面小组件把今天起7天的课程名称、时间和地点另存一份在应用私有存储，只在桌面显示、不联网，退出登录即清空。',
  ),
  (
    title: '记住账号',
    body: '只有你主动选择并确认“记住账号”且登录成功后，应用才保存用于自动登录的加密凭据。本地加密不等于传输加密。可在“我的”关闭记住账号，或退出登录清除保存凭据；退出不会自动删除课表和历史数据。',
  ),
  (
    title: '第三方解析和媒体',
    body: '百宝箱无需教务登录。目前生产解析来源为 api.bugpk.com，点击解析并同意后才提交作品链接，不附带教务凭据。预览或下载还会连接返回的媒体服务器，这些服务会看到网络请求及来源IP。没有获同意的解析来源不会收到作品链接。',
  ),
  (
    title: '好友与私信',
    body: '只有你在“消息 › 私信”中同意开启后才启用。开启时在本机生成私信身份密钥，私钥存于系统安全存储、不离开本机、不随系统备份迁移；中转服务只保存由公钥推出的设备号与公钥。昵称由你填写，仅当面出示二维码或扫码加好友时交给对方。分享的课表（课程、教师、地点、上课时间、开学日与作息）、界面配置与作品链接在本机加密后经中转服务转交，服务器只能看到密文、收发双方设备号、大小与时间。对方取走即从服务器删除，未取走的 30 天后删除；本机每位好友最多保留最近 200 条。好友收到后可自行保存或转述，请只分享愿意给对方的内容。删除好友会解除双方关系并删除本机会话；“关闭私信”会删除服务器上的设备、好友关系与待收消息，并清空本机私信数据。设备 400 天未使用时服务器自动删除。',
  ),
  (
    title: '历史、缓存与下载',
    body: '解析历史默认开启，仅在本机保存作品链接、标题、类型和解析来源，最多80条、最长30天；可在短视频解析设置中关闭（关闭只停止新增），也可逐条删除或清空。点开历史时若缓存已过期，会重新向解析来源提交该链接。解析结果采用最多20项、约2分钟的进程缓存，签名媒体直链不作为长期历史保存。下载记录有条数和30天保留限制，未完成临时任务按24小时清理策略处理。',
  ),
  (
    title: '权限与剪贴板',
    body: '只有点击粘贴才读取剪贴板，不在后台监控。通知权限用于下载状态和课前提醒；拒绝通知仍可使用普通下载路径。课前提醒只按本机课表在系统中定时，不联网；“闹钟和提醒”权限只用于让提醒准时，未允许时提醒可能晚几分钟。保存新媒体不要求读取整个相册或获取所有文件访问权限，旧系统可能让你通过系统界面选择保存位置。设置自定义背景时，通过系统照片选择器只读取你选中的那一张图片，复制保存在本机应用私有目录（只保留一张、不超过20MB），不会上传；更换图片或恢复默认云雾时删除。',
  ),
  (
    title: '删除与设备备份',
    body: '删除解析历史、下载记录或卸载工具资源不会删除已导出的媒体。媒体默认保存在公共 Download/SuperXD，请在系统文件管理器自行删除。清除 Alpha 应用数据会删除其私有数据库和设置。凭据及百宝箱任务等目录已排除系统备份，其他本地数据的备份/迁移仍由设备系统设置决定。',
  ),
  (
    title: '反馈与更新',
    body: '问题通过受邀可访问的私有仓库 Issue 反馈，请先移除真实身份、密码、会话、课表/成绩和媒体隐私信息。本说明随版本中的实际数据处理方式更新；未来新增第三方解析来源须单独取得相应同意。',
  ),
];

class LegalPage extends StatelessWidget {
  const LegalPage({super.key, required this.privacy});
  final bool privacy;

  @override
  Widget build(BuildContext context) {
    final sections = privacy ? _privacySections : _testingSections;
    final colors = CampusPalette.of(context);
    return CampusBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          children: [
            CampusTopBar(
              child: SizedBox(
                height: 56 * MediaQuery.textScalerOf(context).scale(14) / 14,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '返回',
                      onPressed: () => context.pop(),
                      icon: CampusIcon(
                        CampusIcons.back,
                        color: colors.onSurface,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        privacy ? '隐私政策' : '服务协议',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: SafeArea(
                top: false,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 800),
                    child: CampusScrollFade(child: ListView.builder(
                      padding: const EdgeInsets.all(20),
                      itemCount: sections.length,
                      itemBuilder: (context, index) => Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              sections[index].title,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              sections[index].body,
                              style: TextStyle(
                                fontSize: 16,
                                height: 1.6,
                                color: colors.onSurface,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
