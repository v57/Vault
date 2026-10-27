import AuthenticationServices
import ComponentKit
import LocalAuthentication
import SwiftUI
import VaultKit

/// Vault's credential provider. The system starts it when a password, code or passkey field asks; it reads the
/// shared store and the keychain the v57 apps share, and hands back the login the person picks (or the one the
/// system already chose from the list the Vault app published). It sends nothing; it writes only a new passkey.
final class CredentialProviderViewController: ASCredentialProviderViewController {
  private let model = AutoFillModel()
  /// The open passkey sign-in, when the list was opened for one.
  private var passkeyRequest: (clientDataHash: Data, verification: ASAuthorizationPublicKeyCredentialUserVerificationPreference)?

  #if os(macOS)
    override func loadView() {
      view = NSView()
    }
  #endif

  override func viewDidLoad() {
    super.viewDidLoad()
    model.complete = { [weak self] login in self?.complete(with: login) }
    model.completeCode = { [weak self] code in self?.complete(code: code) }
    model.completePasskey = { [weak self] passkey in
      guard let self, let request = passkeyRequest else { return }
      Task { await self.signIn(with: passkey, clientDataHash: request.clientDataHash, verification: request.verification) }
    }
    model.cancel = { [weak self] in self?.cancel(.userCanceled) }
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

  /// The system picked one of the published logins or passkeys: hand it over without showing anything.
  override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
    if let request = credentialRequest as? ASPasskeyCredentialRequest {
      // Signing in with user verification needs Touch ID or Face ID, which is interaction: the system then calls
      // prepareInterfaceToProvideCredential.
      guard request.userVerificationPreference == .discouraged else { return cancel(.userInteractionRequired) }
      guard let passkey = passkey(for: request) else { return cancel(.credentialIdentityNotFound) }
      Task { await signIn(with: passkey, clientDataHash: request.clientDataHash, verification: .discouraged) }
      return
    }
    guard let id = credentialRequest.credentialIdentity.recordIdentifier, let login = AutoFillModel.login(id: id) else {
      return cancel(.credentialIdentityNotFound)
    }
    if #available(macOS 15, iOS 18, *), credentialRequest.type == .oneTimeCode {
      guard let code = login.oneTimeCode?.code() else { return cancel(.credentialIdentityNotFound) }
      complete(code: code)
      return
    }
    complete(with: login)
  }

  override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
    if let request = credentialRequest as? ASPasskeyCredentialRequest {
      guard let passkey = passkey(for: request) else { return cancel(.credentialIdentityNotFound) }
      model.signingIn = passkey
      Task { await signIn(with: passkey, clientDataHash: request.clientDataHash, verification: request.userVerificationPreference) }
      return
    }
    model.load(identifiers: [credentialRequest.credentialIdentity.serviceIdentifier.identifier], wantsCode: false)
  }

  // MARK: One-time codes

  @available(macOS 15, iOS 18, *)
  override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
    model.load(identifiers: serviceIdentifiers.map(\.identifier), wantsCode: true)
  }

  // MARK: Passkeys

  /// A site asked for a passkey and the person opened Vault: its passkeys first, then the logins.
  override func prepareCredentialList(
    for serviceIdentifiers: [ASCredentialServiceIdentifier], requestParameters: ASPasskeyCredentialRequestParameters
  ) {
    passkeyRequest = (requestParameters.clientDataHash, requestParameters.userVerificationPreference)
    model.load(identifiers: serviceIdentifiers.map(\.identifier) + [requestParameters.relyingPartyIdentifier], wantsCode: false)
    model.passkeys = (try? VaultStore.shared?.passkeys(
      relyingParty: requestParameters.relyingPartyIdentifier, allowed: requestParameters.allowedCredentials)) ?? []
  }

  /// A site wants a new passkey saved in Vault: ask, verify the person, make it.
  override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
    guard let request = registrationRequest as? ASPasskeyCredentialRequest,
      let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity
    else { return cancel(.failed) }
    guard request.supportedAlgorithms.contains(where: { $0.rawValue == WebAuthn.es256 }) else { return cancel(.failed) }
    if #available(macOS 15, iOS 18, *), let excluded = request.excludedCredentials, !excluded.isEmpty {
      let ours = (try? VaultStore.shared?.passkeys(relyingParty: identity.relyingPartyIdentifier, allowed: excluded.map(\.credentialID))) ?? []
      if !ours.isEmpty { return cancel(.matchedExcludedCredential) }
    }
    model.registration = (identity.relyingPartyIdentifier, identity.userName)
    model.confirmRegistration = { [weak self] in
      Task { await self?.register(identity, clientDataHash: request.clientDataHash, verification: request.userVerificationPreference) }
    }
  }

  private func register(
    _ identity: ASPasskeyCredentialIdentity, clientDataHash: Data,
    verification: ASAuthorizationPublicKeyCredentialUserVerificationPreference
  ) async {
    guard let verified = await verify(verification, reason: "save a passkey for \(identity.relyingPartyIdentifier)") else {
      return cancel(.userCanceled)
    }
    guard let store = VaultStore.shared,
      let registration = try? store.createPasskey(
        relyingParty: identity.relyingPartyIdentifier, userName: identity.userName, userHandle: identity.userHandle,
        userVerified: verified)
    else { return cancel(.failed) }
    await VaultAutoFill.publish(registration.passkey)
    extensionContext.completeRegistrationRequest(using: ASPasskeyRegistrationCredential(
      relyingParty: registration.passkey.relyingParty, clientDataHash: clientDataHash,
      credentialID: registration.passkey.credentialID, attestationObject: registration.attestationObject),
      completionHandler: nil)
  }

  private func signIn(
    with passkey: VaultPasskey, clientDataHash: Data, verification: ASAuthorizationPublicKeyCredentialUserVerificationPreference
  ) async {
    guard let verified = await verify(verification, reason: "sign in to \(passkey.relyingParty)") else {
      return cancel(.userCanceled)
    }
    guard let assertion = try? passkey.assertion(clientDataHash: clientDataHash, userVerified: verified) else {
      return cancel(.credentialIdentityNotFound)
    }
    extensionContext.completeAssertionRequest(using: ASPasskeyAssertionCredential(
      userHandle: passkey.userHandle, relyingParty: passkey.relyingParty, signature: assertion.signature,
      clientDataHash: clientDataHash, authenticatorData: assertion.authenticatorData, credentialID: passkey.credentialID),
      completionHandler: nil)
  }

  /// Checks that the device's owner is here (Touch ID, Face ID or the device password) unless the site discouraged
  /// it. Returns whether they were verified, or nil when they cancelled or the site required it and it failed.
  private func verify(_ preference: ASAuthorizationPublicKeyCredentialUserVerificationPreference, reason: String) async -> Bool? {
    guard preference != .discouraged else { return false }
    let context = LAContext()
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
      return preference == .required ? nil : false
    }
    do {
      return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    } catch {
      return nil
    }
  }

  private func passkey(for request: ASPasskeyCredentialRequest) -> VaultPasskey? {
    guard let id = request.credentialIdentity.recordIdentifier else { return nil }
    return try? VaultStore.shared?.record(VaultPasskey.self, id: id)
  }

  // MARK: Completing

  private func complete(with login: VaultLogin) {
    guard let password = login.password else { return cancel(.credentialIdentityNotFound) }
    extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: login.username, password: password))
  }

  private func complete(code: String) {
    if #available(macOS 15, iOS 18, *) {
      extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code))
    }
  }

  private func cancel(_ code: ASExtensionError.Code) {
    extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
  }
}

#if os(macOS)
  private typealias HostingController = NSHostingController<AnyView>
#else
  private typealias HostingController = UIHostingController<AnyView>
#endif
