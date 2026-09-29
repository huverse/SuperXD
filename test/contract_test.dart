import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:superxd/edu/kingo_codec.dart';
import 'package:superxd/edu/kingo_des.dart';
import 'package:superxd/edu/login_rules.dart';
import 'package:superxd/edu/parse_bells.dart';
import 'package:superxd/edu/parse_grades.dart';
import 'package:superxd/edu/parse_schedule.dart';
import 'package:superxd/edu/parse_terms.dart';
import 'package:superxd/gateway/fixture_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';

void main() {
  test('开学日按所在周的周一计算', () {
    expect(mondayOf('2024-01-03'), '2024-01-01');
    expect(weekIndex('2024-01-03', '2024-01-03'), 1);
    expect(weekIndex('2024-01-03', '2024-01-01'), 1);
    expect(weekIndex('2024-01-03', '2024-01-07'), 1);
    expect(weekIndex('2024-01-03', '2024-01-08'), 2);
    expect(weekIndex('2024-01-03', '2023-12-31'), 0);
    expect(weekRange('2024-01-03', 1).start, '2024-01-01');
    expect(weekRange('2024-01-03', 1).end, '2024-01-07');
  });

  test('自定义课表被教务覆盖前必须确认，回退保留历史', () {
    final term = const TermRef(xn: '2026', xq: '0', label: '2026-2027学年第一学期');
    final store = ScheduleStore();
    final edu = [
      CourseRecord(
        courseCode: 'C1',
        courseName: '高等数学',
        sectionId: 'S1',
        credit: null,
        teacherName: '',
        meetings: [CourseMeeting(weekday: 1, periodStart: 1, periodEnd: 2, place: '知敬楼101', weeks: [1, 2, 3])],
      ),
    ];
    store.commitSync(term, edu, confirm: false, now: '2026-09-23T00:00:00.000Z');
    final edited = edu.map((course) => course.copy()).toList();
    edited[0].meetings[0] = CourseMeeting(weekday: 1, periodStart: 1, periodEnd: 2, place: '知敬楼202', weeks: [1, 2, 3]);
    store.edit(term, edited, '改教室', '2026-09-23T01:00:00.000Z');
    final plan = store.planSync(term, edu);
    expect(plan.conflict, isTrue);
    expect(plan.message, syncOverwriteMessage);
    expect(() => store.commitSync(term, edu, confirm: false, now: '2026-09-23T02:00:00.000Z'), throwsA(isA<ScheduleConflict>()));
    store.commitSync(term, edu, confirm: true, now: '2026-09-23T02:00:00.000Z');
    expect(store.head(term)!.source, 'edu');
    expect(store.head(term)!.courses[0].meetings[0].place, '知敬楼101');
    expect(store.revisionsOf(term), hasLength(3));
    final userRev = store.revisionsOf(term).firstWhere((row) => row.summary == '改教室');
    store.restore(term, userRev.id, '2026-09-23T03:00:00.000Z');
    expect(store.head(term)!.courses[0].meetings[0].place, '知敬楼202');
    final monday = visibleCourses(edu, ScheduleScope.day(term: term, date: '2024-01-01', termStartDate: '2024-01-03'));
    expect(monday, hasLength(1));
    expect(visibleCourses(edu, ScheduleScope.day(term: term, date: '2023-12-31', termStartDate: '2024-01-03')), isEmpty);
  });

  test('登录明文和验证码判断与参照实现一致', () {
    expect(captchaRequired('200', '操作成功!'), isFalse);
    expect(captchaRequired('402', '账号或密码有误!'), isFalse);
    expect(captchaRequired('402', '您1小时内已输错2次密码，若超过8次，您的账号将被锁定！|2'), isTrue);
    expect(captchaRequired('402', '您的账号已被锁定'), isFalse);
    expect(captchaRequired('401', '验证码错误'), isTrue);
    expect(captchaHint('401', '验证码错误'), '验证码不正确，请重新输入');
    expect(captchaHint('402', '您1小时内已输错2次密码，若超过8次，您的账号将被锁定！|2'), contains('已输错2次'));
    expect(explainLogin('402', '账号或密码有误!', '{}').code, 'PASSWORD_WRONG');
    expect(explainLogin('402', '您的账号已被锁定', '{}').code, 'ACCOUNT_LOCKED');
    final plain = buildLoginPlain('20260000001', 'secret-value', 'SESSION', '');
    expect(plain, '_u=MjAyNjAwMDAwMDE7O1NFU1NJT04=&_p=fe89e8eac4b27a7ed47561527e52ac60&randnumber=&isPasswordPolicy=1&txt_mm_expression=5&txt_mm_length=12&txt_mm_userzh=0&hid_flag=1&hidlag=1&hid_dxyzm=');
    final withCode = buildLoginPlain('20260000001', 'secret-value', 'SESSION', 'Ab');
    expect(withCode.startsWith('_uAb='), isTrue);
    expect(withCode, contains('randnumber=Ab'));
    expect(withCode, contains('hid_flag=&'));
    expect(plain == withCode, isFalse);
  });

  test('青果 DES 与参照实现的密文一致', () {
    const cipher = '3B998112B2A67363B44D0045E2FC13D120745DEFBBA6012D';
    expect(strEnc('hello-kingo', 'tempKey', null, null), cipher);
    expect(strDec(cipher, 'tempKey', null, null), 'hello-kingo');
    expect(kingoBase64(utf16To8(cipher)), 'M0I5OTgxMTJCMkE2NzM2M0I0NEQwMDQ1RTJGQzEzRDEyMDc0NURFRkJCQTYwMTJE');
    expect(hexMd5('abc'), '900150983cd24fb0d6963f7d28e17f72');
  });

  test('课表、成绩、作息和学期解析', () {
    final meetings = parseMeetings('3-18周 三[1-2] 知敬楼402室(110)');
    expect(meetings.single.weekday, 3);
    expect(meetings.single.periodStart, 1);
    expect(meetings.single.periodEnd, 2);
    expect(meetings.single.place, '知敬楼402室');
    expect(meetings.single.weeks.first, 3);
    expect(meetings.single.weeks.last, 18);
    final body = buildGradeBody(kind: 'yxcj', xn: '2025', xq: '0', rxnj: '2025', nj: '2025');
    expect(body, contains('zx=1'));
    expect(body, contains('fx=0'));
    expect(body, contains('wz=0'));
    expect(body, contains('ysyx=yxcj'));
    final bells = parseBellsHtml('<tr><td>上午</td><td>1</td><td>08:00</td><td>08:45</td></tr>');
    expect(bells.periods.single.dayPartCode, 'morning');
    expect(bells.empty, isFalse);
    expect(parseBellsHtml('未设置作息时间').empty, isTrue);
    final terms = parseTerms([
      {'code': '2026-0', 'name': '2026-2027学年第一学期'},
    ]);
    expect(terms.single.xn, '2026');
    expect(terms.single.xq, '0');
    expect(parsePublicCurrent('<input id="xn" value="2026"><input id="xq_m" value="0">')?.xn, '2026');
  });

  test('页面通过夹具网关读取课表，不访问教务', () async {
    final gateway = FixtureCampusGateway(readText: (name) => File('assets/fixtures/$name').readAsString());
    final terms = await gateway.listTerms();
    final schedule = await gateway.syncSchedule(terms.data!.first);
    expect(schedule.ok, isTrue);
    expect(schedule.data!.courses, isNotEmpty);
    expect(schedule.data!.student.loginId, '20260000001');
    final grades = await gateway.syncGrades(const TermRef(xn: '2025', xq: '0'));
    expect(grades.data!.summary!.gpa, 3.0);
    final emptyGrades = await gateway.syncGrades(const TermRef(xn: '1999', xq: '0'));
    expect(emptyGrades.data!.empty, isTrue);
    expect(emptyGrades.ok, isTrue);
    final bells = await gateway.syncBells(const TermRef(xn: '2025', xq: '0'));
    expect(bells.data!.periods.first.start, '08:00');
  });
}
