import AuthenticationServices
import ComponentKit
import SwiftUI
import VaultKit

/// Vault's credential provider. The system starts it when a password or code field asks; it reads the shared store
/// and the keychain the v57 apps share, and hands back the login the person picks (or the one the system already
/// chose from the list the Vault app published). It keeps nothing and sends nothing.
final class CredentialProviderViewController: ASCredentialProviderViewController {
  private let model = AutoFillModel()

  #if os(macOS)
    override func loadView() {
      view = NSView()
    }
  #endif

  override func viewDidLoad() {
    super.viewDidLoad()
    model.complete = { [weak self] login in self?.complete(with: login) }
    model.completeCode = { [weak self] code in self?.complete(code: code) }
    model.cancel = { [weak self] in
      self?.extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue))
    }
    let host = HostingController(rootView: AnyView(AutoFillPicker(model: model).componentKit(accent: Color(.sRGB, red: 0, green: 0.478, blue: 1))))
    addChild(host)
    host.view.frame = view.bounds
    #if os(macOS)
      host.view.autoresizingMask = [.width, .height]
    #else
      host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    #endif
    view.addSubview(host.view)
  }

  // MARK: Passwords

  /// The person opened Vault from the AutoFill menu: show the logins that fit, best first.
  override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
    model.load(identifiers: serviceIdentifiers.map(\.identifier), wantsCode: false)
  }

  /// The system picked one of the published logins: hand over its password without showing anything.
  override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
    guard let id = credentialRequest.credentialIdentity.recordIdentifier, let login = AutoFillModel.login(id: id) else {
      extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.credentialIdentityNotFound.rawValue))
      return
    }
    if #available(macOS 15, iOS 18, *), credentialRequest.type == .oneTimeCode {
      guard let code = login.oneTimeCode?.code() else {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.credentialIdentityNotFound.rawValue))
        return
      }
      complete(code: code)
      return
    }
    complete(with: login)
  }

  override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
    model.load(identifiers: [credentialRequest.credentialIdentity.serviceIdentifier.identifier], wantsCode: false)
  }

  // MARK: One-time codes

  @available(macOS 15, iOS 18, *)
  override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
    model.load(identifiers: serviceIdentifiers.map(\.identifier), wantsCode: true)
  }

  private func complete(with login: VaultLogin) {
    guard let password = login.password else {
      extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.credentialIdentityNotFound.rawValue))
      return
    }
    extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: login.username, password: password))
  }

  private func complete(code: String) {
    if #available(macOS 15, iOS 18, *) {
      extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code))
    }
  }
}

#if os(macOS)
  private typealias HostingController = NSHostingController<AnyView>
#else
  private typealias HostingController = UIHostingController<AnyView>
#endif
