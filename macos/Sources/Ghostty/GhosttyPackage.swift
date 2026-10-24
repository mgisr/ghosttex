import os
import SwiftUI
import GhosttyKit

// MARK: C Extensions

extension Ghostty {
    // The user notification category identifier
    static let userNotificationCategory = "org.ghosttex.terminal.userNotification"

    // The user notification "Show" action
    static let userNotificationActionShow = "org.ghosttex.terminal.userNotification.Show"
}

// MARK: Build Info

extension Ghostty {
    struct Info {
        var mode: ghostty_build_mode_e
        var version: String
    }

    static var info: Info {
        let raw = ghostty_info()
        let version = NSString(
            bytes: raw.version,
            length: Int(raw.version_len),
            encoding: NSUTF8StringEncoding
        ) ?? "unknown"

        return Info(mode: raw.build_mode, version: String(version))
    }
}

// MARK: General Helpers

extension Ghostty {
    enum LaunchSource: String {
        case cli
        case app
        case zig_run
    }

    /// Returns the mechanism that launched the app. This is based on an env var so
    /// its up to the env var being set in the correct circumstance.
    static var launchSource: LaunchSource {
        guard let envValue = ProcessInfo.processInfo.environment["GHOSTTY_MAC_LAUNCH_SOURCE"] else {
            // We default to the CLI because the app bundle always sets the
            // source. If its unset we assume we're in a CLI environment.
            return .cli
        }

        // If the env var is set but its unknown then we default back to the app.
        return LaunchSource(rawValue: envValue) ?? .app
    }
}

// MARK: Swift Types for C Types

extension Ghostty {
    class AllocatedString {
        private let cString: ghostty_string_s

        init(_ c: ghostty_string_s) {
            self.cString = c
        }

        var string: String {
            guard let ptr = cString.ptr else { return "" }
            let data = Data(bytes: ptr, count: Int(cString.len))
            return String(data: data, encoding: .utf8) ?? ""
        }

        deinit {
            ghostty_string_free(cString)
        }
    }
}

extension Ghostty {
    enum SetFloatWIndow {
        case on
        case off
        case toggle

        static func from(_ c: ghostty_action_float_window_e) -> Self? {
            switch c {
            case GHOSTTY_FLOAT_WINDOW_ON:
                return .on

            case GHOSTTY_FLOAT_WINDOW_OFF:
                return .off

            case GHOSTTY_FLOAT_WINDOW_TOGGLE:
                return .toggle

            default:
                return nil
            }
        }
    }

    enum SetSecureInput {
        case on
        case off
        case toggle

        static func from(_ c: ghostty_action_secure_input_e) -> Self? {
            switch c {
            case GHOSTTY_SECURE_INPUT_ON:
                return .on

            case GHOSTTY_SECURE_INPUT_OFF:
                return .off

            case GHOSTTY_SECURE_INPUT_TOGGLE:
                return .toggle

            default:
                return nil
            }
        }
    }

    /// An enum that is used for the directions that a split focus event can change.
    enum SplitFocusDirection {
        case previous, next, up, down, left, right

        /// Initialize from a Ghostty API enum.
        static func from(direction: ghostty_action_goto_split_e) -> Self? {
            switch direction {
            case GHOSTTY_GOTO_SPLIT_PREVIOUS:
                return .previous

            case GHOSTTY_GOTO_SPLIT_NEXT:
                return .next

            case GHOSTTY_GOTO_SPLIT_UP:
                return .up

            case GHOSTTY_GOTO_SPLIT_DOWN:
                return .down

            case GHOSTTY_GOTO_SPLIT_LEFT:
                return .left

            case GHOSTTY_GOTO_SPLIT_RIGHT:
                return .right

            default:
                return nil
            }
        }

        func toNative() -> ghostty_action_goto_split_e {
            switch self {
            case .previous:
                return GHOSTTY_GOTO_SPLIT_PREVIOUS

            case .next:
                return GHOSTTY_GOTO_SPLIT_NEXT

            case .up:
                return GHOSTTY_GOTO_SPLIT_UP

            case .down:
                return GHOSTTY_GOTO_SPLIT_DOWN

            case .left:
                return GHOSTTY_GOTO_SPLIT_LEFT

            case .right:
                return GHOSTTY_GOTO_SPLIT_RIGHT
            }
        }
    }

    /// Enum used for resizing splits. This is the direction the split divider will move.
    enum SplitResizeDirection {
        case up, down, left, right

        static func from(direction: ghostty_action_resize_split_direction_e) -> Self? {
            switch direction {
            case GHOSTTY_RESIZE_SPLIT_UP:
                return .up
            case GHOSTTY_RESIZE_SPLIT_DOWN:
                return .down
            case GHOSTTY_RESIZE_SPLIT_LEFT:
                return .left
            case GHOSTTY_RESIZE_SPLIT_RIGHT:
                return .right
            default:
                return nil
            }
        }

        func toNative() -> ghostty_action_resize_split_direction_e {
            switch self {
            case .up:
                return GHOSTTY_RESIZE_SPLIT_UP
            case .down:
                return GHOSTTY_RESIZE_SPLIT_DOWN
            case .left:
                return GHOSTTY_RESIZE_SPLIT_LEFT
            case .right:
                return GHOSTTY_RESIZE_SPLIT_RIGHT
            }
        }
    }
}

// MARK: SplitFocusDirection Extensions

extension Ghostty.SplitFocusDirection {
    /// Convert to a SplitTree.FocusDirection for the given ViewType.
    func toSplitTreeFocusDirection<ViewType>() -> SplitTree<ViewType>.FocusDirection {
        switch self {
        case .previous:
            return .previous

        case .next:
            return .next

        case .up:
            return .spatial(.up)

        case .down:
            return .spatial(.down)

        case .left:
            return .spatial(.left)

        case .right:
            return .spatial(.right)
        }
    }
}

extension Ghostty {
    /// One representation of clipboard contents. The data is binary-safe;
    /// textual consumers use `string`.
    struct ClipboardContent {
        let mime: String
        let data: Data

        /// The data as text, if it is valid UTF-8.
        var string: String? { String(data: data, encoding: .utf8) }

        static func from(content: ghostty_clipboard_content_s) -> ClipboardContent? {
            guard let mimePtr = content.mime,
                  let dataPtr = content.data else {
                return nil
            }

            let data: Data = if content.len > 0 {
                Data(bytes: dataPtr, count: content.len)
            } else {
                Data()
            }

            return ClipboardContent(
                mime: String(cString: mimePtr),
                data: data
            )
        }
    }

    /// Enum for the macos-window-buttons config option
    enum MacOSWindowButtons: String {
        case visible
        case hidden
    }

    /// Enum for the macos-titlebar-proxy-icon config option
    enum MacOSTitlebarProxyIcon: String {
        case visible
        case hidden
    }

    /// Enum for auto-update-channel config option
    enum AutoUpdateChannel: String {
        case tip
        case stable
    }
}

// MARK: Surface Notification

extension Notification.Name {
    /// Configuration change. If the object is nil then it is app-wide. Otherwise its surface-specific.
    static let ghosttyConfigDidChange = Notification.Name("org.ghosttex.terminal.configDidChange")
    static let GhosttyConfigChangeKey = ghosttyConfigDidChange.rawValue

    /// Color change. Object is the surface changing.
    static let ghosttyColorDidChange = Notification.Name("org.ghosttex.terminal.ghosttyColorDidChange")
    static let GhosttyColorChangeKey = ghosttyColorDidChange.rawValue

    /// Goto tab. Has tab index in the userinfo.
    static let ghosttyMoveTab = Notification.Name("org.ghosttex.terminal.moveTab")
    static let GhosttyMoveTabKey = ghosttyMoveTab.rawValue

    /// Close tab
    static let ghosttyCloseTab = Notification.Name("org.ghosttex.terminal.closeTab")

    /// Close other tabs
    static let ghosttyCloseOtherTabs = Notification.Name("org.ghosttex.terminal.closeOtherTabs")

    /// Close tabs to the right of the focused tab
    static let ghosttyCloseTabsOnTheRight = Notification.Name("org.ghosttex.terminal.closeTabsOnTheRight")

    /// Close window
    static let ghosttyCloseWindow = Notification.Name("org.ghosttex.terminal.closeWindow")

    /// Resize the window to a default size.
    static let ghosttyResetWindowSize = Notification.Name("org.ghosttex.terminal.resetWindowSize")

    /// Ring the bell
    static let ghosttyBellDidRing = Notification.Name("org.ghosttex.terminal.ghosttyBellDidRing")

    /// The active selection changed
    static let ghosttySelectionDidChange = Notification.Name("org.ghosttex.terminal.ghosttySelectionDidChange")

    /// Readonly mode changed
    static let ghosttyDidChangeReadonly = Notification.Name("org.ghosttex.terminal.didChangeReadonly")
    static let ReadonlyKey = ghosttyDidChangeReadonly.rawValue + ".readonly"
    static let ghosttyCommandPaletteDidToggle = Notification.Name("org.ghosttex.terminal.commandPaletteDidToggle")

    /// Toggle maximize of current window
    static let ghosttyMaximizeDidToggle = Notification.Name("org.ghosttex.terminal.maximizeDidToggle")

    /// Notification sent when scrollbar updates
    static let ghosttyDidUpdateScrollbar = Notification.Name("org.ghosttex.terminal.didUpdateScrollbar")
    static let ScrollbarKey = ghosttyDidUpdateScrollbar.rawValue + ".scrollbar"

    /// Focus the search field
    static let ghosttySearchFocus = Notification.Name("org.ghosttex.terminal.searchFocus")
}

// NOTE: I am moving all of these to Notification.Name extensions over time. This
// namespace was the old namespace.
extension Ghostty.Notification {
    /// Used to pass a configuration along when creating a new tab/window/split.
    static let NewSurfaceConfigKey = "org.ghosttex.terminal.newSurfaceConfig"

    /// Posted when a new split is requested. The sending object will be the surface that had focus. The
    /// userdata has one key "direction" with the direction to split to.
    static let ghosttyNewSplit = Notification.Name("org.ghosttex.terminal.newSplit")

    /// Close the calling surface.
    static let ghosttyCloseSurface = Notification.Name("org.ghosttex.terminal.closeSurface")

    /// Focus previous/next split. Has a SplitFocusDirection in the userinfo.
    static let ghosttyFocusSplit = Notification.Name("org.ghosttex.terminal.focusSplit")
    static let SplitDirectionKey = ghosttyFocusSplit.rawValue

    /// Goto tab. Has tab index in the userinfo.
    static let ghosttyGotoTab = Notification.Name("org.ghosttex.terminal.gotoTab")
    static let GotoTabKey = ghosttyGotoTab.rawValue

    /// New tab. Has base surface config requested in userinfo.
    static let ghosttyNewTab = Notification.Name("org.ghosttex.terminal.newTab")

    /// New window. Has base surface config requested in userinfo.
    static let ghosttyNewWindow = Notification.Name("org.ghosttex.terminal.newWindow")

    /// Present terminal. Bring the surface's window to focus without activating the app.
    static let ghosttyPresentTerminal = Notification.Name("org.ghosttex.terminal.presentTerminal")

    /// Toggle fullscreen of current window
    static let ghosttyToggleFullscreen = Notification.Name("org.ghosttex.terminal.toggleFullscreen")
    static let FullscreenModeKey = ghosttyToggleFullscreen.rawValue

    /// Notification sent to toggle split maximize/unmaximize.
    static let didToggleSplitZoom = Notification.Name("org.ghosttex.terminal.didToggleSplitZoom")

    /// Notification
    static let didReceiveInitialWindowFrame = Notification.Name("org.ghosttex.terminal.didReceiveInitialWindowFrame")
    static let FrameKey = "org.ghosttex.terminal.frame"

    /// Notification to render the inspector for a surface
    static let inspectorNeedsDisplay = Notification.Name("org.ghosttex.terminal.inspectorNeedsDisplay")

    /// Notification to show/hide the inspector
    static let didControlInspector = Notification.Name("org.ghosttex.terminal.didControlInspector")

    /// Notification sent to the active split view to resize the split.
    static let didResizeSplit = Notification.Name("org.ghosttex.terminal.didResizeSplit")
    static let ResizeSplitDirectionKey = didResizeSplit.rawValue + ".direction"
    static let ResizeSplitAmountKey = didResizeSplit.rawValue + ".amount"

    /// Notification sent to the split root to equalize split sizes
    static let didEqualizeSplits = Notification.Name("org.ghosttex.terminal.didEqualizeSplits")

    /// Notification that renderer health changed
    static let didUpdateRendererHealth = Notification.Name("org.ghosttex.terminal.didUpdateRendererHealth")

    /// Notifications related to key sequences
    static let didContinueKeySequence = Notification.Name("org.ghosttex.terminal.didContinueKeySequence")
    static let didEndKeySequence = Notification.Name("org.ghosttex.terminal.didEndKeySequence")
    static let KeySequenceKey = didContinueKeySequence.rawValue + ".key"

    /// Notifications related to key tables
    static let didChangeKeyTable = Notification.Name("org.ghosttex.terminal.didChangeKeyTable")
    static let KeyTableKey = didChangeKeyTable.rawValue + ".action"
}

// Make the input enum hashable.
extension ghostty_input_key_e: @retroactive Hashable {}
