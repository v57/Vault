import ComponentKit
import PlatformScan
import SwiftUI
import UniformTypeIdentifiers
import VaultKit

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Vault's share extension. The system starts it from a share sheet; it reads the PDFs and pictures shared, saves
/// them to the Inbox of this device's vault (encrypted, like every record) and ends. It reads no text on the pages
/// (the app does, with more memory) and sends nothing.
final class ShareViewController: PlatformViewController {
  private let model = ShareModel()

  #if os(macOS)
    override func loadView() {
      view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 300))
    }
  #endif

  override func viewDidLoad() {
    super.viewDidLoad()
    model.cancel = { [weak self] in
      self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
    model.add = { [weak self] in self?.add() }
    let host = HostingController(rootView: AnyView(ShareView(model: model).componentKit(accent: Color(.sRGB, red: 0, green: 0.478, blue: 1))))
    addChild(host)
    host.view.frame = view.bounds
    #if os(macOS)
      host.view.autoresizingMask = [.width, .height]
      preferredContentSize = NSSize(width: 440, height: 300)
    #else
      host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    #endif
    view.addSubview(host.view)
    let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    Task { await load(providers) }
  }

  private func load(_ providers: [NSItemProvider]) async {
    if VaultStore.shared == nil {
      model.problem = "Open Vault on this device once first, so there's a vault to add to."
    }
    for provider in providers {
      if let file = await Self.file(from: provider) { model.files.append(file) }
    }
    if model.files.isEmpty, model.problem == nil {
      model.problem = "Vault takes PDFs and pictures, up to \(VaultDocumentFile.maximumSize / 1_048_576) MB each."
    }
    model.isLoading = false
  }

  /// A PDF or a picture, with its size, page count and a thumbnail; nil for anything else or anything too large.
  private static func file(from provider: NSItemProvider) async -> SharedFile? {
    let isPDF = provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
    guard isPDF || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
    let type = isPDF ? UTType.pdf : UTType.image
    guard let data = try? await provider.loadData(type.identifier), data.count <= VaultDocumentFile.maximumSize else { return nil }
    let name = provider.suggestedName.map { ($0 as NSString).deletingPathExtension } ?? (isPDF ? "Document" : "Picture")
    if PDFPages.isPDF(data) {
      let size = PDFPages.pageSize(data) ?? (595, 842)
      let first = PDFPages.render(data, page: 0, maxPixel: 960)
      return SharedFile(
        name: name, contentType: "application/pdf", data: data, width: Int(size.width), height: Int(size.height),
        pageCount: PDFPages.pageCount(data) ?? 1, thumbnail: first.flatMap { PageScanner.thumbnail(of: $0.data)?.data })
    }
    guard let size = PageScanner.pixelSize(of: data) else { return nil }
    let contentType = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : data.starts(with: [0xFF, 0xD8]) ? "image/jpeg" : "image/heic"
    return SharedFile(
      name: name, contentType: contentType, data: data, width: size.width, height: size.height,
      thumbnail: PageScanner.thumbnail(of: data)?.data)
  }

  private func add() {
    guard let store = VaultStore.shared else { return }
    model.isSaving = true
    do {
      try store.addSharedFiles(model.files)
      extensionContext?.completeRequest(returningItems: nil)
    } catch {
      model.isSaving = false
      model.problem = "Couldn't add them: \(error.localizedDescription)"
    }
  }
}

extension NSItemProvider {
  /// The item's bytes as `type`.
  fileprivate func loadData(_ type: String) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      _ = loadDataRepresentation(forTypeIdentifier: type) { data, error in
        if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
      }
    }
  }
}

#if os(macOS)
  typealias PlatformViewController = NSViewController
  private typealias HostingController = NSHostingController<AnyView>
#else
  typealias PlatformViewController = UIViewController
  private typealias HostingController = UIHostingController<AnyView>
#endif
