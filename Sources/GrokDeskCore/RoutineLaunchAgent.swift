import Darwin
import Foundation

public enum RoutineHelperPaths {
    public static let executableName = "GrokDeskRoutineRunner"

    public static func bundledExecutable(appBundleURL: URL = Bundle.main.bundleURL) -> URL {
        appBundleURL.appendingPathComponent("Contents/Helpers/\(executableName)")
    }
}

public enum RoutineHelperError: LocalizedError {
    case helperMissing(String)
    case invalidPropertyList(String)
    case launchctl(String)
    case fileWrite(String)

    public var errorDescription: String? {
        switch self {
        case .helperMissing(let path): "The packaged routine helper is missing or not executable at \(path). Rebuild or move Grok Desk into Applications, then repair the helper."
        case .invalidPropertyList(let reason): "The routine helper configuration is invalid: \(reason)"
        case .launchctl(let reason): "macOS could not update the Grok Desk routine helper: \(reason)"
        case .fileWrite(let reason): "The routine helper configuration could not be saved: \(reason)"
        }
    }
}

/// Owns only Grok Desk's LaunchAgent label and plist. It is never installed on app launch.
public final class RoutineLaunchAgentManager: @unchecked Sendable {
    public static let defaultLabel = "com.grokdesk.GrokDesk.routines"

    public let storeURL: URL
    public let launchAgentURL: URL
    public let helperLabel: String
    public let launchctlURL: URL
    private let commandRunner: RoutineCommandRunning
    private let homeDirectory: URL

    public init(
        storeURL: URL,
        launchAgentURL: URL? = nil,
        helperLabel: String = RoutineLaunchAgentManager.defaultLabel,
        launchctlURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
        commandRunner: RoutineCommandRunning = ProcessRoutineCommandRunner(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.storeURL = storeURL.standardizedFileURL
        self.homeDirectory = homeDirectory
        self.launchAgentURL = (launchAgentURL ?? homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(helperLabel).plist")).standardizedFileURL
        self.helperLabel = helperLabel
        self.launchctlURL = launchctlURL
        self.commandRunner = commandRunner
    }

    public static func applicationDefault(storeURL: URL = RoutineStore.applicationDefault().fileURL) -> RoutineLaunchAgentManager {
        RoutineLaunchAgentManager(storeURL: storeURL)
    }

    public func status(expectedHelperURL: URL = RoutineHelperPaths.bundledExecutable()) -> RoutineHelperStatus {
        let dictionary: [String: Any]
        do {
            guard let existing = try loadExistingPropertyList() else { return .notInstalled }
            dictionary = existing
        } catch {
            return .repairRequired(installedPath: "invalid LaunchAgent plist", currentPath: expectedHelperURL.standardizedFileURL.path)
        }
        guard let arguments = dictionary["ProgramArguments"] as? [String], let installedPath = arguments.first else { return .notInstalled }
        let expectedPath = expectedHelperURL.standardizedFileURL.path
        guard installedPath == expectedPath, FileManager.default.isExecutableFile(atPath: expectedPath) else {
            return .repairRequired(installedPath: installedPath, currentPath: expectedPath)
        }
        return .installed(helperPath: installedPath)
    }

    public func isLoaded() throws -> Bool {
        do {
            _ = try runLaunchctl(["print", domainLabel])
            return true
        } catch let error as RoutineHelperError {
            if case .launchctl = error { return false }
            throw error
        }
    }

    public func propertyList(helperURL: URL, grokURL: URL) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { throw RoutineHelperError.helperMissing(helperURL.path) }
        let inheritedEnvironment = grokEnvironment(ProcessInfo.processInfo.environment)
        var helperEnvironment = [
            "HOME": homeDirectory.path,
            "PATH": inheritedEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
        ]
        for key in ["GROK_HOME", "GROK_DESK_CONFIG_PATH", "GROK_BINARY"] {
            if let value = inheritedEnvironment[key], !value.isEmpty { helperEnvironment[key] = value }
        }
        let properties: [String: Any] = [
            "Label": helperLabel,
            "ProgramArguments": [
                helperURL.standardizedFileURL.path,
                "--store-path", storeURL.path,
                "--grok-path", grokURL.standardizedFileURL.path,
                "--watch",
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
            "EnvironmentVariables": helperEnvironment,
            "WorkingDirectory": homeDirectory.path,
        ]
        do { return try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0) }
        catch { throw RoutineHelperError.invalidPropertyList(error.localizedDescription) }
    }

    public func install(helperURL: URL = RoutineHelperPaths.bundledExecutable(), grokURL: URL = RoutineGrokCLI.discover()) throws {
        let newData = try propertyList(helperURL: helperURL, grokURL: grokURL)
        let oldData = try? Data(contentsOf: launchAgentURL)
        let wasLoaded = try isLoaded()
        if wasLoaded { _ = try runLaunchctl(["bootout", domainLabel]) }

        do {
            try write(newData)
            _ = try runLaunchctl(["enable", domainLabel])
            _ = try runLaunchctl(["bootstrap", guiDomain, launchAgentURL.path])
        } catch {
            _ = try? runLaunchctl(["bootout", domainLabel])
            if let oldData {
                try? write(oldData)
                if wasLoaded { _ = try? runLaunchctl(["bootstrap", guiDomain, launchAgentURL.path]) }
            } else {
                try? FileManager.default.removeItem(at: launchAgentURL)
            }
            throw error
        }
    }

    public func remove() throws {
        let wasLoaded = try isLoaded()
        if wasLoaded { _ = try runLaunchctl(["bootout", domainLabel]) }
        do { _ = try runLaunchctl(["disable", domainLabel]) }
        catch { if wasLoaded { _ = try? runLaunchctl(["bootstrap", guiDomain, launchAgentURL.path]) }; throw error }
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            do { try FileManager.default.removeItem(at: launchAgentURL) }
            catch { throw RoutineHelperError.fileWrite(error.localizedDescription) }
        }
    }

    private var guiDomain: String { "gui/\(getuid())" }
    private var domainLabel: String { "\(guiDomain)/\(helperLabel)" }

    private func runLaunchctl(_ arguments: [String]) throws -> RoutineCommandResult {
        let command = RoutineCommand(
            executableURL: launchctlURL,
            arguments: arguments,
            currentDirectoryURL: homeDirectory,
            timeout: 10,
            environment: grokEnvironment(ProcessInfo.processInfo.environment)
        )
        do {
            let result = try commandRunner.run(command)
            guard result.exitCode == 0, !result.timedOut else {
                let message = [result.stderr, result.stdout].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                throw RoutineHelperError.launchctl(message.isEmpty ? "launchctl exited with status \(result.exitCode)." : String(message.prefix(2_000)))
            }
            return result
        } catch let error as RoutineHelperError {
            throw error
        } catch {
            throw RoutineHelperError.launchctl(error.localizedDescription)
        }
    }

    private func loadExistingPropertyList() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: launchAgentURL.path) else { return nil }
        let data = try Data(contentsOf: launchAgentURL)
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw RoutineHelperError.invalidPropertyList("The existing plist is not a dictionary.")
        }
        return value
    }

    private func write(_ data: Data) throws {
        do {
            try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: launchAgentURL, options: .atomic)
            _ = chmod(launchAgentURL.path, mode_t(S_IRUSR | S_IWUSR))
        } catch { throw RoutineHelperError.fileWrite(error.localizedDescription) }
    }
}
