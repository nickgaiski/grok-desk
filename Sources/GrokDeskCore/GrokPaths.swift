import Foundation
public enum GrokPaths {
    public static var binary: String {
        let preferred = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/bin/grok").path
        return FileManager.default.isExecutableFile(atPath: preferred) ? preferred : RepositoryService.executable("grok")
    }
    public static func home(environment: [String:String] = ProcessInfo.processInfo.environment) -> URL {
        environment["GROK_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }
    public static var config: URL { configURL() }
    public static func configURL(environment: [String:String] = ProcessInfo.processInfo.environment) -> URL {
        environment["GROK_DESK_CONFIG_PATH"].map { URL(fileURLWithPath: $0) } ?? home(environment: environment).appendingPathComponent("config.toml")
    }
}
