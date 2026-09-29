class AccountIdentity {
  const AccountIdentity({required this.source, required this.loginId});
  final String source;
  final String loginId;
}

class LegacyImportState {
  const LegacyImportState({required this.available, this.deferred = false, this.resumable = false});
  final bool available;
  final bool deferred;
  final bool resumable;
}

class LegacyImportReport {
  const LegacyImportReport({required this.imported, required this.skipped, this.alreadyImported = false});
  final int imported;
  final int skipped;
  final bool alreadyImported;
}
