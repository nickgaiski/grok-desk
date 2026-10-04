import Darwin
import Foundation
import GrokDeskCore

@main
enum GrokDeskRoutineRunnerMain {
    static func main() {
        do {
            let options = try parse(Array(CommandLine.arguments.dropFirst()))
            let store = RoutineStore(fileURL: options.storeURL)
            let executor = RoutineExecutor(store: store, grokExecutableURL: options.grokURL ?? RoutineGrokCLI.discover())
            let scheduler = RoutineScheduler(store: store, executor: executor)
            if options.watch {
                scheduler.start()
                dispatchMain()
            }
            let results = try scheduler.tick()
            let processed = results.compactMap(\.run)
            let counts = Dictionary(grouping: processed, by: \.state).mapValues(\.count)
            let summary = counts
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\($0.value)" }
                .joined(separator: ",")
            print("routine-helper processed=\(processed.count)\(summary.isEmpty ? "" : " \(summary)")")
        } catch {
            fputs("Grok Desk routine helper: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func parse(_ arguments: [String]) throws -> Options {
        var storeURL: URL?
        var grokURL: URL?
        var watch = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                print("Usage: GrokDeskRoutineRunner --store-path PATH [--grok-path PATH] [--once]")
                exit(EXIT_SUCCESS)
            case "--once":
                watch = false
            case "--watch":
                watch = true
            case "--store-path", "--grok-path":
                guard index + 1 < arguments.count, arguments[index + 1].first != "-" else {
                    throw RunnerError.missingValue(argument)
                }
                let value = arguments[index + 1]
                if argument == "--store-path" { storeURL = URL(fileURLWithPath: value) }
                else { grokURL = URL(fileURLWithPath: value) }
                index += 1
            default:
                throw RunnerError.unknownArgument(argument)
            }
            index += 1
        }
        guard let storeURL else { throw RunnerError.storeRequired }
        return Options(storeURL: storeURL, grokURL: grokURL, watch: watch)
    }
}

private struct Options {
    let storeURL: URL
    let grokURL: URL?
    let watch: Bool
}

private enum RunnerError: LocalizedError {
    case missingValue(String)
    case unknownArgument(String)
    case storeRequired

    var errorDescription: String? {
        switch self {
        case .missingValue(let option): "Missing a path after \(option)."
        case .unknownArgument(let argument): "Unknown argument: \(argument)"
        case .storeRequired: "Pass --store-path to select the shared routine store."
        }
    }
}
