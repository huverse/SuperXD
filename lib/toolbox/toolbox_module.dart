import 'dart:io';

import 'package:flutter/material.dart';

import 'package:superxd/domain/share_card.dart';
import 'package:superxd/toolbox/download/toolbox_download_manager.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_store.dart';

// 框架给工具服务的公共能力：本工具可用的目录、百宝箱库（同意记录等）、下载管理与自建中转地址（没配时为空）。
class ToolboxServiceContext {
  const ToolboxServiceContext({required this.base, required this.store, required this.downloads, this.relayUrl});
  final Directory base;
  final ToolboxStore store;
  final ToolboxDownloadManager downloads;
  final Uri? relayUrl;
}

// 一个工具的全部登记：名称、图标、页面、按需资源与自己的服务都写在这一处，增删工具只改注册表。
// openService 不为空表示工具有自己的本机数据，百宝箱首页据此给出「清除数据」（经 ToolboxService.clearData）。
class ToolboxModule {
  const ToolboxModule({
    required this.id,
    required this.name,
    required this.icon,
    required this.builder,
    this.resource,
    this.openService,
    this.openShared,
  });
  final String id;
  final String name;
  final IconData icon;
  final WidgetBuilder builder;
  final ToolboxResource? resource;
  final Future<ToolboxService> Function(ToolboxServiceContext context)? openService;
  // 好友分享的卡片由哪个工具打开：认得这张卡就返回要推入的页面，不认得返回空；组合根按注册表找，不直接认识工具页面。
  final Widget? Function(ShareCard card)? openShared;
}
