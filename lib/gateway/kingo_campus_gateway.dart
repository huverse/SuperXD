import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import 'package:superxd/gateway/kingo_auth.dart';
import 'package:superxd/edu/kingo_client.dart';
import 'package:superxd/edu/parse_grades.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/local/app_database.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/period_spans.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/grades.dart' as grades;
import 'package:superxd/domain/campus_log.dart';

class KingoCampusGateway implements CampusGateway {
  KingoCampusGateway({required this.database, KingoClient? client, DateTime Function()? now})
      : client = client ?? KingoClient(),
        _now = now ?? DateTime.now;

  final AppDatabase database;
  final KingoClient client;
  final DateTime Function() _now;
  int _networkCalls = 0;
  Future<GatewayResult<GradesView>>? _gradesInFlight;
  String? _gradesTerm;

  Future<GatewayResult<T>> _networkGuard<T>(Future<GatewayResult<T>> Function() body) async {
    if (_gradesInFlight != null) return _fail('SYNC_BUSY', '成绩同步进行中，请稍后重试');
    _networkCalls++;
    try { return await _guard(body); } finally { _networkCalls--; }
  }
  late final KingoAuth _auth = KingoAuth(client: client, now: _now);

  void abandonLogin() => _auth.cancel();

  @override
  Future<GatewayResult<SessionView>> restoreSession() async {
    final saved = await database.readSession();
    if (saved == null) return _fail('SESSION_EXPIRED', '教务登录已失效，需要重新登录');
    _applyCookie(saved.cookieJson);
    return _ok(_sessionOf(saved), source: 'local', fetchedAt: saved.savedAt);
  }

  @override
  Future<GatewayResult<LoginView>> login(String account, String password) => _guard(() async => _saveLogin(await _auth.login(account, password)));

  @override
  Future<GatewayResult<LoginView>> submitLoginCaptcha(String code) => _guard(() async => _saveLogin(await _auth.submitLoginCaptcha(code)));

  @override
  Future<GatewayResult<CaptchaView>> refreshLoginCaptcha() => _auth.refreshLoginCaptcha();

  @override
  Future<GatewayResult<List<TermRef>>> listTerms() {
    return _guard(() async {
      final local = await database.terms();
      return _ok(local, source: 'local', fetchedAt: _stamp());
    });
  }

  @override
  Future<GatewayResult<List<TermRef>>> syncTerms() {
    return _networkGuard(() async {
      final session = await _openSession();
      final profile = session == null ? null : await client.fetchProfile();
      final listed = await client.listTerms();
      final terms = listed.terms.map((term) => TermRef(xn: term.xn, xq: term.xq, label: term.label)).toList();
      final xn = profile?.xn ?? listed.published?.xn;
      final xq = profile?.xq ?? listed.published?.xq;
      if (xn != null && xq != null && !terms.any((term) => term.xn == xn && term.xq == xq)) {
        terms.add(TermRef(xn: xn, xq: xq, label: '$xn-${int.parse(xn) + 1}学年第${xq == '0' ? '一' : '二'}学期'));
      }
      if (terms.isEmpty) return _fail('UPSTREAM_FORMAT', '教务未返回学期列表');
      await database.saveTerms(terms, currentXn: xn, currentXq: xq);
      if (session != null && profile != null) {
        await database.writeSession(SavedSession(loginId: session.loginId, displayName: session.displayName, className: session.className,
          cookieJson: jsonEncode({'cookies': client.jar, 'pageSession': client.pageSession, 'userCode': profile.userCode}), savedAt: _stamp()));
      }
      final ordered = (await database.terms()).where((term) => terms.any((remote) => remote.key == term.key)).toList();
      return _ok(ordered, source: 'edu', fetchedAt: _stamp());
    });
  }

  @override
  Future<GatewayResult<ScheduleView>> syncSchedule(TermRef term) {
    return _networkGuard(() async {
      final saved = await _openSession();
      if (saved == null) return _fail('SESSION_EXPIRED', '教务登录已失效，需要重新登录');
      final userCode = _userCodeOf(saved.cookieJson);
      if (userCode.isEmpty) {
        await database.clearSession();
        return _fail('SESSION_EXPIRED', '教务登录已失效，需要重新登录');
      }
      final parsed = await client.fetchSchedule(xn: term.xn, xq: term.xq, userCode: userCode);
      final courses = parsed.courses;
      var conflict = false;
      try {
        await database.syncSchedule(term, courses, confirm: false, now: _stamp());
      } on ScheduleConflict catch (error, stack) {
        campusLog('[Schedule] action=sync confirmation=required code=${error.code}\n$stack');
        conflict = true;
      }
      if (parsed.name.isNotEmpty) await database.updateSessionNames(parsed.name, parsed.className);
      final student = SessionView(
        loginId: parsed.loginId.isEmpty ? saved.loginId : parsed.loginId,
        name: parsed.name,
        className: parsed.className,
      );
      return _ok(
        ScheduleView(
          term: TermRef(xn: term.xn, xq: term.xq, label: parsed.termLabel.isEmpty ? term.label : parsed.termLabel),
          student: student,
          courses: courses,
          empty: courses.isEmpty,
          message: conflict ? syncOverwriteMessage : courses.isEmpty ? '教务系统没有课表' : '',
        ),
        source: 'edu',
        fetchedAt: _stamp(),
      );
    });
  }

  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async {
    final store = await _rules(scope.term);
    final head = store.head(scope.term);
    final courses = head?.courses ?? const <CourseRecord>[];
    final session = await database.readSession();
    final student = session == null
        ? const SessionView(loginId: '', name: '', className: '')
        : _sessionOf(session);
    if (head == null) {
      return _ok(
        ScheduleView(term: scope.term, student: student, courses: const [], empty: true, message: '还没有课表', termStartDate: store.termStart(scope.term)),
        source: 'local',
        fetchedAt: _stamp(),
      );
    }
    final given = scope.termStartDate;
    final start = (given != null && given.isNotEmpty) ? given : store.termStart(scope.term);
    final resolved = scope.kind == 'day'
        ? ScheduleScope.day(term: scope.term, date: scope.date ?? '', termStartDate: start ?? '')
        : scope;
    try {
      return _ok(
        ScheduleView(term: scope.term, student: student, courses: visibleCourses(courses, resolved), termStartDate: store.termStart(scope.term), revisionId: head.id, termLastPeriod: maxCoursePeriod(courses)),
        source: head.source,
        fetchedAt: head.createdAt,
      );
    } on StateError catch (error) {
      return _fail('TERM_START_REQUIRED', error.message);
    }
  }

  @override
  Future<GatewayResult<GradesView>> syncGrades(TermRef term) {
    final pending = _gradesInFlight;
    if (pending != null) return _gradesTerm == term.key ? pending : Future.value(_fail('SYNC_BUSY', '另一个学期正在同步，请稍后重试'));
    if (_networkCalls > 0) return Future.value(_fail('SYNC_BUSY', '其他教务同步进行中，请稍后重试'));
    _gradesTerm = term.key;
    final future = _syncGrades(term);
    _gradesInFlight = future;
    return future.whenComplete(() { _gradesInFlight = null; _gradesTerm = null; });
  }

  Future<GatewayResult<GradesView>> _syncGrades(TermRef term) => _guard(() async {
    final saved = await _openSession();
    if (saved == null) return _fail('SESSION_EXPIRED', '教务登录已失效，需要重新登录');
    campusLog('[Grades] action=sync term=${term.key} state=start');
    final form = await client.fetchGradeForm();
    final pages = await client.fetchGrades(xn: term.xn, xq: term.xq, rxnj: form.rxnj, nj: form.nj);
    final bothEmpty = pages.effective.courses.isEmpty && pages.original.courses.isEmpty;
    var missingEmptyHeader = false;
    for (final page in [pages.effective, pages.original]) {
      if (page.loginId.isEmpty || page.termLabel.isEmpty) {
        if (!bothEmpty) throw const grades.GradeDataException('成绩单归属信息不完整，保留原成绩');
        missingEmptyHeader = true;
      }
      if (page.loginId.isNotEmpty && page.loginId != saved.loginId) throw const grades.GradeDataException('成绩单身份与当前账号不一致，保留原成绩');
      final label = page.termLabel.replaceAll(RegExp(r'\s+'), '').replaceAll('–', '-');
      final semester = term.xq == '0' ? r'(?:第一|第1|一|1)' : r'(?:第二|第2|二|2)';
      if (label.isNotEmpty && !RegExp('^${term.xn}-${int.parse(term.xn) + 1}学年$semester学期\$').hasMatch(label)) throw const grades.GradeDataException('成绩单学期与查询不一致，保留原成绩');
    }
    if (missingEmptyHeader) {
      // [人工决策-2026-09-25 02:27:38] 学校空页无抬头：双份明确空+重新核对会话身份才接收，已有非空缓存绝不自动清空。
      final profile = await client.fetchProfile();
      if (profile.loginId != saved.loginId) throw const grades.GradeDataException('空成绩响应的会话身份无法确认，保留原成绩');
      final previous = await database.gradesRow(term);
      if (previous != null && !grades.gradesFromJson(grades.decodeGradeJson(previous['payload_json'] as String), term).empty) throw const grades.GradeDataException('教务返回无抬头空结果，已保留此前非空成绩，请核对教务');
    }
    final effective = pages.effective.courses.map(_gradeCourse).toList();
    final original = pages.original.courses.map(_gradeCourse).toList();
    final summaries = pages.effective.summary.map((row) => GradeSummary(category: row.category, earnedCredit: row.earnedCredit, gpa: row.gpa, averageScore: row.averageScore, weightedAverage: row.weightedAverage)).toList();
    // [人工决策-2026-09-25 01:48:56] 只展示明确教务合计；分类不能冒充总计，不自行推算、换算或合并重修成绩。
    final totals = summaries.where((row) => row.category == '合计').toList();
    if (totals.length > 1) throw const grades.GradeDataException('教务合计不唯一，保留原成绩');
    final view = GradesView(empty: effective.isEmpty && original.isEmpty, message: effective.isEmpty && original.isEmpty ? '教务明确暂无成绩记录' : '',
      term: TermRef(xn: term.xn, xq: term.xq, label: pages.effective.termLabel.isEmpty ? term.label : pages.effective.termLabel), student: SessionView(loginId: saved.loginId, name: pages.effective.name, className: pages.effective.className),
      summary: totals.firstOrNull, effective: effective, original: original, summaries: summaries);
    final payload = jsonEncode(grades.gradesJson(view));
    grades.gradesFromJson(grades.decodeGradeJson(payload), term);
    final fetchedAt = _stamp();
    await database.writeGrades(term.xn, term.xq, fetchedAt, payload, summaryJson: jsonEncode(grades.gradeOverviewJson(view)));
    campusLog('[Grades] action=sync term=${term.key} state=done effective=${effective.length} original=${original.length}');
    return _ok(view, source: 'edu', fetchedAt: fetchedAt);
  });

  @override
  Future<GatewayResult<GradesView>> readGrades(TermRef term) => _guard(() async {
    final row = await database.gradesRow(term);
    if (row == null) return _ok(GradesView(empty: true, cached: false, message: '尚未同步此学期', term: term, student: const SessionView(loginId: '', name: '', className: ''), summary: null, effective: const [], original: const []), source: 'local', fetchedAt: '');
    final view = grades.gradesFromJson(grades.decodeGradeJson(row['payload_json'] as String), term);
    final fetchedAt = row['fetched_at'] as String;
    if (row['summary_json'] == null) await database.backfillGradeSummaries([(term: term, payload: row['payload_json'] as String, fetchedAt: fetchedAt, summary: jsonEncode(grades.gradeOverviewJson(view)))]);
    return _ok(view, source: 'local', fetchedAt: fetchedAt);
  });

  @override
  Future<GatewayResult<List<GradeTermOverview>>> readGradeYear(String year) => _guard(() async {
    final rows = await database.gradeYearRows(year);
    final result = <GradeTermOverview>[];
    final backfill = <({TermRef term, String payload, String fetchedAt, String summary})>[];
    for (final row in rows) {
      final term = TermRef(xn: row['xn'] as String, xq: row['xq'] as String, label: row['label'] as String);
      if (row['fetched_at'] == null) { result.add(GradeTermOverview(term: term, cached: false)); continue; }
      final fetchedAt = row['fetched_at'] as String;
      try {
        Map<String, Object?> summary;
        if (row['summary_json'] == null) {
          final payload = row['legacy_payload'] as String;
          final view = grades.gradesFromJson(grades.decodeGradeJson(payload), term);
          summary = grades.gradeOverviewJson(view);
          backfill.add((term: term, payload: payload, fetchedAt: fetchedAt, summary: jsonEncode(summary)));
        } else { summary = grades.decodeGradeJson(row['summary_json'] as String); }
        result.add(grades.gradeOverviewFromJson(summary, term, fetchedAt));
      } on grades.GradeDataException catch (error, stack) {
        campusLog('[Grades] action=overview term=${term.key} invalid=true\n$stack');
        result.add(GradeTermOverview(term: term, cached: true, fetchedAt: fetchedAt, error: error.message));
      }
    }
    await database.backfillGradeSummaries(backfill);
    return _ok(result, source: 'local', fetchedAt: _stamp());
  });

  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) async {
    final adopted = await database.bellsSource(term.xn, term.xq);
    final resolved = adopted ?? term;
    final row = await database.bellsRow(resolved.xn, resolved.xq);
    if (row == null) {
      return _ok(BellsView(empty: true, message: '还没有作息', term: term, periods: const []), source: 'local', fetchedAt: _stamp());
    }
    final periods = (jsonDecode(row['periods_json'] as String) as List<dynamic>).map((item) {
      final period = (item as Map).cast<String, Object?>();
      return BellPeriod(
        period: period['period'] as int,
        dayPart: period['dayPart'] as String? ?? '',
        dayPartCode: period['dayPartCode'] as String? ?? '',
        start: period['start'] as String? ?? '',
        end: period['end'] as String? ?? '',
      );
    }).toList();
    return _ok(
      BellsView(empty: row['empty'] == 1, message: row['message'] as String? ?? '', term: term, periods: periods, sourceTerm: resolved),
      source: 'local',
      fetchedAt: row['fetched_at'] as String? ?? _stamp(),
    );
  }

  @override
  Future<GatewayResult<TermRef?>> readBellsSource(TermRef term) async {
    final source = await database.bellsSource(term.xn, term.xq);
    return _ok(source, source: 'local', fetchedAt: _stamp());
  }

  @override
  Future<GatewayResult<TermRef>> useBellsSource(TermRef target, TermRef source) async {
    // [人工决策-2026-09-24 19:22:21] 采用来源只引用原始缓存；确认后持久化，普通同步不改绑定。
    final row = await database.bellsRow(source.xn, source.xq);
    if (row == null || row['empty'] == 1) return _fail('BELLS_SOURCE_INVALID', '这套作息没有可用时间，原选择保持不变');
    final periods = jsonDecode(row['periods_json'] as String) as List<dynamic>;
    if (!_validBellPeriods(periods)) return _fail('BELLS_SOURCE_INVALID', '这套作息时间不完整，原选择保持不变');
    await database.setBellsSource(targetXn: target.xn, targetXq: target.xq, sourceXn: source.xn, sourceXq: source.xq);
    return _ok(source, source: 'user', fetchedAt: _stamp());
  }

  @override
  Future<GatewayResult<BellsView>> syncBells(TermRef term) {
    return _networkGuard(() async {
      final parsed = await client.fetchBells(xn: term.xn, xq: term.xq);
      final periods = parsed.periods
          .map((period) => BellPeriod(
                period: period.period,
                dayPart: period.dayPart,
                dayPartCode: period.dayPartCode,
                start: period.start,
                end: period.end,
              ))
          .toList();
      final payload = periods.map((period) => <String, Object?>{
        'period': period.period, 'dayPart': period.dayPart, 'dayPartCode': period.dayPartCode,
        'start': period.start, 'end': period.end,
      }).toList();
      if ((parsed.empty && payload.isNotEmpty) || (!parsed.empty && !_validBellPeriods(payload))) {
        return _fail('UPSTREAM_FORMAT', '作息时间数据异常，保留已有缓存');
      }
      final fetchedAt = _stamp();
      await database.writeBells(
        xn: term.xn,
        xq: term.xq,
        fetchedAt: fetchedAt,
        empty: parsed.empty,
        message: parsed.message,
        periodsJson: jsonEncode(payload),
      );
      return _ok(
        BellsView(
          empty: parsed.empty,
          message: parsed.message,
          term: TermRef(xn: term.xn, xq: term.xq, label: parsed.termLabel.isEmpty ? term.label : parsed.termLabel),
          periods: periods,
        ),
        source: 'edu',
        fetchedAt: fetchedAt,
      );
    });
  }

  @override
  Future<GatewayResult<TermRef>> setTermStart(TermRef term, String date) async {
    try {
      final store = await _rules(term);
      final saved = store.setTermStart(term, date);
      await database.setTermStart(term, date);
      return _ok(saved, source: 'user', fetchedAt: _stamp());
    } on FormatException catch (error) {
      return _fail('INVALID_DATE', error.message);
    }
  }

  @override
  Future<GatewayResult<RevisionView>> saveScheduleRevision(TermRef term, List<CourseRecord> courses, String summary, {required String? expectedRevisionId}) => _guard(() async {
    final row = await database.saveSchedule(term, courses, summary, expectedRevisionId: expectedRevisionId, now: _stamp());
    return _ok(_revision(row), source: row.source, fetchedAt: row.createdAt);
  });

  @override
  Future<GatewayResult<SyncPlan>> planScheduleSync(TermRef term, List<CourseRecord> courses) async {
    final store = await _rules(term);
    return _ok(store.planSync(term, courses), source: 'local', fetchedAt: _stamp());
  }

  @override
  Future<GatewayResult<RevisionView>> commitScheduleSync(TermRef term, List<CourseRecord> courses, {required bool confirm, String? expectedRevisionId}) => _guard(() async {
    final row = await database.syncSchedule(term, courses, confirm: confirm, expectedRevisionId: expectedRevisionId, now: _stamp());
    return _ok(_revision(row), source: row.source, fetchedAt: row.createdAt);
  });

  @override
  Future<GatewayResult<List<RevisionView>>> listScheduleRevisions(TermRef term, {int? beforeSequence, int limit = 20}) => _guard(() async {
    final head = await database.headRevisionId(term);
    final page = await database.revisionPage(term, beforeSequence: beforeSequence, limit: limit);
    final rows = page.map((row) => RevisionView(id: row['id'] as String, source: row['source'] as String, createdAt: row['created_at'] as String,
      summary: row['summary'] as String, sequence: row['sequence'] as int, operation: row['operation'] as String,
      restoredFromId: row['restored_from_id'] as String?, current: row['id'] == head)).toList();
    return _ok(rows, source: 'local', fetchedAt: _stamp());
  });

  @override
  Future<GatewayResult<ScheduleRevision>> readScheduleRevision(TermRef term, String id) => _guard(() async {
    final row = await database.readRevision(term, id);
    return row == null ? _fail('REVISION_MISSING', '版本已清理或不属于此学期') : _ok(row, source: row.source, fetchedAt: row.createdAt);
  });

  @override
  Future<GatewayResult<RevisionView>> restoreScheduleRevision(TermRef term, String id, {required String? expectedRevisionId}) => _guard(() async {
    final target = await database.readRevision(term, id);
    if (target == null) return _fail('REVISION_MISSING', '版本已清理或不属于此学期');
    final row = await database.restoreRevision(term, id, expectedRevisionId: expectedRevisionId, now: _stamp());
    return _ok(_revision(row), source: row.source, fetchedAt: row.createdAt);
  });

  Future<GatewayResult<LoginView>> _saveLogin(GatewayResult<LoginView> result) async {
    if (result.ok && result.data?.session != null) await _auth.persistSession(database);
    return result;
  }

  Future<SavedSession?> _openSession() async {
    final saved = await database.readSession();
    if (saved == null) return null;
    _applyCookie(saved.cookieJson);
    return saved;
  }

  bool _validBellPeriods(List<dynamic> periods) {
    final seen = <int>{};
    return periods.isNotEmpty && periods.every((value) {
      if (value is! Map) return false;
      final period = value['period'];
      final start = value['start'];
      final end = value['end'];
      if (period is! int || period < 1 || !seen.add(period) || start is! String || end is! String) return false;
      final startMinute = clockMinutes(start);
      final endMinute = clockMinutes(end);
      return startMinute != null && endMinute != null && endMinute > startMinute;
    });
  }

  void _applyCookie(String cookieJson) {
    final decoded = jsonDecode(cookieJson);
    if (decoded is! Map) return;
    final map = decoded.cast<String, Object?>();
    final cookies = map['cookies'];
    client.jar
      ..clear()
      ..addAll(cookies is Map ? cookies.map((key, value) => MapEntry('$key', '$value')) : const {});
    client.pageSession = map['pageSession'] as String? ?? '';
  }

  String _userCodeOf(String cookieJson) {
    final decoded = jsonDecode(cookieJson);
    if (decoded is! Map) return '';
    return decoded.cast<String, Object?>()['userCode'] as String? ?? '';
  }

  SessionView _sessionOf(SavedSession saved) {
    return SessionView(loginId: saved.loginId, name: saved.displayName, className: saved.className);
  }

  GradeCourse _gradeCourse(ParsedGradeCourse course) {
    return GradeCourse(
      courseCode: course.courseCode,
      courseName: course.courseName,
      credit: course.credit,
      attributes: course.attributes,
      score: course.score,
      earnedCredit: course.earnedCredit,
      gradePoint: course.gradePoint,
      usualScore: course.usualScore,
      midtermScore: course.midtermScore,
      finalScore: course.finalScore,
      skillScore: course.skillScore,
      totalScore: course.totalScore,
    );
  }

  Future<ScheduleStore> _rules(TermRef term, {String? revisionId}) => database.loadTermStore(term, revisionId: revisionId);

  RevisionView _revision(ScheduleRevision row) {
    return RevisionView(id: row.id, source: row.source, createdAt: row.createdAt, summary: row.summary, sequence: row.sequence, operation: row.operation, restoredFromId: row.restoredFromId, current: true);
  }

  String _stamp() => _now().toUtc().toIso8601String();

  GatewayResult<T> _ok<T>(T data, {required String source, required String fetchedAt}) {
    return GatewayResult(ok: true, source: source, fetchedAt: fetchedAt, data: data);
  }

  GatewayResult<T> _fail<T>(String code, String message) {
    return GatewayResult(ok: false, source: 'local', fetchedAt: _stamp(), error: GatewayError(code: code, message: message));
  }

  Future<GatewayResult<T>> _guard<T>(Future<GatewayResult<T>> Function() body) async {
    try {
      return await body();
    } on grades.GradeDataException catch (error, stack) {
      campusLog('[Grades] action=boundary invalid=true\n$stack');
      return _fail('GRADE_DATA_INVALID', error.message);
    } on RevisionConflict catch (error, stack) {
      campusLog('[Schedule] action=commit conflict=true\n$stack');
      return _fail('REVISION_CONFLICT', error.message);
    } on ScheduleConflict catch (error, stack) {
      campusLog('[Schedule] action=sync confirmation=required\n$stack');
      return _fail(error.code, error.toString());
    } on ScheduleValidation catch (error, stack) {
      campusLog('[Schedule] action=validate failed=true\n$stack');
      return _fail('INVALID_SCHEDULE', error.message);
    } on KingoCallException catch (error, stack) {
      campusLog('[KingoCampusGateway] code=${error.failure.code}\n$stack');
      if (error.failure.code == 'SESSION_EXPIRED') {
        await database.clearSession();
        client.jar.clear();
        client.pageSession = '';
      }
      return _fail(error.failure.code, error.failure.message);
    } on TimeoutException catch (error, stack) {
      campusLog('[KingoCampusGateway] $error\n$stack');
      return _fail('NETWORK_TIMEOUT', '教务连接超时');
    } on FormatException catch (error, stack) {
      campusLog('[KingoCampusGateway] code=UPSTREAM_FORMAT errorType=${error.runtimeType}\n$stack');
      return _fail('UPSTREAM_FORMAT', '教务返回的数据格式异常，未覆盖已有缓存');
    } on SocketException catch (error, stack) {
      campusLog('[KingoCampusGateway] code=NETWORK_FAILED errorType=${error.runtimeType}\n$stack');
      return _fail('NETWORK_FAILED', '教务连接失败');
    } on http.ClientException catch (error, stack) {
      campusLog('[KingoCampusGateway] code=NETWORK_FAILED errorType=${error.runtimeType}\n$stack');
      return _fail('NETWORK_FAILED', '教务连接失败');
    } on DatabaseException catch (error, stack) {
      campusLog('[KingoCampusGateway] code=LOCAL_STORAGE_FAILED errorType=${error.runtimeType}\n$stack');
      return _fail('LOCAL_STORAGE_FAILED', '本地数据保存失败');
    } catch (error, stack) {
      campusLog('[KingoCampusGateway] code=OPERATION_FAILED errorType=${error.runtimeType}\n$stack');
      return _fail('OPERATION_FAILED', '操作未完成，请重试');
    }
  }
}
