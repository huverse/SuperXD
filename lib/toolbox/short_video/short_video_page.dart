import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/download/downloads_page.dart';
import 'package:superxd/toolbox/short_video/media_result_page.dart';
import 'package:superxd/toolbox/short_video/parse_coordinator.dart';
import 'package:superxd/toolbox/short_video/parse_history_page.dart';
import 'package:superxd/toolbox/short_video/short_video_controller.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_url.dart';

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
  }

  Future<void> _parse({bool refresh = false}) async {
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
        controller.selected,
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
        final agreed = await showCampusDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('第三方解析'),
            content: Text(
              '作品链接将发送至：\n${needed.map((id) => controller.coordinator.providers[id]!.source.host).join('\n')}\n\n不发送教务信息。仅处理本人或已获授权的作品。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('同意并解析'),
              ),
            ],
          ),
        );
        if (!mounted || agreed != true || version != _inputVersion) return;
        for (final id in needed) {
          final source = controller.coordinator.providers[id]!.source;
          await widget.runtime.store.grantConsent(id, source.consentVersion);
        }
      }
      if (!mounted || version != _inputVersion) return;
      setState(() => _prompting = false);
      await controller.parse(uri.toString(), refresh: refresh);
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
      if (again is ToolboxDownload && mounted) await _prepareRetry(again);
      if (again == true && mounted) await _parse(refresh: true);
    } catch (error, stack) {
      debugPrint(
        '[ShortVideo] action=input errorType=${error.runtimeType}\n$stack',
      );
      if (mounted) setState(() => _message = '请检查链接后重试');
    } finally {
      if (mounted) setState(() => _prompting = false);
    }
  }

  Future<void> _prepareRetry(ToolboxDownload task) async {
    _replace(task.sourceUrl.toString());
    widget.runtime.coordinator.clearCache();
    if (task.providerId case final id?
        when widget.runtime.coordinator.providers.containsKey(id)) {
      await _controller!.select(id);
    }
  }

  Future<void> _downloads() async {
    final task = await Navigator.push<ToolboxDownload>(
      context,
      MaterialPageRoute(builder: (_) => DownloadsPage(runtime: widget.runtime)),
    );
    if (task != null && mounted) await _prepareRetry(task);
  }

  Future<void> _history() async {
    final row = await Navigator.push<Map<String, Object?>>(
      context,
      MaterialPageRoute(
        builder: (_) => ParseHistoryPage(store: widget.runtime.store),
      ),
    );
    if (row != null && mounted) {
      _replace(row['source_url'] as String);
      final source = row['provider_id'] as String;
      if (widget.runtime.coordinator.providers.containsKey(source)) {
        await _controller!.select(source);
      }
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
        builder: (context, _) => AlertDialog(
          title: const Text('解析设置'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('保存解析历史'),
                subtitle: const Text('仅本机，最多80条／30天'),
                value: controller.historyEnabled,
                onChanged: (value) => controller.setHistory(value).catchError((
                  Object error,
                  StackTrace stack,
                ) {
                  debugPrint(
                    '[ShortVideo] action=settings errorType=${error.runtimeType}\n$stack',
                  );
                }),
              ),
              for (final source in controller.coordinator.providers.values)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${source.source.name} 参与自动解析'),
                  value: controller.enabled.contains(source.source.id),
                  onChanged: (value) => controller
                      .enable(source.source.id, value)
                      .catchError((Object error, StackTrace stack) {
                        debugPrint(
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
                onPressed: () => setState(() => _ready = _initialize()),
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
                      padding: const EdgeInsets.all(16),
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
                                        debugPrint(
                                          '[ShortVideo] action=select errorType=${error.runtimeType}\n$stack',
                                        );
                                      });
                                    }
                                  },
                          ),
                          const SizedBox(height: 16),
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
                                          debugPrint(
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
                      children: [
                        TextButton.icon(
                          onPressed: _downloads,
                          icon: const CampusIcon(CampusIcons.download),
                          label: const Text('下载管理'),
                        ),
                        TextButton(
                          onPressed: _history,
                          child: const Text('解析历史'),
                        ),
                        TextButton(
                          onPressed: _settings,
                          child: const Text('设置'),
                        ),
                      ],
                    ),
                    for (final provider
                        in controller.coordinator.providers.values)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(provider.source.name),
                        subtitle: Text(
                          controller.coordinator.statuses[provider.source.id] ==
                                  null
                              ? '尚无本机解析记录'
                              : controller
                                    .coordinator
                                    .statuses[provider.source.id]!
                                    .success
                              ? '最近一次解析成功'
                              : '最近一次解析未完成',
                        ),
                      ),
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
