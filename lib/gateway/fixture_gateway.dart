import 'dart:convert';
import 'dart:developer' as developer;

import 'package:superxd/gateway/campus_gateway.dart';
import 'package:superxd/local/schedule_store.dart';
import 'package:superxd/local/period_spans.dart';
import 'package:superxd/local/schedule_edit.dart';
import 'package:superxd/local/grades.dart' as grades;

class FixtureCampusGateway implements CampusGateway {
  FixtureCampusGateway({required this.readText, DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Future<String> Function(String name) readText;
  final DateTime Function() _now;
  final ScheduleStore _store = ScheduleStore();
  final Map<String, TermRef> _bellsSources = {};
  SessionView? _student;

  @override
  Future<GatewayResult<List<TermRef>>> syncTerms() => listTerms();

  @override
  Future<GatewayResult<TermRef?>> readBellsSource(TermRef term) async {
    return _ok(_bellsSources[term.key], source: 'local', fetchedAt: _stamp());
  }

  @override
  Future<GatewayResult<TermRef>> useBellsSource(TermRef target, TermRef source) async {
    final raw = await syncBells(source);
    if (raw.data?.periods.isNotEmpty != true) return _fail('BELLS_SOURCE_INVALID', '这套作息没有可用时间，原选择保持不变');
    if (target.key == source.key) {
      _bellsSources.remove(target.key);
    } else {
      _bellsSources[target.key] = source;
    }
    return _ok(source, source: 'user', fetchedAt: _stamp());
  }

  @override
  Future<GatewayResult<SessionView>> restoreSession() async {
    final schedule = await _schedule();
    _student = schedule.student;
    return _ok(schedule.student, source: 'local', fetchedAt: schedule.fetchedAt);
  }

  @override
  Future<GatewayResult<LoginView>> login(String account, String password) async {
    final schedule = await _schedule();
    _student = schedule.student;
    return _ok(
      LoginView(session: schedule.student),
      source: 'local',
      fetchedAt: schedule.fetchedAt,
    );
  }

  @override
  Future<GatewayResult<LoginView>> submitLoginCaptcha(String code) async {
    return _fail('LOGIN_FAILED', '夹具没有验证码');
  }

  @override
  Future<GatewayResult<CaptchaView>> refreshLoginCaptcha() async {
    return _fail('LOGIN_FAILED', '夹具没有验证码');
  }

  @override
  Future<GatewayResult<List<TermRef>>> listTerms() async {
    final schedule = await _schedule();
    final grades = await _grades();
    final bells = await _bells();
    final terms = <String, TermRef>{};
    for (final term in [schedule.view.term, grades.view.term, bells.view.term]) {
      terms.putIfAbsent(term.key, () => term);
    }
    return _ok(terms.values.toList(), source: 'local', fetchedAt: schedule.fetchedAt);
  }

  @override
  Future<GatewayResult<ScheduleView>> syncSchedule(TermRef term) async {
    final schedule = await _schedule();
    if (schedule.view.term.key != term.key) {
      return _ok(
        ScheduleView(term: term, student: schedule.student, courses: const [], empty: true, message: '教务系统没有课表'),
        source: 'local',
        fetchedAt: schedule.fetchedAt,
      );
    }
    final plan = _store.planSync(term, schedule.view.courses);
    if (plan.action == 'insert') {
      _store.commitSync(term, schedule.view.courses, confirm: false, now: schedule.fetchedAt);
    }
    _student = schedule.student;
    return _ok(schedule.view, source: 'local', fetchedAt: schedule.fetchedAt);
  }

  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async {
    final schedule = await _schedule();
    if (_store.head(scope.term) == null && scope.term.key == schedule.view.term.key) {
      _store.commitSync(scope.term, schedule.view.courses, confirm: false, now: schedule.fetchedAt);
    }
    final head = _store.head(scope.term);
    final courses = head?.courses ?? const <CourseRecord>[];
    final given = scope.termStartDate;
    final start = given != null && given.isNotEmpty ? given : _store.termStart(scope.term);
    final resolved = scope.kind == 'day'
        ? ScheduleScope.day(term: scope.term, date: scope.date ?? '', termStartDate: start ?? '')
        : scope;
    try {
      final visible = visibleCourses(courses, resolved);
      return _ok(
        ScheduleView(term: scope.term, student: _student ?? schedule.student, courses: visible, termLastPeriod: maxCoursePeriod(courses), termStartDate: _store.termStart(scope.term), revisionId: head?.id, message: head == null ? '还没有课表' : ''),
        source: head?.source ?? 'local',
        fetchedAt: head?.createdAt ?? schedule.fetchedAt,
      );
    } on StateError catch (error) {
      return _fail('TERM_START_REQUIRED', error.message);
    }
  }

  @override
  Future<GatewayResult<GradesView>> readGrades(TermRef term) => syncGrades(term);

  @override
  Future<GatewayResult<List<GradeTermOverview>>> readGradeYear(String year) async {
    final terms = (await listTerms()).data!.where((term) => term.xn == year).toList();
    final results = await Future.wait(terms.map(readGrades));
    return _ok([for (var index = 0; index < terms.length; index++) GradeTermOverview(term: terms[index], cached: results[index].data!.cached, empty: results[index].data!.empty, summary: results[index].data!.summary, summaryScope: results[index].data!.summaryScope, fetchedAt: results[index].fetchedAt, effectiveCount: results[index].data!.effective.length, originalCount: results[index].data!.original.length)], source: 'local', fetchedAt: _stamp());
  }

  @override
  Future<GatewayResult<GradesView>> syncGrades(TermRef term) async {
    final grades = await _grades();
    if (grades.view.term.key == term.key) {
      return _ok(grades.view, source: 'local', fetchedAt: grades.fetchedAt);
    }
    final empty = await _gradesEmpty();
    return _ok(
      GradesView(
        empty: true,
        message: empty.view.message,
        term: term,
        student: grades.view.student,
        summary: null,
        effective: const [],
        original: const [],
      ),
      source: 'local',
      fetchedAt: empty.fetchedAt,
    );
  }

  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) async {
    final source = _bellsSources[term.key] ?? term;
    final raw = await syncBells(source);
    final data = raw.data!;
    return _ok(BellsView(empty: data.empty, message: data.message, term: term, periods: data.periods, sourceTerm: source), source: 'local', fetchedAt: raw.fetchedAt);
  }

  @override
  Future<GatewayResult<BellsView>> syncBells(TermRef term) async {
    final bells = await _bells();
    if (bells.view.term.key == term.key) {
      return _ok(bells.view, source: 'local', fetchedAt: bells.fetchedAt);
    }
    final empty = await _bellsEmpty();
    return _ok(
      BellsView(empty: true, message: empty.view.message, term: term, periods: const []),
      source: 'local',
      fetchedAt: empty.fetchedAt,
    );
  }

  @override
  Future<GatewayResult<TermRef>> setTermStart(TermRef term, String date) async {
    try {
      final saved = _store.setTermStart(term, date);
      return _ok(saved, source: 'user', fetchedAt: _stamp());
    } on FormatException catch (error) {
      return _fail('INVALID_DATE', error.message);
    }
  }

  @override
  Future<GatewayResult<RevisionView>> saveScheduleRevision(TermRef term, List<CourseRecord> courses, String summary, {required String? expectedRevisionId}) async {
    if (_store.head(term)?.id != expectedRevisionId) return _fail('REVISION_CONFLICT', const RevisionConflict().message);
    final normalized = normalizeSchedule(courses);
    try { validateSchedule(normalized); } on ScheduleValidation catch (error, stack) { developer.log('[ScheduleFixture] action=validate', error: error, stackTrace: stack); return _fail('INVALID_SCHEDULE', error.message); }
    final row = _store.edit(term, normalized, summary, _stamp());
    return _ok(_revision(row), source: row.source, fetchedAt: row.createdAt);
  }

  @override
  Future<GatewayResult<SyncPlan>> planScheduleSync(TermRef term, List<CourseRecord> courses) async {
    return _ok(_store.planSync(term, courses), source: 'local', fetchedAt: _stamp());
  }

  @override
  Future<GatewayResult<RevisionView>> commitScheduleSync(TermRef term, List<CourseRecord> courses, {required bool confirm, String? expectedRevisionId}) async {
    if (confirm && _store.head(term)?.id != expectedRevisionId) return _fail('REVISION_CONFLICT', const RevisionConflict().message);
    try {
      final row = _store.commitSync(term, courses, confirm: confirm, now: _stamp());
      if (row == null) return _fail('SYNC_FAILED', '没有可提交的课表');
      return _ok(_revision(row), source: 'edu', fetchedAt: row.createdAt);
    } on ScheduleConflict catch (error) {
      return _fail(error.code, error.plan.message ?? syncOverwriteMessage);
    }
  }

  @override
  Future<GatewayResult<List<RevisionView>>> listScheduleRevisions(TermRef term, {int? beforeSequence, int limit = 20}) async {
    final rows = _store.revisionsOf(term).reversed.where((row) => beforeSequence == null || row.sequence < beforeSequence).take(limit.clamp(1, 100)).map(_revision).toList();
    return _ok(rows, source: 'local', fetchedAt: _stamp());
  }

  @override
  Future<GatewayResult<ScheduleRevision>> readScheduleRevision(TermRef term, String id) async {
    final row = _store.revisionsOf(term).where((row) => row.id == id).firstOrNull;
    return row == null ? _fail('REVISION_MISSING', '版本已清理或不属于此学期') : _ok(row, source: row.source, fetchedAt: row.createdAt);
  }

  @override
  Future<GatewayResult<RevisionView>> restoreScheduleRevision(TermRef term, String id, {required String? expectedRevisionId}) async {
    if (_store.head(term)?.id != expectedRevisionId) return _fail('REVISION_CONFLICT', const RevisionConflict().message);
    try {
      final row = _store.restore(term, id, _stamp());
      return _ok(_revision(row), source: row.source, fetchedAt: row.createdAt);
    } on StateError catch (error) {
      return _fail('REVISION_MISSING', error.message);
    }
  }

  Future<({ScheduleView view, String fetchedAt, SessionView student})> _schedule() async {
    final json = await _read('schedule.json');
    final data = _map(json['data']);
    final term = TermRef.fromJson(_map(data['term']));
    final student = _studentOf(_map(data['student']));
    return (
      view: ScheduleView(term: term, student: student, courses: coursesFromJson(data['courses'])),
      fetchedAt: json['fetchedAt'] as String,
      student: student,
    );
  }

  Future<({GradesView view, String fetchedAt})> _grades() => _readGrades('grades.json');
  Future<({GradesView view, String fetchedAt})> _gradesEmpty() => _readGrades('grades.empty.json');

  Future<({GradesView view, String fetchedAt})> _readGrades(String name) async {
    final json = await _read(name);
    final data = _map(json['data']);
    return (
      view: grades.gradesFromJson(data, TermRef.fromJson(_map(data['term']))),
      fetchedAt: json['fetchedAt'] as String,
    );
  }

  Future<({BellsView view, String fetchedAt})> _bells() => _readBells('bells.json');
  Future<({BellsView view, String fetchedAt})> _bellsEmpty() => _readBells('bells.empty.json');

  Future<({BellsView view, String fetchedAt})> _readBells(String name) async {
    final json = await _read(name);
    final data = _map(json['data']);
    final periods = (data['periods'] as List<dynamic>? ?? const []).map((item) {
      final period = _map(item);
      return BellPeriod(
        period: period['period'] as int,
        dayPart: period['dayPart'] as String? ?? '',
        dayPartCode: period['dayPartCode'] as String? ?? '',
        start: period['start'] as String? ?? '',
        end: period['end'] as String? ?? '',
      );
    }).toList();
    return (
      view: BellsView(
        empty: data['empty'] == true,
        message: data['message'] as String? ?? '',
        term: TermRef.fromJson(_map(data['term'])),
        periods: periods,
      ),
      fetchedAt: json['fetchedAt'] as String,
    );
  }

  Future<Map<String, Object?>> _read(String name) async {
    return _map(jsonDecode(await readText(name)));
  }

  Map<String, Object?> _map(Object? value) => (value as Map).cast<String, Object?>();

  SessionView _studentOf(Map<String, Object?> json) {
    return SessionView(
      loginId: json['loginId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      className: json['className'] as String? ?? '',
    );
  }

  RevisionView _revision(ScheduleRevision row) {
    return RevisionView(id: row.id, source: row.source, createdAt: row.createdAt, summary: row.summary, sequence: row.sequence, operation: row.operation, restoredFromId: row.restoredFromId, current: _store.heads[row.termKey] == row.id);
  }

  String _stamp() => _now().toUtc().toIso8601String();

  GatewayResult<T> _ok<T>(T data, {required String source, required String fetchedAt}) {
    return GatewayResult(ok: true, source: source, fetchedAt: fetchedAt, data: data);
  }

  GatewayResult<T> _fail<T>(String code, String message) {
    return GatewayResult(
      ok: false,
      source: 'local',
      fetchedAt: _stamp(),
      error: GatewayError(code: code, message: message),
    );
  }
}
