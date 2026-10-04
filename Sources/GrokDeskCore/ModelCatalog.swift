import Foundation

public struct GrokModel: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var isDefault: Bool
}

public struct ModelCatalogState: Equatable, Sendable {
    public var models: [GrokModel]
    public var stale: Bool
    public init(models: [GrokModel], stale: Bool) {
        self.models = models
        self.stale = stale
    }
}

public func parseModels(_ stdout: String) -> [GrokModel] {
    stdout.split(separator: "\n").compactMap { raw in
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("*") || line.hasPrefix("-") else { return nil }
        let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
        let id = body.split(separator: " ").first.map(String.init) ?? ""
        guard !id.isEmpty else { return nil }
        let isDefault = line.hasPrefix("*") || body.contains("(default)")
        return GrokModel(id: id, label: displayName(for: id), isDefault: isDefault)
    }
}

public func reduceCatalog(_ state: ModelCatalogState, stdout: String?, failed: Bool) -> ModelCatalogState {
    if failed {
        return ModelCatalogState(models: state.models, stale: true)
    }
    return ModelCatalogState(models: parseModels(stdout ?? ""), stale: false)
}
