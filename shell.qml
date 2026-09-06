// zhor — what is eating this potato right now.
//
//   qs -p ~/.config/quickshell/zhor                        # run standalone
//   qs -p ~/.config/quickshell/zhor ipc call popup toggle  # bound to SUPER+SHIFT+ESC
//
// Standalone wrapper: puts the Zhor pill in its own layer-shell window next to
// the clock. To embed zhor in your own bar, use Zhor.qml directly (see README).
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

ShellRoot {
    id: root
    property int pillRight: 790      // left of the clock widget (which sits at 678)
    property int pillTop:   8

    // Hide over fullscreen. Read from the workspace, not from the `fullscreen`
    // event (it desyncs when fullscreen ends by a workspace switch); the list is
    // refreshed on every event that can change it, via the socket, no fork.
    readonly property bool fsActive: Hyprland.focusedWorkspace?.hasFullscreen ?? false
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            switch (event.name) {
            case "fullscreen": case "workspace": case "workspacev2":
            case "focusedmon": case "activewindow": case "activewindowv2":
            case "closewindow": case "openwindow": case "movewindowv2":
                Hyprland.refreshWorkspaces()
            }
        }
    }

    IpcHandler {
        target: "popup"
        function toggle(): void { zhor.toggle() }
        function open(): void   { zhor.popupOpen = true }
        function close(): void  { zhor.popupOpen = false }
    }

    PanelWindow {
        visible: !root.fsActive
        anchors { top: true; right: true }
        margins { top: root.pillTop; right: root.pillRight }
        implicitWidth: zhor.implicitWidth
        implicitHeight: zhor.implicitHeight
        color: "transparent"
        WlrLayershell.namespace: "zhor-pill"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        Zhor { id: zhor; anchors.fill: parent; fsActive: root.fsActive }
    }
}
