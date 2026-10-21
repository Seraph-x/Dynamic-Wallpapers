import AppKit
import ApplicationServices
import Darwin
import WallpaperCore

enum FinderDesktopHitSampler {
    struct WindowInfo {
        let id: UInt32
        let owner: pid_t
        let layer: Int
        let bounds: CGRect
        let isSystemCursor: Bool
        init(id: UInt32, owner: pid_t, layer: Int, bounds: CGRect, isSystemCursor: Bool = false) {
            self.id = id; self.owner = owner; self.layer = layer; self.bounds = bounds
            self.isSystemCursor = isSystemCursor
        }
    }

    static func menuSnapshot(finderPID: pid_t) -> FinderMenuSnapshot {
        do { return try menuSnapshot(windows: readWindows(), finderPID: finderPID) }
        catch { return .unavailable(error.localizedDescription) }
    }

    static func sample(point: CGPoint, target: FinderClickTarget, menu: FinderMenuEvidence,
                       finderPID: pid_t, destination: FinderMouseDestination) -> FinderDesktopSample {
        var roles: [String] = []
        var allFinder = true
        var complete = false
        var clear = false
        var observedMenu = menu
        var failure: String?
        do {
            let windows = try readWindows()
            observedMenu.apply(try menuSnapshot(windows: windows, finderPID: finderPID), ifUnchanged: menu.generation)
            let system = try systemElement()
            var hit: AXUIElement?
            let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
            guard result == .success, var current = hit else {
                throw WallpaperError("桌面命中查询失败：AX \(result.rawValue)")
            }
            // The observed desktop chain is exact; icons/labels have an additional leaf.
            for depth in 0..<3 {
                var pid: pid_t = 0
                let ownerResult = AXUIElementGetPid(current, &pid)
                guard ownerResult == .success else {
                    throw WallpaperError("无法读取命中元素进程：AX \(ownerResult.rawValue)")
                }
                guard pid == finderPID else { allFinder = false; break }
                let roleValue = try attribute(current, kAXRoleAttribute)
                guard let role = roleValue as? String else { throw WallpaperError("桌面元素角色格式无效。") }
                roles.append(role)
                if depth == 2 { complete = role == kAXApplicationRole; break }
                current = try element(attribute(current, kAXParentAttribute), label: "桌面元素父节点")
            }
            let obstruction = obstruction(point: point, target: target, windows: windows, finderPID: finderPID)
            clear = obstruction == nil
            failure = obstruction
        } catch { failure = error.localizedDescription }
        return FinderDesktopSample(target: target, menu: observedMenu, roles: roles,
            allOwnersAreFinder: allFinder, completeAncestry: complete, windowsClear: clear,
            destination: destination, failureReason: failure)
    }

    private static func menuSnapshot(windows: [WindowInfo], finderPID: pid_t) throws -> FinderMenuSnapshot {
        // Both Finder context menus and menu-bar menus were observed at this public level.
        // AXShownMenuUIElement returned noValue even while those menus were open.
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        if windows.contains(where: { $0.layer == menuLevel }) { return .open }
        _ = try systemElement()
        let finder = AXUIElementCreateApplication(finderPID)
        let menuBar = try element(attribute(finder, kAXMenuBarAttribute), label: "Finder 菜单栏")
        let role = try attribute(menuBar, kAXRoleAttribute) as? String
        guard role == kAXMenuBarRole else { throw WallpaperError("Finder 菜单栏角色无法确认。") }
        guard let selected = try attribute(menuBar, kAXSelectedChildrenAttribute) as? [AXUIElement] else {
            throw WallpaperError("Finder 菜单栏选择状态格式无效。")
        }
        return selected.isEmpty ? .closed : .open
    }

    private static func systemElement() throws -> AXUIElement {
        let system = AXUIElementCreateSystemWide()
        let result = AXUIElementSetMessagingTimeout(system, 0.2)
        guard result == .success else { throw WallpaperError("辅助功能查询超时配置失败：AX \(result.rawValue)") }
        return system
    }

    private static func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success, let value else { throw WallpaperError("\(name) 查询失败：AX \(result.rawValue)") }
        return value
    }

    private static func element(_ value: CFTypeRef, label: String) throws -> AXUIElement {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw WallpaperError("\(label)格式无效。") }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func readWindows() throws -> [WindowInfo] {
        guard let values = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            throw WallpaperError("系统窗口列表不可用。")
        }
        return try values.map { value in
            guard let number = value[kCGWindowNumber as String] as? NSNumber,
                  let id = UInt32(exactly: number.uint64Value), id != kCGNullWindowID,
                  let ownerNumber = value[kCGWindowOwnerPID as String] as? NSNumber,
                  let owner = pid_t(exactly: ownerNumber.int64Value), owner >= 0,
                  let layer = value[kCGWindowLayer as String] as? Int,
                  let dictionary = value[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary),
                  [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height].allSatisfy(\.isFinite),
                  bounds.width >= 0, bounds.height >= 0 else {
                throw WallpaperError("系统窗口列表缺少有效的标识、进程、层级或范围。")
            }
            return WindowInfo(id: id, owner: owner, layer: layer, bounds: bounds,
                              isSystemCursor: try isSystemCursor(layer: layer, owner: owner))
        }
    }

    private static func isSystemCursor(layer: Int, owner: pid_t) throws -> Bool {
        guard layer == Int(CGWindowLevelForKey(.cursorWindow)) else { return false }
        // A cursor is drawn above the desktop but does not receive its clicks.
        // Verify its system owner; an arbitrary app at the same level still blocks.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE.
        guard proc_pidpath(owner, &path, UInt32(path.count)) > 0 else {
            throw WallpaperError("无法确认光标层窗口的进程身份：进程 \(owner)，系统错误 \(errno)。")
        }
        let executable = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        let windowServer = URL(fileURLWithPath:
            "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer").resolvingSymlinksInPath()
        return executable == windowServer
    }

    static func obstruction(point: CGPoint, target: FinderClickTarget,
                                    windows: [WindowInfo], finderPID: pid_t) -> String? {
        guard let targetWindow = windows.first(where: { $0.id == target.windowID }),
              targetWindow.owner == ProcessInfo.processInfo.processIdentifier,
              targetWindow.bounds.contains(point) else { return "当前壁纸窗口不在点击位置或不再显示。" }
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        for window in windows {
            if window.id == target.windowID { return nil }
            guard window.bounds.contains(point), window.layer >= targetWindow.layer else { continue }
            if window.isSystemCursor { continue }
            if window.owner == finderPID, window.layer == iconLevel { continue }
            return "点击位置被窗口遮挡（窗口 \(window.id)，进程 \(window.owner)，层级 \(window.layer)）。"
        }
        return "壁纸窗口已不在屏幕窗口列表。"
    }
}
