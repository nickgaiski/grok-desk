import Foundation

public struct CameraPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let camera: String
    public let lens: String
    public let focal: String
    public let aperture: String
    public let movement: String
    public func apply(to board: inout StudioBoard) {
        var look = StudioLook()
        look.camera = camera; look.lens = lens; look.focal = focal; look.aperture = aperture; look.treatment = detail
        board.look = look; board.motion = movement; board.presetName = name
    }
    public static let all: [CameraPreset] = [
        .init(id: "drama", name: "Natural drama", detail: "Soft window light, restrained color, natural skin tones.", camera: "ARRI Alexa 35", lens: "Cooke S4 prime", focal: "35 mm", aperture: "f/2.8", movement: "Slow push in"),
        .init(id: "epic", name: "Large-format epic", detail: "Expansive scale, deep atmospheric layers, rich highlight detail.", camera: "IMAX 65 mm film", lens: "Large-format prime", focal: "24 mm", aperture: "f/8", movement: "Crane rise"),
        .init(id: "noir", name: "Neo-noir", detail: "Hard side light, deep shadows, isolated practical lights, cool nights and warm highlights.", camera: "ARRI Alexa Mini LF", lens: "Anamorphic", focal: "50 mm", aperture: "f/2", movement: "Slow tracking shot"),
        .init(id: "scifi", name: "Anamorphic sci-fi", detail: "Architectural framing, cool color separation, oval bokeh and restrained lens flare.", camera: "Sony VENICE 2", lens: "Anamorphic", focal: "35 mm", aperture: "f/2.8", movement: "Gentle orbit"),
        .init(id: "documentary", name: "Intimate documentary", detail: "Available light, tactile grain and an observational, immediate feeling.", camera: "Super 16 film", lens: "Vintage prime", focal: "35 mm", aperture: "f/4", movement: "Handheld"),
        .init(id: "portrait", name: "Editorial portrait", detail: "Soft sculpted light, gentle highlight rolloff, warm skin against a quiet background.", camera: "ARRI Alexa Mini LF", lens: "Cooke S4 prime", focal: "85 mm", aperture: "f/1.4", movement: "Locked camera"),
        .init(id: "product", name: "Precision product", detail: "Controlled studio reflections, crisp texture, clean background and precise composition.", camera: "RED V-RAPTOR", lens: "Macro", focal: "100 mm", aperture: "f/8", movement: "Slow push in")
    ]
    public static let cameras = ["Full-frame digital", "ARRI Alexa 35", "ARRI Alexa Mini LF", "Sony VENICE 2", "RED V-RAPTOR", "IMAX 65 mm film", "Super 16 film"]
    public static let lenses = ["Cinema prime", "Cooke S4 prime", "Large-format prime", "Anamorphic", "Vintage prime", "Macro", "Tilt-shift", "Diffusion"]
    public static let focals = ["14 mm", "24 mm", "35 mm", "50 mm", "85 mm", "100 mm"]
    public static let apertures = ["f/1.4", "f/2", "f/2.8", "f/4", "f/5.6", "f/8", "f/11"]
    public static let movements = ["Locked camera", "Slow push in", "Pull back", "Slow tracking shot", "Gentle orbit", "Handheld", "Pan left", "Pan right", "Crane rise"]
}
