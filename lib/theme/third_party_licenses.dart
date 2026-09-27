import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerCampusLicenses() {
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/third_party_notices.txt');
    yield LicenseEntryWithLineBreaks(['SuperXD 图标与曲线动效来源'], text);
    yield LicenseEntryWithLineBreaks(['Noto Serif SC'], await rootBundle.loadString('assets/fonts/noto_serif_sc_license.txt'));
  });
}
