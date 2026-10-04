import Foundation
import TOMLKit
public enum SettingScope:String,Sendable {case environment,user,project,managed,requirements,defaults}
public struct SettingDescriptor:Identifiable,Sendable {
    public let path:[String]
    public let title:String
    public let choices:[String]
    public let fallback:String
    public let environment:String?
    public var id:String {path.joined(separator:".")}
    public init(_ path:String,_ title:String,_ choices:[String],_ fallback:String,environment:String? = nil) {self.path=path.split(separator:".").map(String.init);self.title=title;self.choices=choices;self.fallback=fallback;self.environment=environment}
    public var projectWritable:Bool {["mcp_servers","plugins","permission"].contains(path.first ?? "")}
    public static let all:[Self] = [
        .init("ui.permission_mode","Tool permissions",["ask","auto","always-approve"],"ask"),
        .init("sandbox.profile","Filesystem sandbox",["off","workspace","read-only","strict"],"off",environment:"GROK_SANDBOX"),
        .init("models.default_reasoning_effort","Default reasoning",["low","medium","high","xhigh"],"high"),
        .init("subagents.enabled","Subagents",["true","false"],"Runtime default",environment:"GROK_SUBAGENTS"),
        .init("ui.cancel_subagents_on_turn_cancel","Cancel child agents",["ask","always_stop","always_continue"],"ask"),
        .init("tools.respect_gitignore","Respect gitignore",["true","false"],"false",environment:"GROK_RESPECT_GITIGNORE"),
        .init("toolset.bash.auto_background_on_timeout","Background long commands",["true","false"],"true"),
        .init("hints.new_session_worktree_mode","New session worktree prompt",["ask","always","never"],"never"),
        .init("hints.fork_worktree_mode","Fork worktree prompt",["ask","always","never"],"ask"),
        .init("ui.show_thinking_blocks","Thinking blocks in Grok terminal",["true","false"],"true",environment:"GROK_SHOW_THINKING_BLOCKS"),
        .init("session.auto_compact_threshold_percent","Auto-compact context (%)",["70","75","80","85","90","95"],"85")
    ]
    public func literal(_ value:String)->String {if ["true","false"].contains(value) || Int(value) != nil {return value};return ConfigDocument.quoted(value)}
    public func effective(user:String,requirements:String="",systemRequirements:String="",managed:String="",environment:[String:String]=ProcessInfo.processInfo.environment)->(value:String,source:SettingScope) {
        func read(_ text:String)->String? {
            guard let root=try? TOMLTable(string:text) else{return nil}
            var table=root
            for key in path.dropLast() {guard let next=table[key]?.tomlValue.table else{return nil};table=next}
            guard let key=path.last,let value=table[key]?.tomlValue else{return nil}
            return value.string ?? value.bool.map{$0 ? "true":"false"} ?? value.int.map(String.init)
        }
        if let value=read(systemRequirements) {return(value,.requirements)}
        if let value=read(requirements) {return(value,.requirements)}
        if let key=self.environment,let value=environment[key] {return(value=="1" ? "true":value=="0" ? "false":value,.environment)}
        if let value=read(user) {return(value,.user)}
        if let value=read(managed) {return(value,.managed)}
        return(fallback,.defaults)
    }
}
