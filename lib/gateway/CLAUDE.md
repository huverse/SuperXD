# gateway 网关

定位：把教务协议（edu）和本地存储（local）组合成 domain 端口 CampusGateway 的实现，并管理账号生命周期。依赖 domain、edu、local。对上层一律返回 GatewayResult；内部异常都在这一层按类型转换成 GatewayCode。

# 文件职责

- account_access.dart：账号生命周期接口 AccountAccess。
  - 继承 ChangeNotifier，并实现 CampusGateway。
  - 提供代次 generation、当前会话与身份、记住账号、登出与会话过期、旧库导入状态。
  - 页面和 AppSession 只依赖这个接口。
- account_gateway.dart：AccountAccess 的实现 AccountGateway。这个门面只负责选中固定的账号上下文。
  - 活动上下文包含身份、会话和该账号专属的 KingoCampusGateway。
    - 业务调用经 _dispatch 转发，并记录在途请求数。
    - 账号变化后，迟到的调用返回 ACCOUNT_CHANGED。
  - 切换锁：登录落定、退出、会话过期、旧库导入和关闭都在同一把锁里执行。切换前，旧上下文先停止接收请求，并等在途请求全部结束。
  - 登录：
    - 每次尝试都新建一个 KingoAuth 和一个客户端，用尝试编号（epoch）防止旧尝试回写。
    - 成功后依次写会话、激活账号索引，再按用户选择写入或删除凭据。任何一步失败都回滚到原值。
  - 启动恢复：
    1. 先用本地会话恢复。
    2. 失败且保存了凭据时，自动登录一次。
    3. 自动登录遇到密码错误、错误次数超限或账号锁定时，删除凭据。
    4. 需要验证码或其他失败时，转人工登录，并清除活动账号指针。
  - 同步中会话失效：
    - 保存了凭据时，自动重新登录，再重放这次请求；并发请求共用同一次恢复。
    - 恢复失败或重放后仍失效，该上下文不再自动恢复。
  - 登录成功、会话恢复成功、退出和导入完成时，代次 generation 都会加一。
- kingo_auth.dart：一次登录的暂态 KingoAuth。
  - 账号密码只在本次认证过程中暂存；提交验证码时沿用同一个会话。
  - 用 epoch 和 busy 标记防止并发提交与迟到回写。
  - persistSession 把会话和学期写入账号库。固定账号网关和切换门面共用这一个方法。
- kingo_campus_gateway.dart：固定账号的 CampusGateway 实现 KingoCampusGateway。
  - 读操作只读本地库，例如 readSchedule、readGrades、readGradeYear、readBells。
  - 同步操作访问教务网络：syncTerms、syncSchedule、syncGrades、syncBells。成绩同步与其他网络同步互斥，冲突时返回 SYNC_BUSY。
  - syncSchedule：发现本地有自定义版本时不写入，只返回确认文案；用户确认后由 planScheduleSync、commitScheduleSync 提交。
  - syncGrades：
    - 两份成绩页的抬头学号和学期都必须一致。
    - 学校的空成绩页没有抬头。此时要求两份都明确为空，并重新核对会话身份；已有非空缓存时不覆盖。
    - 只展示教务明确给出的“合计”，不自行推算。
  - useBellsSource：只能采用某学期的原始缓存，而且时间必须完整有效。
  - _guard 把异常映射为错误码：
    - GradeDataException → GRADE_DATA_INVALID
    - RevisionConflict → REVISION_CONFLICT
    - ScheduleConflict → SYNC_CONFLICT
    - ScheduleValidation → INVALID_SCHEDULE
    - KingoCallException → 异常自带的错误码；会话失效时同时清除会话和 cookie
    - 超时 → NETWORK_TIMEOUT
    - 格式异常 → UPSTREAM_FORMAT
    - 网络异常 → NETWORK_FAILED
    - 数据库异常 → LOCAL_STORAGE_FAILED
    - 其他异常 → OPERATION_FAILED

# 关键规则

- 新增 CampusGateway 方法的步骤：
  1. 在 domain 端口里加方法签名。
  2. 在 KingoCampusGateway 里实现。
  3. 在 AccountGateway 里经 _dispatch 转发；需要会话恢复的网络同步传 recover: true。
  4. 补齐 test/fixture_campus_gateway.dart 和各测试替身。
- 任何异常都不得穿出网关。新的失败类型先在 domain/gateway_code.dart 登记。
- 旧上下文的迟到结果一律丢弃（返回 ACCOUNT_CHANGED），不得写入新账号的库，也不得改动新会话。
- 登录密码只在 KingoAuth 里暂存到认证结束。认证成功后，只有用户选择了记住账号，才交给 CredentialStore。

# 人工决策检索

- 命令：grep -rn 人工决策- lib/gateway
- 本目录的标记位于以下几处：
  - 成绩空页的接收条件
  - 只展示教务合计
  - 作息来源只引用原始缓存
