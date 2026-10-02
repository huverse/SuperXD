import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/download/downloads_page.dart';
import 'package:superxd/toolbox/short_video/media_result_page.dart';
import 'package:superxd/toolbox/short_video/parse_coordinator.dart';
import 'package:superxd/toolbox/short_video/parse_history_page.dart';
import 'package:superxd/toolbox/short_video/short_video_controller.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_url.dart';
import 'package:superxd/domain/campus_log.dart';

class ShortVideoPage extends StatefulWidget {
  const ShortVideoPage({
    super.key,
    required this.runtime,
    this.initialInput = '',
    this.initialSource,
  });
  final ToolboxRuntime runtime;
  final String initialInput;
  final String? initialSource;
  @override
  State<ShortVideoPage> createState() => _ShortVideoPageState();
}

class _ShortVideoPageState extends State<ShortVideoPage> {
  late final _input = TextEditingController(text: widget.initialInput);
  ShortVideoController? _controller;
  late Future<void> _ready = _initialize();
  bool _prompting = false;
  int _inputVersion = 0;
  String? _message;
  List<Map<String, Object?>> _recent = const [];
  Future<void> _initialize() async {
    await widget.runtime.initialize();
    final controller = ShortVideoController(
      widget.runtime.coordinator,
      widget.runtime.store,
    );
    await controller.initialize();
    if (widget.initialSource case final source?
        when widget.runtime.coordinator.providers.containsKey(source)) {
      await controller.select(source);
    }
    if (!mounted) {
      controller.dispose();
      return;
    }
    _controller = controller;
    await _reloadRecent();
  }

  Future<void> _reloadRecent() async {
    try {
      final rows = await widget.runtime.store.history(limit: 5);
      if (mounted) setState(() => _recent = rows);
    } catch (error, stack) {
      campusLog(
        '[ShortVideo] action=recent errorType=${error.runtimeType}\n$stack',
      );
    }
  }

  Future<void> _parse({bool refresh = false, String? source}) async {
    final controller = _controller!;
    if (controller.busy || _prompting) return;
    final version = _inputVersion;
    setState(() {
      _prompting = true;
      _message = null;
    });
    try {
      final uri = shortVideoInput(_input.text);
      final candidates = controller.coordinator.candidates(
        source ?? controller.selected,
        controller.enabled,
      );
      final needed = <String>[];
      for (final provider in candidates) {
        if (!await widget.runtime.store.consent(
          provider.source.id,
          provider.source.consentVersion,
        )) {
          needed.add(provider.source.id);
        }
      }
      if (needed.isNotEmpty) {
        if (!mounted) return;
        final agreed = await showCampusConfirm(
          context,
          title: '第三方解析',
          message: '作品链接将发送至：\n${needed.map((id) => controller.coordinator.providers[id]!.source.host).join('\n')}\n\n不发送教务信息。仅处理本人或已获授权的作品。',
          action: '同意并解析',
        );
        if (!mounted || !agreed || version != _inputVersion) return;
        for (final id in needed) {
          final source = controller.coordinator.providers[id]!.source;
          await widget.runtime.store.grantConsent(id, source.consentVersion);
        }
      }
      if (!mounted || version != _inputVersion) return;
      setState(() => _prompting = false);
      await controller.parse(uri.toString(), refresh: refresh, source: source);
      if (!mounted || version != _inputVersion || controller.outcome == null) {
        return;
      }
      final again = await Navigator.push<Object?>(
        context,
        MaterialPageRoute(
          builder: (_) => MediaResultPage(
            runtime: widget.runtime,
            outcome: controller.outcome!,
          ),
        ),
      );
      await _reloadRecent();
      if (again is ToolboxDownload && mounted) {
        await _open(again.sourceUrl.toString(), again.providerId, refresh: true);
      }
      if (again == true && mounted) await _parse(refresh: true, source: source);
    } catch (error, stack) {
      campusLog(
        '[ShortVideo] action=input errorType=${error.runtimeType}\n$stack',
      );
      if (mounted) setState(() => _message = '请检查链接后重试');
    } finally {
      if (mounted) setState(() => _prompting = false);
    }
  }

  // 历史与下载任务直达结果页：按原来源解析且不改保存的来源选择；2分钟内命中缓存直接打开，否则正常解析可取消，失败原地提示。
  Future<void> _open(String sourceUrl, String? providerId, {bool refresh = false}) async {
    _replace(sourceUrl);
    await _parse(
      refresh: refresh,
      source: widget.runtime.coordinator.providers.containsKey(providerId) ? providerId : null,
    );
  }

  Future<void> _downloads() async {
    final task = await Navigator.push<ToolboxDownload>(
      context,
      MaterialPageRoute(builder: (_) => DownloadsPage(runtime: widget.runtime)),
    );
    if (task != null && mounted) {
      await _open(task.sourceUrl.toString(), task.providerId, refresh: true);
    }
  }

  Future<void> _history() async {
    final row = await Navigator.push<Map<String, Object?>>(
      context,
      MaterialPageRoute(
        builder: (_) => ParseHistoryPage(
          store: widget.runtime.store,
          providers: widget.runtime.coordinator.providers,
        ),
      ),
    );
    await _reloadRecent();
    if (row != null && mounted) {
      await _open(row['source_url'] as String, row['provider_id'] as String);
    }
  }

  void _replace(String value) {
    _inputVersion++;
    _controller?.invalidate();
    _input.text = value;
    setState(() => _message = null);
  }

  Future<void> _settings() async {
    final controller = _controller!;
    await showCampusDialog<void>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => CampusGlassDialog(
          title: const Text('解析设置'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CampusSwitchTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('保存解析历史'),
                subtitle: const Text('仅本机，最多80条／30天'),
                value: controller.historyEnabled,
                onChanged: (value) => controller.setHistory(value).catchError((
                  Object error,
                  StackTrace stack,
                ) {
                  campusLog(
                    '[ShortVideo] action=settings errorType=${error.runtimeType}\n$stack',
                  );
                }),
              ),
              for (final source in controller.coordinator.providers.values)
                CampusSwitchTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${source.source.name} 参与自动解析'),
                  subtitle: Text(switch (controller.coordinator.statuses[source.source.id]) {
                    null => '本次运行尚未解析',
                    final status => '${status.success ? '最近一次成功' : '最近一次未完成'} · ${formatCampusTimestamp(status.checkedAt.toUtc().toIso8601String())}',
                  }),
                  value: controller.enabled.contains(source.source.id),
                  onChanged: (value) => controller
                      .enable(source.source.id, value)
                      .catchError((Object error, StackTrace stack) {
                        campusLog(
                          '[ShortVideo] action=source_toggle errorType=${error.runtimeType}\n$stack',
                        );
                      }),
                ),
              TextButton(
                onPressed: () {
                  controller.coordinator.clearCache();
                  Navigator.pop(context);
                },
                child: const Text('清除解析缓存'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _inputVersion++;
    _controller?.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('短视频解析'),
      leading: IconButton(
        tooltip: '返回',
        onPressed: () {
          if (context.canPop()) {
            context.pop();
          } else {
            Navigator.pop(context);
          }
        },
        icon: const CampusIcon(CampusIcons.back),
      ),
    ),
    body: SafeArea(
      child: FutureBuilder<void>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: TextButton(
                onPressed: () => setState(() {
                  _ready = _initialize();
                }),
                child: const Text('准备失败，点击重试'),
              ),
            );
          }
          final controller = _controller;
          if (controller == null) {
            return const Center(child: CampusLoading(label: '正在准备'));
          }
          return ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    CampusSurface(
                      padding: EdgeInsets.fromLTRB(16, campusFieldGap(context), 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: controller.selected,
                            key: ValueKey(controller.selected),
                            decoration: const InputDecoration(
                              labelText: '解析来源',
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: ParseCoordinator.automatic,
                                child: Text(
                                  '自动',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              for (final provider
                                  in controller.coordinator.providers.values)
                                DropdownMenuItem(
                                  value: provider.source.id,
                                  child: Text(provider.source.name),
                                ),
                            ],
                            onChanged: _prompting
                                ? null
                                : (value) {
                                    if (value != null) {
                                      _inputVersion++;
                                      controller.select(value).catchError((
                                        Object error,
                                        StackTrace stack,
                                      ) {
                                        campusLog(
                                          '[ShortVideo] action=select errorType=${error.runtimeType}\n$stack',
                                        );
                                      });
                                    }
                                  },
                          ),
                          SizedBox(height: campusFieldGap(context)),
                          TextField(
                            controller: _input,
                            enabled: !_prompting,
                            minLines: 2,
                            maxLines: 5,
                            maxLength: 8192,
                            keyboardType: TextInputType.url,
                            style: const TextStyle(fontSize: 16),
                            decoration: const InputDecoration(
                              labelText: '作品链接',
                              hintText: '粘贴链接或分享内容',
                              counterText: '',
                            ),
                            onChanged: (_) {
                              _inputVersion++;
                              controller.invalidate();
                              setState(() => _message = null);
                            },
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _prompting
                                    ? null
                                    : () async {
                                        try {
                                          final value = await Clipboard.getData(
                                            Clipboard.kTextPlain,
                                          );
                                          if (mounted && value?.text != null) {
                                            _replace(value!.text!);
                                          }
                                        } catch (error, stack) {
                                          campusLog(
                                            '[ShortVideo] action=paste errorType=${error.runtimeType}\n$stack',
                                          );
                                        }
                                      },
                                icon: const CampusIcon(CampusIcons.paste),
                                label: const Text('粘贴'),
                              ),
                              if (_input.text.isNotEmpty)
                                TextButton(
                                  onPressed: _prompting
                                      ? null
                                      : () => _replace(''),
                                  child: const Text('清空'),
                                ),
                              FilledButton(
                                onPressed:
                                    _prompting ||
                                        controller.busy ||
                                        _input.text.trim().isEmpty
                                    ? null
                                    : () => _parse(),
                                child: CampusBusyContent(
                                  busy: controller.busy,
                                  label: '解析',
                                  busyLabel: '解析中',
                                ),
                              ),
                              if (controller.busy)
                                TextButton(
                                  onPressed: () {
                                    _inputVersion++;
                                    controller.cancel();
                                  },
                                  child: const Text('取消'),
                                ),
                            ],
                          ),
                          if (controller.attempting case final id?)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                '正在尝试 ${controller.coordinator.providers[id]!.source.name}',
                              ),
                            ),
                          if (_message != null || controller.error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                _message ?? controller.error!,
                                style: TextStyle(
                                  color: CampusPalette.of(context).danger,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        ListenableBuilder(
                          listenable: widget.runtime.downloads,
                          builder: (context, _) {
                            final active = widget.runtime.downloads.forTool('short_video').where((item) => !item.terminal).length;
                            return TextButton.icon(
                              onPressed: _downloads,
                              icon: const CampusIcon(CampusIcons.download),
                              label: Text(active > 0 ? '下载管理（$active）' : '下载管理'),
                            );
                          },
                        ),
                        TextButton.icon(
                          onPressed: _settings,
                          icon: const CampusIcon(CampusIcons.settings),
                          label: const Text('设置'),
                        ),
                      ],
                    ),
                    if (_recent.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: Text('最近解析', style: Theme.of(context).textTheme.titleMedium)),
                          TextButton.icon(
                            onPressed: _history,
                            iconAlignment: IconAlignment.end,
                            icon: const CampusIcon(CampusIcons.next),
                            label: const Text('全部'),
                          ),
                        ],
                      ),
                      CampusSurface(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          children: [
                            for (final row in _recent)
                              ParseHistoryTile(
                                row: row,
                                providers: controller.coordinator.providers,
                                onTap: _prompting || controller.busy
                                    ? null
                                    : () => _open(row['source_url'] as String, row['provider_id'] as String),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}
