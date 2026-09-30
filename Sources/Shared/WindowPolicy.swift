import Foundation

/// The information needed to choose a window without depending on a live capture session.
public struct WindowCandidate {
    public let id: Int
    public let app: String
    public let bundle: String
    public let title: String
    public let area: Double

    public init(id: Int, app: String, bundle: String, title: String, area: Double) {
        self.id = id; self.app = app; self.bundle = bundle; self.title = title; self.area = area
    }

    public static func select(from windows: [Self], app: String, title: String?, id: Int) -> Int? {
        let app = app.lowercased()
        let matching = windows.filter { $0.app.lowercased().contains(app) || $0.bundle.lowercased() == app }
        // A pinned window is an identity, not a preference. Titles may change; IDs may not.
        if id != 0 { return matching.first { $0.id == id }?.id }
        return matching.filter { title == nil || $0.title.localizedCaseInsensitiveContains(title!) }
            .max { $0.area < $1.area }?.id
    }
}

/// Accessibility can label a frameless helper panel as a standard window. Keep those in the parent's
/// capture instead of following them as independent windows. Unknown attributes are not negative evidence.
public struct WindowTraits {
    public let standard: Bool
    public let parentIsWindow: Bool
    public let hasWindowControls: Bool?
    public let resizable: Bool?
    public let hasContainingWindow: Bool

    public init(standard: Bool, parentIsWindow: Bool, hasWindowControls: Bool?, resizable: Bool?, hasContainingWindow: Bool = false) {
        self.standard = standard; self.parentIsWindow = parentIsWindow
        self.hasWindowControls = hasWindowControls; self.resizable = resizable
        self.hasContainingWindow = hasContainingWindow
    }

    public var isIndependent: Bool {
        standard && !parentIsWindow && !(hasContainingWindow && hasWindowControls == false && resizable == false)
    }
}
