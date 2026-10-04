import Foundation

public struct SubscriptionSnapshot: Equatable, Sendable {
    public var plan: String
    public var percentUsed: Double
    public var percentLeft: Double
    public var resetsAt: String
}

public func parseSubscriptionLog(_ text: String) -> SubscriptionSnapshot? {
    for line in text.split(separator: "\n").reversed() {
        guard line.contains("creditUsagePercent"),
              let data = String(line).data(using: .utf8),
              let row = try? JSONSerialization.jsonObject(with: data) else { continue }
        if let found = findCredits(row) {
            let used = min(100, max(0, found.percent))
            return SubscriptionSnapshot(
                plan: found.plan,
                percentUsed: used,
                percentLeft: max(0, (100 - used) * 10).rounded() / 10,
                resetsAt: found.end
            )
        }
    }
    return nil
}

private struct CreditHit {
    var percent: Double
    var plan: String
    var end: String
}

private func findCredits(_ value: Any, plan: String = "Grok", end: String = "") -> CreditHit? {
    guard let object = value as? [String: Any] else { return nil }
    var nextPlan = plan
    var nextEnd = end
    if let tier = object["subscriptionTier"] as? String { nextPlan = prettyTier(tier) }
    if let period = object["currentPeriod"] as? [String: Any], let finish = period["end"] as? String {
        nextEnd = finish
    }
    if let raw = object["creditUsagePercent"] as? Double ?? (object["creditUsagePercent"] as? Int).map(Double.init) {
        return CreditHit(percent: raw, plan: nextPlan, end: String(nextEnd.prefix(10)))
    }
    for child in object.values {
        if let hit = findCredits(child, plan: nextPlan, end: nextEnd) { return hit }
    }
    return nil
}

private func prettyTier(_ raw: String) -> String {
    if raw.isEmpty { return "Grok" }
    if raw.contains(" ") { return raw }
    return raw
}

public func loadSubscription(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SubscriptionSnapshot? {
    let url = home.appendingPathComponent(".grok/logs/unified.jsonl")
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let size = handle.seekToEndOfFile()
    let window = min(size, 400_000)
    handle.seek(toFileOffset: size - window)
    let data = handle.readDataToEndOfFile()
    return parseSubscriptionLog(String(data: data, encoding: .utf8) ?? "")
}

public func decodeLiveSubscription(_ data: Data, plan: String) throws -> SubscriptionSnapshot {
    let root = try JSONSerialization.jsonObject(with:data)
    guard let found = findCredits(root,plan:plan), found.percent.isFinite else {
        throw NSError(domain:"Subscription",code:1,userInfo:[NSLocalizedDescriptionKey:"The service did not return a credit allowance. No percentage was inferred."])
    }
    let used = min(100,max(0,found.percent))
    return SubscriptionSnapshot(plan:plan,percentUsed:used,percentLeft:((100-used)*10).rounded()/10,resetsAt:found.end)
}

public func fetchLiveSubscription(home:URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> SubscriptionSnapshot {
    let data = try Data(contentsOf:home.appendingPathComponent(".grok/auth.json"))
    guard let root = try JSONSerialization.jsonObject(with:data) as? [String:[String:Any]],
          let account = root.first(where: { $0.key.hasPrefix("https://auth.x.ai::") })?.value,
          let token = account["key"] as? String, !token.isEmpty else {
        throw NSError(domain:"Subscription",code:401,userInfo:[NSLocalizedDescriptionKey:"Sign in with Grok Build to refresh usage."])
    }
    func request(_ path:String) async throws -> Data {
        var request = URLRequest(url:URL(string:"https://cli-chat-proxy.grok.com/v1/"+path)!)
        request.timeoutInterval=15;request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        let (data,response)=try await URLSession.shared.data(for:request)
        guard let response=response as? HTTPURLResponse,response.statusCode==200 else {
            throw NSError(domain:"Subscription",code:2,userInfo:[NSLocalizedDescriptionKey:"Live usage could not be refreshed. Check the connection or sign in again."])
        }
        return data
    }
    async let settingsData = request("settings")
    async let billingData = request("billing?format=credits")
    let settings = try JSONSerialization.jsonObject(with:await settingsData) as? [String:Any]
    return try decodeLiveSubscription(await billingData,plan:settings?["subscription_tier_display"] as? String ?? "Grok")
}
