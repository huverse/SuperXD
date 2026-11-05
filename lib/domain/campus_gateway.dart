import 'package:superxd/domain/auto_sync.dart';
import 'package:superxd/domain/schedule_store.dart';

class GatewayError {
  const GatewayError({required this.code, required this.message, this.detail});
  final String code;
  final String message;
  final String? detail;
}

class GatewayResult<T> {
  const GatewayResult({
    required this.ok,
    required this.source,
    required this.fetchedAt,
    this.error,
    this.needsInput,
    this.data,
  });

  final int schemaVersion = 1;
  final bool ok;
  final GatewayError? error;
  final String? needsInput;
  final String source;
  final String fetchedAt;
  final T? data;
}

class SessionView {
  const SessionView({required this.loginId, required this.name, required this.className});
  final String loginId;
  final String name;
  final String className;
}

class CaptchaView {
  const CaptchaView({
    required this.prompt,
    required this.hint,
    required this.contentType,
    required this.imageBase64,
  });
  final String prompt;
  final String hint;
  final String contentType;
  final String imageBase64;
}

class LoginView {
  const LoginView({this.session, this.captcha});
  final SessionView? session;
  final CaptchaView? captcha;
}

class ScheduleView {
  const ScheduleView({
    required this.term,
    required this.student,
    required this.courses,
    this.empty = false,
    this.message = '',
    this.termStartDate,
    this.revisionId,
    this.termLastPeriod,
  });
  final int? termLastPeriod;
  final TermRef term;
  final SessionView student;
  final List<CourseRecord> courses;
  final bool empty;
  final String message;
  final String? termStartDate;
  final String? revisionId;
}

class GradeSummary {
  const GradeSummary({
    required this.earnedCredit,
    required this.gpa,
    required this.averageScore,
    required this.weightedAverage,
    this.category = '合计',
  });
  final String category;
  final Object? earnedCredit;
  final Object? gpa;
  final Object? averageScore;
  final Object? weightedAverage;
}

class GradeCourse {
  const GradeCourse({
    required this.courseCode,
    required this.courseName,
    required this.credit,
    this.score,
    this.earnedCredit,
    this.gradePoint,
    this.usualScore,
    this.midtermScore,
    this.finalScore,
    this.skillScore,
    this.totalScore,
    this.attributes = const {},
  });
  final Map<String, String> attributes;
  final String courseCode;
  final String courseName;
  final Object? credit;
  final Object? score;
  final Object? earnedCredit;
  final Object? gradePoint;
  final Object? usualScore;
  final Object? midtermScore;
  final Object? finalScore;
  final Object? skillScore;
  final Object? totalScore;
}

class GradesView {
  const GradesView({
    required this.empty,
    required this.message,
    required this.term,
    required this.student,
    required this.summary,
    required this.effective,
    required this.original,
    this.cached = true,
    this.summaryScope = 'term',
    this.summaries = const [],
  });
  final bool cached;
  final String summaryScope;
  final List<GradeSummary> summaries;
  final bool empty;
  final String message;
  final TermRef term;
  final SessionView student;
  final GradeSummary? summary;
  final List<GradeCourse> effective;
  final List<GradeCourse> original;
}

class GradeTermOverview {
  const GradeTermOverview({required this.term, required this.cached, this.empty = false, this.fetchedAt, this.summary, this.summaryScope = 'unknown', this.effectiveCount = 0, this.originalCount = 0, this.error});
  final TermRef term;
  final bool cached;
  final bool empty;
  final String? fetchedAt;
  final GradeSummary? summary;
  final String summaryScope;
  final int effectiveCount;
  final int originalCount;
  final String? error;
}

class BellPeriod {
  const BellPeriod({
    required this.period,
    required this.dayPart,
    required this.dayPartCode,
    required this.start,
    required this.end,
  });
  final int period;
  final String dayPart;
  final String dayPartCode;
  final String start;
  final String end;
}

class BellsView {
  const BellsView({
    required this.empty,
    required this.message,
    required this.term,
    required this.periods,
    this.sourceTerm,
  });
  final bool empty;
  final String message;
  final TermRef term;
  final List<BellPeriod> periods;
  final TermRef? sourceTerm;
}

// 课前提醒设置，按学期一条；默认关闭，提前 15 分钟。live 为在状态栏胶囊（OPPO 流体云）显示倒计时，默认关闭。
class ReminderSetting {
  const ReminderSetting({required this.enabled, required this.leadMinutes, required this.live});
  final bool enabled;
  final int leadMinutes;
  final bool live;
  static const leads = [5, 10, 15, 30];
  static const initial = ReminderSetting(enabled: false, leadMinutes: 15, live: false);
}

class RevisionView {
  const RevisionView({
    required this.id,
    required this.source,
    required this.createdAt,
    required this.summary,
    this.sequence = 0,
    this.operation = 'edit',
    this.restoredFromId,
    this.current = false,
  });
  final int sequence;
  final String operation;
  final String? restoredFromId;
  final bool current;
  final String id;
  final String source;
  final String createdAt;
  final String summary;
}

abstract class CampusGateway {
  Future<GatewayResult<SessionView>> restoreSession();
  Future<GatewayResult<LoginView>> login(String account, String password);
  Future<GatewayResult<LoginView>> submitLoginCaptcha(String code);
  Future<GatewayResult<CaptchaView>> refreshLoginCaptcha();
  Future<GatewayResult<List<TermRef>>> listTerms();
  Future<GatewayResult<List<TermRef>>> syncTerms();
  Future<GatewayResult<ScheduleView>> syncSchedule(TermRef term);
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope);
  Future<GatewayResult<GradesView>> syncGrades(TermRef term);
  Future<GatewayResult<GradesView>> readGrades(TermRef term);
  Future<GatewayResult<List<GradeTermOverview>>> readGradeYear(String year);
  Future<GatewayResult<BellsView>> syncBells(TermRef term);
  Future<GatewayResult<BellsView>> readBells(TermRef term);
  Future<GatewayResult<TermRef?>> readBellsSource(TermRef term);
  Future<GatewayResult<TermRef>> useBellsSource(TermRef target, TermRef source);
  Future<GatewayResult<TermRef>> setTermStart(TermRef term, String date);
  Future<GatewayResult<RevisionView>> saveScheduleRevision(TermRef term, List<CourseRecord> courses, String summary, {required String? expectedRevisionId});
  Future<GatewayResult<SyncPlan>> planScheduleSync(TermRef term, List<CourseRecord> courses);
  Future<GatewayResult<RevisionView>> commitScheduleSync(TermRef term, List<CourseRecord> courses, {required bool confirm, String? expectedRevisionId});
  Future<GatewayResult<List<RevisionView>>> listScheduleRevisions(TermRef term, {int? beforeSequence, int limit = 20});
  Future<GatewayResult<ScheduleRevision>> readScheduleRevision(TermRef term, String id);
  Future<GatewayResult<RevisionView>> restoreScheduleRevision(TermRef term, String id, {required String? expectedRevisionId});
  // 只读写本机账号库；未设置过时返回 ReminderSetting.initial。
  Future<GatewayResult<ReminderSetting>> readReminderSetting(TermRef term);
  Future<GatewayResult<ReminderSetting>> saveReminderSetting(TermRef term, ReminderSetting setting);
  // 逐项合并教务课表（人工决策见 domain/auto_sync.dart）：同一事务里核对 head，先记一版教务同步（下次的基准），合并结果不同时再记一版我的修改。
  Future<GatewayResult<RevisionView>> commitScheduleMerge(TermRef term, List<CourseRecord> courses, List<CourseRecord> merged, String summary, {required String? expectedRevisionId});
  // 和本地改过的课表冲突的教务课表：dismissed 为真是用户选了保留本地（同一份教务课表不再提醒），为假是留到打扰时机再问；
  // 返回之后还等不等用户来选（选过保留本地的同一份仍是 false）。教务课表落成新版本时同一学期的这一条随之删掉。
  Future<GatewayResult<bool>> holdScheduleSync(TermRef term, List<CourseRecord> courses, {required bool dismissed});
  Future<GatewayResult<List<HeldScheduleSync>>> readHeldScheduleSyncs();
  // 自动同步的设置与上次结果，只读写本机账号库；没设置过时是关着的默认值。
  Future<GatewayResult<AutoSyncView>> readAutoSync();
  Future<GatewayResult<AutoSyncSetting>> saveAutoSyncSetting(AutoSyncSetting setting);
  Future<GatewayResult<AutoSyncStatus>> recordAutoSync(AutoSyncStatus status);
}
