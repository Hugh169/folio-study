import SwiftUI

#if DEBUG
/// Where views marked with `shotTarget(_:)` are drawn, so a render shot can
/// click them: SwiftUI draws most controls itself, with no AppKit view to find.
@MainActor
enum ShotTargets {
    /// Frames in the hosting view, with the origin at the top left, by name.
    static var frames: [String: CGRect] = [:]
}

extension View {
    /// Marks a view for render shots to click. Does nothing in release builds.
    func shotTarget(_ name: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { ShotTargets.frames[name] = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in ShotTargets.frames[name] = frame }
            }
        }
    }
}
#else
extension View {
    /// Marks a view for render shots to click. Does nothing in release builds.
    func shotTarget(_ name: String) -> some View {
        self
    }
}
#endif
