import Flutter
import Photos
import QuickLook
import UIKit

// 百宝箱下载的导出、一次性导出（图片与诊断日志包）与打开，对应安卓 ToolboxFileExporter.kt（通道 superxd/toolbox_files）。
// [人工决策-2026-10-26 20:27:41] iOS 没有公共的 Download 文件夹（用户选定）：图片与视频存进系统相册，只申请「添加到相册」；
// 相册收不下的（音频、webm 等视频格式）放进「文件」App › 我的 iPhone › SuperXD（应用的 Documents，数据库不在这里，见 main.dart）；诊断日志包弹系统分享面板。
final class ToolboxFileExporter: NSObject, QLPreviewControllerDataSource {
  private static let extensions = [
    "video/mp4": "mp4", "video/webm": "webm", "video/quicktime": "mov", "video/x-matroska": "mkv", "video/x-msvideo": "avi",
    "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif",
    "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/aac": "aac", "audio/ogg": "ogg", "audio/wav": "wav",
    "application/zip": "zip",
  ]
  // 一次性导出只有图片（人脸照片、驿站码等）与诊断日志包（zip），不开放视频音频。
  private static let externalMimes: Set<String> = ["image/jpeg", "image/png", "image/webp", "application/zip"]
  // 系统相册收得下的格式；webp 先转成 JPEG 再存。
  private static let photoMimes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]
  private static let videoMimes: Set<String> = ["video/mp4", "video/quicktime"]
  private static let externalName = try! NSRegularExpression(pattern: "^[^./\\\\:\\p{Cc}][^/\\\\:\\p{Cc}]{0,63}$")
  private let worker = DispatchQueue(label: "superxd.toolbox-files", qos: .userInitiated)
  private var previewing: URL?

  func register(messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "superxd/toolbox_files", binaryMessenger: messenger).setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any] ?? [:]
    do {
      switch call.method {
      case "publish":
        let source = try Self.file(arguments["source"], inside: Self.supportDirectory().appendingPathComponent("toolbox/downloads"))
        guard let id = arguments["id"] as? String, id.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil,
              let filename = arguments["filename"] as? String,
              filename.range(of: "^SuperXD_\(NSRegularExpression.escapedPattern(for: id))\\.(mp4|webm|mov|mkv|avi|jpg|png|webp|gif|mp3|m4a|aac|ogg|wav)$", options: .regularExpression) != nil,
              let mime = arguments["mimeType"] as? String, Self.extensions[mime] == (filename as NSString).pathExtension
        else { throw ExportError.invalid }
        export(source, filename: filename, mime: mime, result: result)
      // 一次性导出：来源只认应用缓存目录（Dart 侧的临时文件就在这里），不能拿它把应用私有的库、密钥或配置导出去。
      case "publishExternal":
        let source = try Self.file(arguments["source"], inside: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
        guard let filename = arguments["filename"] as? String, filename.contains("."),
              Self.externalName.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) != nil,
              let mime = arguments["mimeType"] as? String, Self.externalMimes.contains(mime), Self.extensions[mime] == (filename as NSString).pathExtension
        else { throw ExportError.invalid }
        if mime == "application/zip" {
          share(source, filename: filename, result: result)
        } else {
          export(source, filename: filename, mime: mime, result: result)
        }
      case "open":
        guard let text = arguments["uri"] as? String, let uri = URL(string: text) else { throw ExportError.invalid }
        try open(uri)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      NSLog("[ToolboxFiles] action=%@ errorType=%@", call.method, String(describing: type(of: error)))
      result(FlutterError(code: "FILE_OPERATION", message: "文件操作未完成", details: nil))
    }
  }

  private func export(_ source: URL, filename: String, mime: String, result: @escaping FlutterResult) {
    if Self.photoMimes.contains(mime) || Self.videoMimes.contains(mime) {
      saveToPhotos(source, filename: filename, mime: mime, result: result)
    } else {
      worker.async {
        do {
          let target = try Self.saveToDocuments(source, filename: filename)
          DispatchQueue.main.async { result(target.absoluteString) }
        } catch {
          NSLog("[ToolboxFiles] action=save_document errorType=%@", String(describing: type(of: error)))
          DispatchQueue.main.async { result(FlutterError(code: "SAVE_FAILED", message: "保存失败，请重试", details: nil)) }
        }
      }
    }
  }

  // 只申请「添加到相册」：读不到用户的其他照片。返回 ph:// 加相册条目号，打开时进系统相册。
  private func saveToPhotos(_ source: URL, filename: String, mime: String, result: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { [worker] status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async { result(FlutterError(code: "PHOTOS_DENIED", message: "没有添加到相册的权限，请在系统设置里允许", details: nil)) }
        return
      }
      worker.async {
        // 交给相册的文件放进临时目录下的一个文件夹，存完（成败都）连夹删掉。
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
          try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
          var name = filename
          let file: URL
          if mime == "image/webp" {
            guard let data = UIImage(contentsOfFile: source.path)?.jpegData(compressionQuality: 0.95) else { throw ExportError.invalid }
            name = (filename as NSString).deletingPathExtension + ".jpg"
            file = staging.appendingPathComponent(name)
            try data.write(to: file, options: .atomic)
          } else {
            // 下载的临时文件扩展名是 .part，相册按文件扩展名认资源：只用 uniformTypeIdentifier 指明类型照样报
            // PHPhotosErrorDomain 3302（资源无效，10-28 iPhone 日志）。换成带正确扩展名的文件名再交出去：
            // 同一个应用容器里硬链接不复制数据，大视频也是瞬间；系统不让链接时退回复制。
            file = staging.appendingPathComponent(filename)
            do {
              try FileManager.default.linkItem(at: source, to: file)
            } catch {
              try FileManager.default.copyItem(at: source, to: file)
            }
          }
          var placeholder: PHObjectPlaceholder?
          try PHPhotoLibrary.shared().performChangesAndWait {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = name
            request.addResource(with: Self.videoMimes.contains(mime) ? .video : .photo, fileURL: file, options: options)
            placeholder = request.placeholderForCreatedAsset
          }
          let identifier = placeholder?.localIdentifier ?? ""
          DispatchQueue.main.async { result("ph://\(identifier)") }
        } catch {
          // 系统错误域与错误号交回 Dart 记进本机日志（NSLog 只进系统控制台，用户导不出来）。
          let failure = error as NSError
          NSLog("[ToolboxFiles] action=save_photo errorType=%@ code=%ld", failure.domain, failure.code)
          DispatchQueue.main.async { result(FlutterError(code: "SAVE_FAILED", message: "保存失败，请重试", details: "\(failure.domain) \(failure.code)")) }
        }
      }
    }
  }

  // 文件名是幂等键（同安卓）：已有同名的直接算存好，先写临时文件再挪过去，不留半个文件。
  private static func saveToDocuments(_ source: URL, filename: String) throws -> URL {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let target = documents.appendingPathComponent(filename)
    if FileManager.default.fileExists(atPath: target.path) { return target }
    let partial = documents.appendingPathComponent(".\(filename).partial")
    try? FileManager.default.removeItem(at: partial)
    try FileManager.default.copyItem(at: source, to: partial)
    try FileManager.default.moveItem(at: partial, to: target)
    return target
  }

  // 日志包：复制成要给出去的文件名再弹分享面板，面板关掉就删副本；用户取消返回空（Dart 侧按「没完成」提示）。
  private func share(_ source: URL, filename: String, result: @escaping FlutterResult) {
    do {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let copy = folder.appendingPathComponent(filename)
      try FileManager.default.copyItem(at: source, to: copy)
      guard let presenter = UIApplication.shared.topViewController else { throw ExportError.noWindow }
      let controller = UIActivityViewController(activityItems: [copy], applicationActivities: nil)
      controller.popoverPresentationController?.sourceView = presenter.view
      controller.completionWithItemsHandler = { _, completed, _, _ in
        try? FileManager.default.removeItem(at: folder)
        result(completed ? copy.absoluteString : nil)
      }
      presenter.present(controller, animated: true)
    } catch {
      NSLog("[ToolboxFiles] action=share errorType=%@", String(describing: type(of: error)))
      result(FlutterError(code: "FILE_OPERATION", message: "文件操作未完成", details: nil))
    }
  }

  // 相册里的条目打开系统相册；「文件」里的用快速查看在应用里预览。
  private func open(_ uri: URL) throws {
    if uri.scheme == "ph" {
      guard let photos = URL(string: "photos-redirect://") else { throw ExportError.invalid }
      UIApplication.shared.open(photos)
      return
    }
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.path
    guard uri.isFileURL, uri.standardizedFileURL.path.hasPrefix(documents + "/"), let presenter = UIApplication.shared.topViewController else { throw ExportError.invalid }
    previewing = uri
    let preview = QLPreviewController()
    preview.dataSource = self
    presenter.present(preview, animated: true)
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewing == nil ? 0 : 1 }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { previewing! as NSURL }

  private static func supportDirectory() -> URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

  private static func file(_ value: Any?, inside root: URL) throws -> URL {
    guard let path = value as? String else { throw ExportError.invalid }
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard file.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"), FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { throw ExportError.invalid }
    return file
  }
}

enum ExportError: Error {
  case invalid
  case noWindow
}
