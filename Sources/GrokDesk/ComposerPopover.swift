import SwiftUI

struct ComposerPopover<LabelView:View, Content:View>:View {
    let title:String
    let value:String
    let label:()->LabelView
    let content:(@escaping ()->Void)->Content
    @State private var presented=false
    init(_ title:String,value:String="",@ViewBuilder label:@escaping ()->LabelView,@ViewBuilder content:@escaping (@escaping ()->Void)->Content) {self.title=title;self.value=value;self.label=label;self.content=content}
    var body:some View {
        Button {presented.toggle()} label:{label().font(.system(size:11)).fixedSize()}
            .buttonStyle(QuietButton()).accessibilityLabel(title).accessibilityValue(value)
            .popover(isPresented:$presented,arrowEdge:.top) {
                VStack(alignment:.leading,spacing:8) {
                    Text(title).font(.system(size:12,weight:.semibold)).foregroundStyle(DeskColor.muted).padding(.horizontal,10).padding(.top,4)
                    Divider().padding(.horizontal,6)
                    content {presented=false}
                }.padding(8).deskPopup().foregroundStyle(DeskColor.ink).onExitCommand{presented=false}
            }
    }
}
struct ComposerChoice:Identifiable {
    let id:String
    let title:String
    var detail:String=""
    var symbol:String?=nil
    var enabled=true
    var inlineDetail=false
}
struct ComposerChoices:View {
    let choices:[ComposerChoice]
    let selected:String
    let select:(String)->Void
    var highlight:((String)->Void)? = nil
    @State private var highlighted:String?
    @FocusState private var focused:Bool
    var body:some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(spacing:2) {
                    ForEach(choices) { choice in
                        Button {select(choice.id)} label:{
                            HStack(spacing:10) {
                                if let symbol=choice.symbol {Image(systemName:symbol).frame(width:18).foregroundStyle(DeskColor.muted)}
                                if choice.inlineDetail {
                                    HStack(spacing:10) {Text(choice.title).frame(width:36,alignment:.leading);Text(choice.detail).foregroundStyle(DeskColor.muted)}
                                } else {
                                    VStack(alignment:.leading,spacing:3){Text(choice.title).lineLimit(1);if !choice.detail.isEmpty {Text(choice.detail).font(.system(size:10)).foregroundStyle(DeskColor.muted).lineLimit(2)}}
                                }
                                Spacer(minLength:10)
                                Image(systemName:"checkmark").font(.system(size:10,weight:.semibold)).opacity(choice.id==selected ? 1:0)
                            }.frame(height:choice.detail.isEmpty || choice.inlineDetail ? 32:46).contentShape(Rectangle())
                        }.buttonStyle(DeskMenuRowStyle(selected:highlighted==choice.id)).disabled(!choice.enabled).opacity(choice.enabled ? 1:0.45)
                            .id(choice.id).onHover{if $0 && choice.enabled {highlighted=choice.id}}
                            .accessibilityAddTraits(choice.id==selected ? .isSelected:[]).help(choice.title + (choice.detail.isEmpty ? "":"\n"+choice.detail))
                    }
                }
            }.frame(height:min(CGFloat(choices.reduce(0){$0+($1.detail.isEmpty || $1.inlineDetail ? 34:48)}),320))
                .onChange(of:highlighted){_,id in if let id {reader.scrollTo(id);highlight?(id)}}
        }.frame(width:260).focusable().focused($focused).focusEffectDisabled()
            .onAppear {highlighted=selected;DispatchQueue.main.async{focused=true}}
            .onKeyPress(.downArrow){move(1);return .handled}.onKeyPress(.upArrow){move(-1);return .handled}
            .onKeyPress(.return){if let id=highlighted,choices.contains(where:{$0.id==id && $0.enabled}) {select(id)};return .handled}
    }
    private func move(_ offset:Int){let enabled=choices.filter(\.enabled);guard !enabled.isEmpty else{return};let index=enabled.firstIndex(where:{$0.id==highlighted}) ?? 0;highlighted=enabled[min(max(index+offset,0),enabled.count-1)].id}
}
struct AspectRatioPicker:View {
    @Binding var selection:String
    @State private var preview:String?
    private let names=["2:3":"Tall","3:2":"Wide","1:1":"Square","9:16":"Vertical","16:9":"Widescreen"]
    var body:some View {
        ComposerPopover("Aspect ratio",value:selection) {
            HStack(spacing:6){ratioShape(selection).frame(width:16,height:14);Text(selection)}
        } content:{dismiss in
            VStack(spacing:10) {
                ZStack {
                    RoundedRectangle(cornerRadius:12).fill(DeskColor.row.opacity(0.5))
                    VStack(spacing:6) {ratioShape(preview ?? selection).foregroundStyle(DeskColor.select).frame(width:90,height:60);Text(names[preview ?? selection] ?? "").font(.system(size:10)).foregroundStyle(DeskColor.muted)}
                }.frame(height:96).padding(.horizontal,6)
                ComposerChoices(choices:["2:3","3:2","1:1","9:16","16:9"].map{ComposerChoice(id:$0,title:$0,detail:names[$0] ?? "",inlineDetail:true)},selected:selection,select:{selection=$0;dismiss()},highlight:{preview=$0})
            }.onAppear {preview=selection}
        }
    }
    private func ratioShape(_ value:String)->some View {let parts=value.split(separator:":").compactMap{Double($0)};let ratio=parts.count==2 ? parts[0]/parts[1]:1;return RoundedRectangle(cornerRadius:2).strokeBorder(lineWidth:1.3).aspectRatio(ratio,contentMode:.fit)}
}
