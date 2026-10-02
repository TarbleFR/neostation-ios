import UIKit

// Read-only adapters for existing native menus. No swizzling, KVC, private API,
// input handler replacement, core rebuild or menu mutation. Bound each traversal.
enum NPGameHUDAnchor {
    static func kind(of button: UIButton) -> String? {
        for target in button.allTargets {
            guard let object = target.base as? NSObject else { continue }
            let className = NSStringFromClass(type(of: object))
            let actions = Set(button.actions(forTarget:target.base,forControlEvent:.touchUpInside) ?? [])
            if className == "DOLDolphinViewController" && actions.contains("menuPressed:") { return "dolphin" }
            if className == "Armsx2GameViewController" && actions.contains("menuPressed") { return "armsx2" }
            if className == "RPCS3GameViewController" && actions.contains("menuPressed") { return "rpcs3" }
            if className == "NeoDusklightControls" && actions.contains("openMenu") { return "dusklight" }
        }
        if button.menu != nil && button.accessibilityLabel == "Menu" {
            var parent = button.superview
            for _ in 0..<12 {
                guard let view = parent else { break }
                if NSStringFromClass(type(of:view)) == "KartPadGameOverlay" { return "kartpad" }
                parent = view.superview
            }
        }
        return nil
    }
    static func visible(_ view: UIView) -> Bool {
        guard let window = view.window, !window.isHidden else { return false }
        var cursor: UIView? = view
        while let item = cursor { if item.isHidden || item.alpha < 0.05 { return false }; cursor = item.superview }
        return !view.bounds.isEmpty
    }
    static func find(in root: UIView, limit: Int = 512) -> UIButton? {
        var remaining = limit
        func walk(_ view: UIView, depth: Int) -> UIButton? {
            guard remaining > 0, depth < 20, !view.isHidden, view.alpha >= 0.05 else { return nil }; remaining -= 1
            if let button = view as? UIButton, kind(of:button) != nil { return button }
            for child in view.subviews.reversed() { if let found = walk(child,depth:depth+1) { return found } }
            return nil
        }
        return walk(root,depth:0)
    }
}
