// One policy shared by all view updates and the offscreen lifecycle checks.
// Occlusion, minimize, hide, close, sleep, and errors feed `visible: false`.
enum FrameScheduling {
    static func shouldRunNativeGlass(visible: Bool, paused: Bool, backdropStill: Bool,
                                     physicsAwake: Bool, redrawPending: Bool) -> Bool {
        visible && (redrawPending || (!paused && (!backdropStill || physicsAwake)))
    }
    static func shouldPlayAudio(visible: Bool, paused: Bool, scene: Scene) -> Bool {
        visible && !paused && scene == .koi
    }
    static func shouldRunPool(visible: Bool, paused: Bool, atRest: Bool, redrawPending: Bool) -> Bool {
        visible && (redrawPending || (!paused && !atRest))
    }
    static func shouldRun(visible: Bool, paused: Bool, staticScene: Bool,
                          refinementPending: Bool, interacting: Bool, redrawPending: Bool) -> Bool {
        guard visible else { return false }
        return redrawPending || interacting || refinementPending || (!paused && !staticScene)
    }
}
