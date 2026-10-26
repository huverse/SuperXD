import Flutter
import QuickLook
import UIKit

// 把导出的 .ics 交给日历，对应安卓 CalendarExporter.kt（通道 superxd/calendar_export）。iOS 没有「用日历打开」：
// 用快速查看预览这份日历，里面有「全部添加」导入系统日历；只接受缓存 calendar_export 文件夹里的 .ics，文件留到下次导出时由 Dart 侧清空。
final class CalendarExporter: NSObject, QLPreviewControllerDataSource {
  private var previewing: URL?

  func register(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "superxd/calendar_export", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      guard let self, call.method == "open" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("calendar_export").resolvingSymlinksInPath()
      guard let path = (call.arguments as? [String: Any])?["path"] as? String,
            case let file = URL(fileURLWithPath: path).resolvingSymlinksInPath(),
            file.deletingLastPathComponent().path == root.path, file.pathExtension == "ics", FileManager.default.fileExists(atPath: file.path),
            let presenter = UIApplication.shared.topViewController
      else {
        NSLog("[CalendarExport] action=open errorType=invalid")
        result(FlutterError(code: "CALENDAR_EXPORT", message: "无法打开日历", details: nil))
        return
      }
      self.previewing = file
      let preview = QLPreviewController()
      preview.dataSource = self
      presenter.present(preview, animated: true)
      result("preview")
    }
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewing == nil ? 0 : 1 }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { previewing! as NSURL }
}
