import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/cinema/cinema_cloud_parse.dart';
import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_page.dart';
import 'package:superxd/toolbox/cinema/cinema_player_page.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';
import 'package:superxd/toolbox/cinema/cinema_service.dart';
import 'package:superxd/toolbox/toolbox_url.dart';

// 电影院的「解析」一段（登记在 toolbox_catalog.dart 的电影院 children，id cinema.parse，在功能开关 cinemaParseFlag 后面，
// 人工决策见 domain/feature_flags.dart）：视频网站播放页地址 → 云解析 → 播放；第一次解析前征得同意（地址会发给第三方解析服务）。
class CinemaParseSection extends StatefulWidget {
  const CinemaParseSection({super.key});
  static const sectionId = 'cinema.parse';
  @override
  State<CinemaParseSection> createState() => _CinemaParseSectionState();
}

class _CinemaParseSectionState extends State<CinemaParseSection> {
  late final CinemaService _service = CinemaScope.of(context).service;
  final _link = TextEditingController();
  var _parsing = false;
  String? _message;

  // 解析中报给电影院首页（忙着时不能切到别的段）。
  void _setParsing(bool parsing) {
    setState(() => _parsing = parsing);
    CinemaScope.of(context).busy(CinemaParseSection.sectionId, parsing);
  }

  Future<void> _parse() async {
    final package = _service.package;
    final parser = package == null || package.parsers.isEmpty ? null : package.parsers.first;
    final Uri target;
    try {
      target = toolboxPublicUrl(_link.text.trim());
    } on Object {
      setState(() => _message = '输入视频页面的 http(s) 地址');
      return;
    }
    if (parser == null && !cinemaMediaUrl(target.toString())) {
      setState(() => _message = '现在没有可用的解析服务');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _message = null);
    _setParsing(true);
    try {
      if (parser != null && !cinemaMediaUrl(target.toString()) && !await _service.parserConsented(parser)) {
        if (!mounted) return;
        final agreed = await showCampusConfirm(
          context,
          title: '使用云解析',
          message: '播放页地址会发给${parser.name}（${parser.host}），画面来自第三方，版权归原权利人。',
          action: '同意并解析',
        );
        if (!agreed) return;
        await _service.grantParser(parser);
      }
      final parsed = parser == null ? CinemaParsed(title: target.pathSegments.lastOrNull ?? '直链', type: 'direct', url: target.toString(), direct: true) : await _service.cloud.parse(parser, target.toString());
      if (!mounted) return;
      await Navigator.push<void>(context, CampusPageRoute(builder: (_) => CinemaPlayerPage.parsed(service: _service, parser: parser, target: target.toString(), parsed: parsed)));
    } on CinemaParseException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } on CinemaHttpException catch (error) {
      if (mounted) setState(() => _message = '解析服务${error.message}');
    } on CinemaRuleException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } catch (error, stack) {
      campusLog('[Cinema] action=parse errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _message = '解析没完成，稍后再试');
    } finally {
      if (mounted) _setParsing(false);
    }
  }

  Future<void> _paste() async {
    try {
      final value = await Clipboard.getData(Clipboard.kTextPlain);
      final text = value?.text?.trim();
      if (text != null && text.isNotEmpty && mounted) {
        _link.text = text;
        setState(() => _message = null);
      }
    } catch (error, stack) {
      campusLog('[Cinema] action=paste errorType=${error.runtimeType}\n$stack');
    }
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    sliver: SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CampusSurface(
            padding: EdgeInsets.fromLTRB(16, campusFieldGap(context), 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _link,
                  enabled: !_parsing,
                  minLines: 1,
                  maxLines: 3,
                  maxLength: 8192,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(labelText: '视频页面地址', hintText: '粘贴播放页地址', counterText: ''),
                  onChanged: (_) => setState(() => _message = null),
                ),
                const SizedBox(height: CampusGap.medium),
                Wrap(
                  spacing: CampusGap.small,
                  runSpacing: CampusGap.small,
                  children: [
                    OutlinedButton.icon(onPressed: _parsing ? null : _paste, icon: const CampusIcon(CampusIcons.paste), label: const Text('粘贴')),
                    FilledButton(
                      style: campusProminent,
                      onPressed: _parsing || _link.text.trim().isEmpty ? null : _parse,
                      child: CampusBusyContent(busy: _parsing, label: '解析并播放', busyLabel: '解析中', icon: const CampusIcon(CampusIcons.resume)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_message case final message?)
            Padding(
              padding: const EdgeInsets.only(top: CampusGap.medium),
              child: Text(message, style: TextStyle(color: CampusPalette.of(context).danger)),
            ),
        ],
      ),
    ),
  );
}
