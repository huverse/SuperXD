import 'dart:async';

import 'package:flutter/services.dart';

import 'package:superxd/domain/font_pack.dart';
import 'package:superxd/local/pack_library.dart';

// 把一个字体包的几个字重注册给引擎。同一族名再注册只是多一份，不影响显示。
typedef FontPackRegistrar = Future<void> Function(String family, List<Uint8List> fonts);

Future<void> registerFontPack(String family, List<Uint8List> fonts) {
  final loader = FontLoader(family);
  for (final font in fonts) {
    loader.addFont(Future.value(ByteData.sublistView(font)));
  }
  return loader.load();
}

// 字体包的本机文件、核对、注册与下载状态（人工决策见 domain/font_pack.dart）：下载、核对、取消、删除与清理是按需下载文件包的通用一套
// （local/pack_library.dart，星空素材包同用），文件放应用支持目录的 font_packs；字体包在全部字重核对通过后注册给引擎（register）。
class FontPackLibrary extends PackLibrary<FontPack> {
  FontPackLibrary({required super.directory, super.source, super.packs = fontPacks, FontPackRegistrar register = registerFontPack})
    : super(tag: 'FontPack', noun: '字体', onReady: (pack, fonts) => register(pack.family, fonts));
}
