import AppKit

/// A plain click on a view that also selects text: pressed and released in
/// place, and not the first half of a double-click. The view feeds it its
/// mouse events, and it reports after the double-click interval, when a
/// second click can no longer make the first one part of a word selection.
final class SingleClick {
    var onClick: () -> Void = {}
    /// How far the pointer may move between down and up and still click.
    static let slop: CGFloat = 4

    private var downAt: CGPoint?
    private var pending: DispatchWorkItem?

    func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        if event.clickCount != 1 {
            pending?.cancel()
            pending = nil
        }
    }

    func mouseDragged(with event: NSEvent) {
        guard let downAt else { return }
        let point = event.locationInWindow
        if abs(point.x - downAt.x) > Self.slop || abs(point.y - downAt.y) > Self.slop {
            self.downAt = nil
        }
    }

    func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        guard downAt != nil, event.clickCount == 1 else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.onClick()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: item)
    }
}
