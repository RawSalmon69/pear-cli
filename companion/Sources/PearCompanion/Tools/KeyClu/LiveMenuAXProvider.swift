import ApplicationServices

/// Builds a menu-bar `AXNode` tree from a running app via Accessibility.
/// Flattens each menu-bar item's single `AXMenu` child so `AXNode.children`
/// holds the actual menu items. Every read is timeout-capped so a beachballing
/// target app can't freeze our main thread.
///
/// ponytail: reads the whole menu tree eagerly on each hotkey press. Fine for
/// on-demand use; if a giant menu (Safari History) feels slow, cap depth or
/// item count here.
@MainActor
struct LiveMenuAXProvider: MenuAXProviding {
    func menuBar(forPID pid: pid_t) -> AXNode? {
        let app = AXUIElementCreateApplication(pid)
        DockAX.capTimeout(app)
        guard let bar = DockAX.element(app, kAXMenuBarAttribute) else { return nil }
        return node(from: bar)
    }

    // ponytail: depth cap guards against cyclic AX trees; real menus are shallow (<~5).
    private static let maxDepth = 20

    private func node(from element: AXUIElement, depth: Int = 0) -> AXNode {
        DockAX.capTimeout(element)
        let title = DockAX.string(element, kAXTitleAttribute) ?? ""
        let enabled = DockAX.bool(element, kAXEnabledAttribute) ?? true
        let char = DockAX.string(element, kAXMenuItemCmdCharAttribute)
        let virtualKey = DockAX.value(element, kAXMenuItemCmdVirtualKeyAttribute) as? Int
        let modifiers = DockAX.value(element, kAXMenuItemCmdModifiersAttribute) as? Int ?? 0
        let glyph = DockAX.value(element, kAXMenuItemCmdGlyphAttribute) as? Int

        // A menu-bar item / submenu parent holds its items inside one AXMenu
        // child. Flatten that so `children` are the items themselves.
        var children: [AXNode] = []
        if depth < Self.maxDepth {
            for child in DockAX.elements(element, kAXChildrenAttribute) ?? [] {
                if DockAX.string(child, kAXRoleAttribute) == kAXMenuRole {
                    DockAX.capTimeout(child)
                    children +=
                        (DockAX.elements(child, kAXChildrenAttribute) ?? []).map {
                            node(from: $0, depth: depth + 1)
                        }
                } else {
                    children.append(node(from: child, depth: depth + 1))
                }
            }
        }

        let isSeparator = title.isEmpty && char == nil && virtualKey == nil && children.isEmpty
        return AXNode(
            title: title, cmdChar: char, cmdVirtualKey: virtualKey,
            cmdModifiers: modifiers, cmdGlyph: glyph,
            isSeparator: isSeparator, isEnabled: enabled, children: children)
    }
}
