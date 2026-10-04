import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerCampusLicenses() {
  LicenseRegistry.addLicense(() async* {
    // 本项目以 GPL-3.0 分发，随安装包附上许可全文（GPL 第 4、6 条要求）。
    yield LicenseEntryWithLineBreaks(['SuperXD'], await rootBundle.loadString('LICENSE'));
    yield LicenseEntryWithLineBreaks(['SuperXD 第三方组件与改编来源'], await rootBundle.loadString('assets/third_party_notices.txt'));
    yield LicenseEntryWithLineBreaks(['Maple Mono NF CN'], await rootBundle.loadString('assets/fonts/LICENSE.txt'));
    yield LicenseEntryWithLineBreaks(['Noto Serif SC'], await rootBundle.loadString('assets/fonts/noto_serif_sc_license.txt'));
  });
}
