# edu 教务协议与页面解析

定位：只负责 Kingo 教务的 HTTP 协议、登录加密和页面解析，只依赖 domain，不访问数据库，也不感知账号。出错时直接抛异常（KingoCallException、FormatException、TimeoutException 或网络异常），由 gateway 层统一转成 GatewayResult。

# 文件职责

- kingo_client.dart：HTTP 客户端 KingoClient。
  - 教务地址 kingoBase 写死为单校地址。统一设置请求头，维护 cookie 罐（jar、pageSession）。
  - 每次请求 25 秒超时，只允许与 base 同源的地址，不跟随重定向。
  - 会话失效的判定：重定向到登录页，或页面内容提示重新登录。非 2xx 响应报 UPSTREAM_HTTP。
  - cancelRequests 作废在途请求，取消后迟到的响应不得改写 cookie；dispose 之后拒绝发起请求。
  - 成绩数据接口按块读取，上限 4MB。
  - 解码：content-type 或页面前 1000 字节声明 GB 系字符集时用 GBK，否则用 UTF-8；UTF-8 解码失败时回退 GBK。
  - 登录流程：
    1. 获取登录页会话。
    2. 获取临时 DES 密钥和时间戳，加密参数后提交。
    3. 需要验证码时拉取验证码图片。
    4. 成功后读取身份信息和学期列表。
  - 取数：个人信息、学期列表（含公开页标注的当前学期）、课表、成绩表单、有效成绩与原始成绩两份、作息。
- kingo_codec.dart：登录加密与签名。登录参数先经 DES 加密，再转码并做 Base64；签名是双重 MD5；另提供课表查询参数用的 Base64。
- kingo_des.dart：移植自教务前端的 DES 实现。strEnc 用于登录，strDec 只在测试中使用。
- login_rules.dart：登录与页面结果判定。
  - explainLogin 把教务状态码和提示映射为 LoginFailure（带 GatewayCode）。
  - explainPage 识别页面里的会话失效。
  - 另含验证码判定与提示文案，以及登录明文的拼装。
- parse_terms.dart：把学期下拉列表的 JSON 解析为 ParsedTerm（学年 xn、学期 xq、名称）。
- parse_schedule.dart：
  - 把课表页 HTML 解析为 ParsedSchedule。
  - 辅助函数：expandWeeks 展开周次表达式与单双周；parseMeetings 解析上课时段文本。
  - 解析失败抛 ScheduleParseException。
- parse_grades.dart：按列名解析成绩页 HTML，包括有效成绩、原始成绩、分类汇总和抬头信息；buildGradeBody 拼装查询表单。
- parse_bells.dart：把作息页 HTML 解析为节次、时段（上午、下午、晚上）和起止时间。页面标题的匹配规则里写死了校名。

# 关键规则

- 只有明确语义才算空：
  - 课表：只有明确的无课提示才视为空。权限、维护等错误不得生成空版本去覆盖本地课表。
  - 成绩：只有明确的无成绩语义才写入空缓存。未知、维护、权限或被截断的页面，不得清空已同步的成绩。
  - 作息：页面必须含作息标题；缺少时间数据时，只有“未设置作息时间”才算空。
- 课表的课程门数按唯一课程代码核对。同一课程可能拆成多个教学班，全部保留。
- 解析失败时抛 FormatException，或抛带 UPSTREAM_FORMAT 的 KingoCallException。网关据此报错，保留已有缓存。
- 日志不写原始 HTML、链接、cookie 或凭据。
- 修改解析规则时：
  - 先在以下测试里加合成样本：test/kingo_client_response_test.dart、test/sync_boundary_regression_test.dart、test/contract_test.dart、test/grades_test.dart。
  - 真实页面只在授权环境下用 tool/verify_edu.dart、tool/verify_grades.dart 手动核对，样本不入库。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/edu
- 本目录的标记位于课表空页判定、多教学班保留、成绩空缓存判定三处。
