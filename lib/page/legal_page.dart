import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/glass_panel.dart';

// [人工决策-2026-10-05 01:28:53] 仓库公开、发行公开 Alpha 后，用户协议与隐私政策按公开测试重写（取代 2026-09-28 的私有内测说明）：开发者 Galaxyous 个人开发者、GPL-3.0 开源、反馈走 GitHub Issues；仍告知真实数据流与未验收边界，不冒充学校官方服务或稳定版承诺。
const legalUpdated = '2026年10月5日';

const _termsSections = [
  (
    title: '协议说明',
    body: '本协议是你与 SuperXD 开发者 Galaxyous（个人开发者，下称“开发者”）之间关于使用 SuperXD 的约定。安装或使用本应用，即表示你已阅读并同意本协议和《隐私政策》；不同意请停止使用。',
  ),
  (
    title: 'SuperXD 是什么',
    body: 'SuperXD 是开源、非官方的校园课表与成绩客户端，目前只对接山东现代学院的 Kingo 教务系统。它不是学校官方应用，与学校没有隶属或合作关系。当前为 Alpha 测试版，功能和数据可能出错，课表、成绩请以学校系统为准。',
  ),
  (
    title: '开源许可',
    body: '源代码以 GNU GPL v3.0 许可在 https://github.com/huverse/SuperXD 公开，你享有该许可赋予的使用、修改和再分发权利，本协议不限制这些权利。第三方组件按各自许可使用，详见“关于 › 开源许可”。',
  ),
  (
    title: '教务账号',
    body: '只使用本人或已获授权的教务账号，并妥善保管密码。不得借助本应用绕过学校的验证码、权限或访问限制，也不得修改应用去高频或批量访问教务系统。因违反学校规定产生的后果由使用者自行承担。',
  ),
  (
    title: '百宝箱与作品版权',
    body: '短视频解析依赖第三方服务，开发者无法保证其可用性和结果。请只解析、下载本人或已获授权的作品；作品版权归原作者，不得用于侵权传播或商业用途。',
  ),
  (
    title: '私信使用规范',
    body: '私信只用于在好友之间分享课表、界面配置和作品链接卡片。不得利用私信传播违法违规内容或骚扰他人。内容端到端加密，开发者无法查看；对异常注册或滥用请求，中转服务会限流，开发者也可能删除相关设备。',
  ),
  (
    title: '测试服务与变更',
    body: '测试期间功能和服务可能调整、中断或停止，包括私信中转服务；重要变化会在版本说明中告知。你的课表、成绩等数据主要保存在本机，卸载或清除应用数据会将其删除，重要信息请自行保存。',
  ),
  (
    title: '责任限制',
    body: '本应用按现状免费提供。因学校系统变化、第三方服务、网络环境或设备原因导致的数据错误、提醒延误或服务中断，在法律允许的范围内开发者不承担责任；法律另有规定的除外。',
  ),
  (
    title: '协议更新与终止',
    body: '本协议随版本更新，更新内容在应用内展示，继续使用即表示同意更新后的协议。你可以随时停止使用并卸载应用；在“消息 › 私信”中关闭私信，会同时删除服务器上的私信数据。本协议适用中华人民共和国法律。',
  ),
  (
    title: '反馈与联系',
    body: '问题与建议请提交至 https://github.com/huverse/SuperXD/issues 。Issue 公开可见，请勿附上密码、Cookie、验证码、学号、真实课表成绩或未打码的截图。',
  ),
];

const _privacySections = [
  (
    title: '概述',
    body: '本政策说明 SuperXD（含 Alpha 测试版）如何处理你的信息，由开发者 Galaxyous（个人开发者）负责。应用不含广告、行为统计或崩溃上报 SDK。你的教务账号、课表和成绩只在本机与学校教务系统之间传输，开发者收不到；开发者运营的唯一服务是私信中转。',
  ),
  (
    title: '教务账号、课表与成绩',
    body: '登录时，账号、密码和验证码直接发送给学校教务系统（当前为 HTTP 明文连接，传输中可能被网络中间方读取，请只在可信网络使用）。会话、课表、成绩和课表编辑历史只存于本机，不同账号分别隔离，课表历史每学期最多保留 100 版。业务数据库、账号索引和日志都不保存密码。',
  ),
  (
    title: '记住账号',
    body: '只有你在登录时主动勾选并确认“记住账号”且登录成功后，应用才会把用于自动登录的凭据加密保存在系统安全存储中。本地加密不等于传输加密。你可以在“我的 › 账号”中关闭，或退出登录，凭据会立即删除；课表和历史数据不受影响。',
  ),
  (
    title: '日历导出与桌面小组件',
    body: '使用“导出到日历”时，该学期的课程名称、地点、教师和上课时间会写成日历文件，交给你选择的日历应用或分享目标，之后由该应用处理；本机缓存只保留最近一次导出的文件。桌面小组件在应用私有存储中另存今天起 7 天的课程名称、时间和地点，只在桌面显示、不联网，退出登录即清空。',
  ),
  (
    title: '好友与私信',
    body: '只有你在“消息 › 私信”中同意开启后才启用。开启时在本机生成私信密钥，私钥存于系统安全存储，不离开本机，也不随系统备份迁移。中转服务器保存：由公钥推出的设备号、公钥、好友关系、待收取的密文及其大小和时间；注册时按 IP 地址计数限流（一小时后失效），运行日志只记录设备号和操作类型，按大小滚动覆盖。服务器看不到你分享的内容。昵称只在扫码加好友时交给对方。',
  ),
  (
    title: '私信内容与保存期限',
    body: '分享的课表（课程、教师、地点、上课时间、开学日与作息）、界面配置和作品链接在本机加密后经中转服务器转交。对方取走即从服务器删除，未取走的 30 天后删除；本机每位好友最多保留最近 200 条。好友收到后可以自行保存或转述，请只分享你愿意给对方的内容。删除好友会解除双方关系并删除本机会话；关闭私信会删除服务器上的设备、好友关系和待收消息，并清空本机私信数据；设备 400 天未使用时服务器自动删除。测试期中转服务可能使用 HTTP 明文连接：内容仍是加密的，但设备号、好友关系、消息大小和时间对网络中间方可见。',
  ),
  (
    title: '百宝箱与第三方解析',
    body: '百宝箱无需教务登录。目前的解析来源是第三方服务 api.bugpk.com：你首次使用并同意后，点击解析时才提交作品链接，不附带任何教务信息；未获同意的来源不会收到链接。预览或下载会连接解析结果中的媒体服务器，它们能看到你的网络请求和 IP 地址。这些第三方按各自的规则处理数据，开发者无法控制。',
  ),
  (
    title: '解析历史、缓存与下载',
    body: '解析历史默认开启，只在本机保存作品链接、标题、类型和解析来源，最多 80 条、30 天；可在短视频解析设置中关闭（只停止新增），也可逐条删除或清空。打开已过期的历史会重新向解析来源提交该链接。解析结果在内存中最多缓存 20 项、约 2 分钟。下载记录最多保留 100 项、30 天，超过 24 小时未完成的任务在启动时取消。',
  ),
  (
    title: '系统权限',
    body: '网络：访问教务系统、解析来源和私信中转。相机：只在扫码加好友时使用，识别在本机完成，不拍照、不上传。通知：显示下载状态和课前提醒。闹钟和提醒：只用于让课前提醒准时，未允许时提醒可能晚几分钟。照片选择器：设置背景或从相册识别二维码时，只读取你选中的那一张，背景图复制到应用私有目录（只保留一张、不超过 20MB），识别用的副本用完即删。剪贴板：只在你点击粘贴时读取。保存媒体不申请读取全部相册或所有文件的权限。',
  ),
  (
    title: '你的权利',
    body: '你可以随时查看、删除本机数据：退出登录、删除解析历史与下载记录、关闭记住账号，或在系统设置中清除应用数据。你可以撤回同意：关闭私信（服务器数据随之删除）、关闭解析历史、不再使用某个解析来源。已导出到公共 Download/SuperXD 的媒体不会随应用删除，请在文件管理器中自行处理。',
  ),
  (
    title: '设备备份',
    body: '记住账号的凭据、私信密钥和私信数据库、百宝箱任务等目录已排除系统备份与设备迁移；其他本地数据是否备份由你的系统设置决定。',
  ),
  (
    title: '未成年人',
    body: '本应用面向在校大学生。如果你未满 14 周岁，请在监护人同意和指导下使用。',
  ),
  (
    title: '政策更新与联系',
    body: '本政策随应用版本更新，新增数据处理（例如接入新的解析来源）会先在应用内单独征得你的同意。问题请提交至 https://github.com/huverse/SuperXD/issues ，Issue 公开可见，请勿附上任何个人信息。',
  ),
];

class LegalPage extends StatelessWidget {
  const LegalPage({super.key, required this.privacy});
  final bool privacy;

  @override
  Widget build(BuildContext context) {
    final sections = privacy ? _privacySections : _termsSections;
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
                        privacy ? '隐私政策' : '用户协议',
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
                      itemCount: sections.length + 1,
                      itemBuilder: (context, index) => index == 0 ? Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: Text('更新日期：$legalUpdated', style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
                      ) : Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              sections[index - 1].title,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              sections[index - 1].body,
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
