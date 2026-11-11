import UIKit
import LocalAuthentication
import Shared

/// Each Mac's login password, saved on this device only, behind Touch ID (or Face ID, or the passcode): read only to
/// unlock that Mac when a session finds it locked. Never synced, never readable without the person holding the device.
enum SavedPassword {
    private static func item(_ mac: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "dev.hither.unlock", kSecAttrAccount: mac]
    }
    private static func flag(_ mac: String) -> String { "unlock.saved.\(mac)" }

    /// There's one (known without asking for Touch ID).
    static func has(_ mac: String) -> Bool { UserDefaults.standard.bool(forKey: flag(mac)) }

    static func save(_ password: String, for mac: String) {
        SecItemDelete(item(mac) as CFDictionary)
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, nil)
        else { return }
        let err = SecItemAdd(item(mac).merging([kSecValueData: Data(password.utf8), kSecAttrAccessControl: access]) { $1 } as CFDictionary, nil)
        UserDefaults.standard.set(err == errSecSuccess, forKey: flag(mac))
        if err != errSecSuccess { log("saving the password for \(mac): \(err)") }
    }

    /// Asks for Touch ID; nil if it was cancelled or there's none.
    static func read(_ mac: String, reason: String, _ done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let context = LAContext()
            context.localizedReason = reason
            var v: CFTypeRef?
            let err = SecItemCopyMatching(item(mac).merging([kSecReturnData: true, kSecUseAuthenticationContext: context]) { $1 } as CFDictionary, &v)
            if err == errSecItemNotFound { DispatchQueue.main.async { UserDefaults.standard.set(false, forKey: flag(mac)) } }
            let pw = err == errSecSuccess ? (v as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
            DispatchQueue.main.async { done(pw) }
        }
    }

    static func forget(_ mac: String) {
        SecItemDelete(item(mac) as CFDictionary)
        UserDefaults.standard.set(false, forKey: flag(mac))
    }

    /// "Touch ID", "Face ID" or "your passcode": what guards it on this device.
    static var guardName: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch c.biometryType {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        default: return "your passcode"
        }
    }
}

/// A session found its Mac locked: unlock it with the saved password (after Touch ID), or ask for it once and save it
/// when it works. One attempt per Mac at a time, however many sessions open at once; "Not Now" holds until that Mac is
/// seen unlocked. The Mac types the password only if it's still locked (see the host's `unlock`).
final class Unlocker {   // main queue
    static let shared = Unlocker()
    private var busy: [String: CFTimeInterval] = [:]   // Mac → when its attempt started
    private var typed: [String: String] = [:]           // asked for, saved once it unlocks
    private var declined: Set<String> = []

    /// `send`: to the host, over the session that found it locked. `present`: where to ask.
    func locked(_ mac: Peer, send: @escaping (Msg) -> Void, present: @escaping () -> UIViewController?) {
        let now = CACurrentMediaTime()
        guard !declined.contains(mac.id), now - (busy[mac.id] ?? 0) > 20 else { return }
        busy[mac.id] = now
        if SavedPassword.has(mac.id) {
            SavedPassword.read(mac.id, reason: "Unlock \(mac.name)") { [weak self] pw in
                guard let pw else { self?.busy[mac.id] = nil; return }   // cancelled: type it on the lock screen
                self?.typed[mac.id] = nil
                Self.send(pw, send)
            }
        } else {
            ask(mac, send: send, present: present, wrong: false)
        }
    }

    /// The host's answer to an unlock, or news that the Mac is (un)locked now.
    func result(_ mac: Peer, locked: Bool, tried: Bool, send: @escaping (Msg) -> Void, present: @escaping () -> UIViewController?) {
        if !locked {
            declined.remove(mac.id)
            if let pw = typed.removeValue(forKey: mac.id) {
                SavedPassword.save(pw, for: mac.id)
                if SavedPassword.has(mac.id) { macsFlash?("Unlocked \(mac.name). Next time \(SavedPassword.guardName) unlocks it.") }
            }
            busy[mac.id] = nil
        } else if tried, busy[mac.id] != nil {   // the password didn't work
            ask(mac, send: send, present: present, wrong: true)
        }
    }

    var macsFlash: ((String) -> Void)?

    private func ask(_ mac: Peer, send: @escaping (Msg) -> Void, present: @escaping () -> UIViewController?, wrong: Bool) {
        guard let p = present() else { busy[mac.id] = nil; return }
        let saved = SavedPassword.has(mac.id)
        let a = UIAlertController(
            title: wrong ? "That password didn't unlock \(mac.name)" : "\(mac.name) is locked",
            message: wrong && saved && typed[mac.id] == nil
                ? "Its password may have changed. Type it to unlock and save it again."
                : "Type its password to unlock it. It's saved on this device for next time, behind \(SavedPassword.guardName).",
            preferredStyle: .alert)
        a.addTextField { f in
            f.isSecureTextEntry = true
            f.placeholder = "Password"
            f.textContentType = .password
            f.returnKeyType = .go
        }
        a.addAction(UIAlertAction(title: "Not Now", style: .cancel) { [weak self] _ in
            self?.declined.insert(mac.id)
            self?.typed[mac.id] = nil
            self?.busy[mac.id] = nil
        })
        let go = UIAlertAction(title: "Unlock", style: .default) { [weak self, weak a] _ in
            let pw = a?.textFields?.first?.text ?? ""
            guard let self, !pw.isEmpty else { self?.busy[mac.id] = nil; return }
            typed[mac.id] = pw
            busy[mac.id] = CACurrentMediaTime()
            Self.send(pw, send)
        }
        a.addAction(go)
        a.preferredAction = go
        var top = p
        while let next = top.presentedViewController { top = next }
        top.present(a, animated: true)
    }

    private static func send(_ pw: String, _ send: (Msg) -> Void) {
        var m = Msg("unlock"); m.text = pw
        send(m)
    }
}
