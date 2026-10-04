import SwiftUI
import GrokDeskCore
struct ConnectionHealthBadge: View {
    let name:String
    let project:String
    let enabled:Bool
    @ObservedObject private var health = ConnectionHealthStore.shared
    private var state:ConnectionHealth { health.health(name:name,project:project) }
    private var label:String {
        if !enabled { return "Disabled" }
        switch state.probe { case .unchecked:return state.authorizedAt == nil ? "Not checked":"Authorized · not checked";case .checking:return "Checking";case .verified:return "Verified";case .failed:return "Needs attention";case .unknown:return "Unverified" }
    }
    var body:some View {
        HStack(spacing:5) { Circle().fill(enabled && state.probe == .verified ? Color.green:DeskColor.muted).frame(width:5,height:5);Text(label) }
            .font(.system(size:10)).foregroundStyle(DeskColor.muted)
            .help(state.message + (state.checkedAt.map { " · " + $0.formatted() } ?? ""))
    }
}
