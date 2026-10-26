import Flutter
import Foundation
import MetricKit

// 上次进程为什么结束，对应安卓 ProcessExitReasons.kt（通道 superxd/diagnostics）。iOS 没有 ApplicationExitInfo，改用 MetricKit 的诊断报告：
// 崩溃记 CRASH、卡死记 ANR（Dart 侧 app_diagnostics.dart 都按异常结束记错误），CPU 与写盘超限记 EXCESSIVE_RESOURCE_USAGE 且按后台算（只在开发者模式下记）。
// 报告由系统在之后的某次启动交来（不一定是下一次），先存进 device_only/exit_reasons.json，Dart 按时刻取上回之后的；只留最近 exitLimit 条。
final class ProcessExitReasons: NSObject, MXMetricManagerSubscriber {
  private static let exitLimit = 20
  private static let traceLimit = 8 * 1024
  // 安卓的进程重要度口径：前台 100，看不见的后台 400。
  private static let foreground = 100
  private static let background = 400
  private let worker = DispatchQueue(label: "superxd.diagnostics")
  private let store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("device_only/exit_reasons.json")

  func register(messenger: FlutterBinaryMessenger) {
    MXMetricManager.shared.add(self)
    FlutterMethodChannel(name: "superxd/diagnostics", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "exitReasons" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let since = (call.arguments as? [String: Any])?["since"] as? Int ?? 0
      self.worker.async {
        let exits = self.load().filter { ($0["timestamp"] as? Int ?? 0) > since }
        DispatchQueue.main.async { result(exits) }
      }
    }
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    worker.async {
      var exits = self.load()
      for payload in payloads {
        let timestamp = Int(payload.timeStampEnd.timeIntervalSince1970 * 1000)
        for crash in payload.crashDiagnostics ?? [] {
          let description = "exceptionType=\(crash.exceptionType?.stringValue ?? "-") exceptionCode=\(crash.exceptionCode?.stringValue ?? "-") signal=\(crash.signal?.stringValue ?? "-") termination=\(crash.terminationReason ?? "-")"
          exits.append(Self.exit(timestamp, "CRASH", status: crash.signal?.intValue ?? 0, importance: Self.foreground, description: description, tree: crash.callStackTree))
        }
        for hang in payload.hangDiagnostics ?? [] {
          exits.append(Self.exit(timestamp, "ANR", status: 0, importance: Self.foreground, description: "hangDuration=\(hang.hangDuration)", tree: hang.callStackTree))
        }
        for cpu in payload.cpuExceptionDiagnostics ?? [] {
          exits.append(Self.exit(timestamp, "EXCESSIVE_RESOURCE_USAGE", status: 0, importance: Self.background, description: "cpuTime=\(cpu.totalCPUTime)", tree: cpu.callStackTree))
        }
        for disk in payload.diskWriteExceptionDiagnostics ?? [] {
          exits.append(Self.exit(timestamp, "EXCESSIVE_RESOURCE_USAGE", status: 0, importance: Self.background, description: "writes=\(disk.totalWritesCaused)", tree: disk.callStackTree))
        }
      }
      exits.sort { ($0["timestamp"] as? Int ?? 0) < ($1["timestamp"] as? Int ?? 0) }
      self.save(Array(exits.suffix(Self.exitLimit)))
    }
  }

  private static func exit(_ timestamp: Int, _ reason: String, status: Int, importance: Int, description: String, tree: MXCallStackTree) -> [String: Any] {
    var trace = String(decoding: tree.jsonRepresentation(), as: UTF8.self)
    if trace.utf8.count > traceLimit { trace = String(decoding: Data(trace.utf8.prefix(traceLimit)), as: UTF8.self) }
    return ["timestamp": timestamp, "reason": reason, "status": status, "importance": importance, "pssKb": 0, "rssKb": 0, "description": description, "trace": trace]
  }

  // 存的是自己写的文件，读坏了当没有记录。
  private func load() -> [[String: Any]] {
    guard let data = try? Data(contentsOf: store), let exits = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return exits
  }

  private func save(_ exits: [[String: Any]]) {
    do {
      try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: exits).write(to: store, options: .atomic)
    } catch {
      NSLog("[Diagnostics] action=save_exits errorType=%@", String(describing: type(of: error)))
    }
  }
}
