import Foundation

/// Public links shown in the Help menu and in Settings.
public enum ProjectLinks {
    public static let repository = URL(string: "https://github.com/Camponotus-vagus/glb-print-prep")!
    public static let issues = URL(string: "https://github.com/Camponotus-vagus/glb-print-prep/issues/new/choose")!
    public static let releases = URL(string: "https://github.com/Camponotus-vagus/glb-print-prep/releases")!
    public static let githubSponsors = URL(string: "https://github.com/sponsors/Camponotus-vagus")!
    /// Ko-fi page (one-off and monthly tips); the UI hides the entry when nil.
    public static let koFi: URL? = URL(string: "https://ko-fi.com/zermat")
}
