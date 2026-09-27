import Foundation

/// Public links shown in the Help menu and in Settings.
public enum ProjectLinks {
    public static let repository = URL(string: "https://github.com/Camponotus-vagus/glb-print-prep")!
    public static let issues = URL(string: "https://github.com/Camponotus-vagus/glb-print-prep/issues/new/choose")!
    public static let releases = URL(string: "https://github.com/Camponotus-vagus/glb-print-prep/releases")!
    public static let githubSponsors = URL(string: "https://github.com/sponsors/Camponotus-vagus")!
    /// Set to the Ko-fi page once it exists (e.g. "https://ko-fi.com/yourname"); hidden while nil.
    public static let koFi: URL? = nil
}
