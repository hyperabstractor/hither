import Foundation
import Network

/// How to reach a paired Mac: its Bonjour name on the home network ("mini.local"), its Tailscale name elsewhere
/// ("mini", MagicDNS). Whichever answered last is tried first; a name that hasn't connected in 5 s gives way to the next.
public enum Reach {
    public static let patience = 5.0

    public static func hosts(_ mac: Peer) -> [String] {
        let last = UserDefaults.standard.string(forKey: "reach.\(mac.id)")
        return ["\(mac.name).local", mac.name].sorted { a, b in a == last && b != last }
    }

    public static func worked(_ host: String, for mac: Peer) { UserDefaults.standard.set(host, forKey: "reach.\(mac.id)") }

    /// Give up on a connection that isn't up yet, so its close handler tries the next name.
    public static func giveUpLater(on w: Wire) {
        DispatchQueue.main.asyncAfter(deadline: .now() + patience) { [weak w] in
            guard let w, w.conn.state != .ready else { return }
            w.close()
        }
    }
}
