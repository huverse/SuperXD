// 网关错误码登记表：页面与同步编排只按错误码分支，message只供展示；新增错误码先在此登记，测试保留字面量钉住取值。
abstract final class GatewayCode {
  // 教务登录接口返回成功，只在登录规则内部判断
  static const ok = 'OK';
  // 教务页面提示未设置作息，只在登录规则内部判断
  static const empty = 'EMPTY';
  // 教务会话失效：清除会话后自动恢复一次，仍失效则转人工登录
  static const sessionExpired = 'SESSION_EXPIRED';
  // 登录失败的兜底原因
  static const loginFailed = 'LOGIN_FAILED';
  // 同一次登录仍在处理，拒绝并发提交
  static const loginBusy = 'LOGIN_BUSY';
  // 教务没有返回登录结果
  static const serverUnavailable = 'SERVER_UNAVAILABLE';
  // 教务要求短信验证，转人工
  static const smsRequired = 'SMS_REQUIRED';
  // 需要填写验证码或验证码错误
  static const captchaRequired = 'CAPTCHA_REQUIRED';
  // 账号或密码错误：自动登录遇到时删除保存的凭据
  static const passwordWrong = 'PASSWORD_WRONG';
  // 密码已输错多次：自动登录遇到时删除保存的凭据
  static const passwordWrongCount = 'PASSWORD_WRONG_COUNT';
  // 账号已锁定：自动登录遇到时删除保存的凭据
  static const accountLocked = 'ACCOUNT_LOCKED';
  // 教务拒绝登录的账号状态
  static const accountState = 'ACCOUNT_STATE';
  // 账号已切换或登录被取消，旧结果作废
  static const accountChanged = 'ACCOUNT_CHANGED';
  // 自动登录取得的身份与保存的账号不一致
  static const accountMismatch = 'ACCOUNT_MISMATCH';
  // 教务来源地址变化，需要重新登录
  static const accountSourceChanged = 'ACCOUNT_SOURCE_CHANGED';
  // 教务返回格式无法识别，保留已有缓存
  static const upstreamFormat = 'UPSTREAM_FORMAT';
  // 教务返回非成功的HTTP状态
  static const upstreamHttp = 'UPSTREAM_HTTP';
  // 教务请求超时
  static const networkTimeout = 'NETWORK_TIMEOUT';
  // 教务连接失败
  static const networkFailed = 'NETWORK_FAILED';
  // 教务提示请求太过频繁（跳转406页）：本轮同步立即停止，稍后再同步，不自动重试
  static const rateLimited = 'RATE_LIMITED';
  // 另一项教务同步进行中
  static const syncBusy = 'SYNC_BUSY';
  // 本地自定义课表须经确认才能被教务版本替换
  static const syncConflict = 'SYNC_CONFLICT';
  // 按天读取课表缺少开学日
  static const termStartRequired = 'TERM_START_REQUIRED';
  // 开学日格式无效
  static const invalidDate = 'INVALID_DATE';
  // 课表内容未通过校验
  static const invalidSchedule = 'INVALID_SCHEDULE';
  // 课表已有更新的版本，拒绝覆盖
  static const revisionConflict = 'REVISION_CONFLICT';
  // 历史版本已清理或不属于该学期
  static const revisionMissing = 'REVISION_MISSING';
  // 所选作息来源没有可用时间，原选择不变
  static const bellsSourceInvalid = 'BELLS_SOURCE_INVALID';
  // 成绩数据未通过边界校验，保留原成绩
  static const gradeDataInvalid = 'GRADE_DATA_INVALID';
  // 旧版本数据导入未完成，已有数据未被覆盖
  static const legacyImportFailed = 'LEGACY_IMPORT_FAILED';
  // 本地数据库读写失败
  static const localStorageFailed = 'LOCAL_STORAGE_FAILED';
  // 未归类的操作失败兜底
  static const operationFailed = 'OPERATION_FAILED';
}
