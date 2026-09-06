// zhor as a component: drop this Item into any Quickshell bar.
//
//   import "zhor" as Z      // the zhor checkout must live INSIDE your config dir
//   Z.Zhor { fsActive: yourFullscreenFlag }
//
// The pill is this Item; the process list is a window the component owns.
// Nothing here decides anything — zhor.py measures and flags, this draws and
// forwards the click a human made. No process is ever touched automatically.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

Item {
    id: root
    implicitWidth: pillRect.implicitWidth
    implicitHeight: 34

    // ── inputs ──────────────────────────────────────────────
    property bool fsActive: false      // hide the popup over fullscreen windows
    property real amberPsi:  20
    property real redPsi:    50
    property color cBg:     "#e6141826"
    property color cAccent: "#b69ad6"
    property color cText:   "#eef1fa"
    property color cDim:    "#a6b6c4d8"
    property color cFaint:  "#33ffffff"
    property color cWarn:   "#e8b34a"
    property color cBad:    "#e05561"
    property color cPill:   cBg        // pill background; a host bar may pass its own
    property int   pillRadius: 17

    // ── state, fed by zhor.py ───────────────────────────────
    property var  psi:    ({ cpu10: 0, mem_full10: 0, io_full10: 0 })
    property var  mem:    ({ avail_mb: 0, total_mb: 0, swap_pct: 0 })
    property var  procs:  []
    property var  alerts: []
    property bool alive:  false
    property bool popupOpen: false
    property string sortKey: "cpu"
    function toggle() { popupOpen = !popupOpen }

    readonly property bool bad: alerts.length > 0
    readonly property color pillColor: !alive ? cDim
        : bad || psi.cpu10 >= redPsi ? cBad
        : psi.cpu10 >= amberPsi ? cWarn : cAccent
    function fmtMb(mb) { return mb >= 1024 ? (mb / 1024).toFixed(1) + "G" : mb + "M" }
    readonly property var sorted: {
        var a = procs.slice()
        a.sort(root.sortKey === "cpu" ? (x, y) => y.cpu - x.cpu : (x, y) => y.rss_mb - x.rss_mb)
        return a
    }

    // zhor.py sits next to this file. Quickshell.shellPath() resolves against the
    // config ROOT, which is a different directory when zhor is embedded in a bar.
    readonly property string script: new URL(Qt.resolvedUrl("zhor.py")).pathname

    Process {
        id: collector
        command: ["python3", root.script, "watch"]
        running: true
        stdout: SplitParser {
            onRead: data => {
                try {
                    var j = JSON.parse(data)
                    root.psi = j.psi; root.mem = j.mem
                    root.procs = j.procs; root.alerts = j.alerts
                    root.alive = true
                    root.notifyNew(j.alerts)
                } catch (e) { console.log("zhor: bad line:", e) }
            }
        }
        stderr: SplitParser { onRead: data => console.log("zhor.py:", data) }
        onExited: { root.alive = false; respawn.start() }
    }
    Timer { id: respawn; interval: 3000; onTriggered: collector.running = true }

    property var notified: ({})
    function notifyNew(list) {
        var live = {}
        for (var i = 0; i < list.length; i++) {
            var a = list[i], key = a.kind + ":" + a.pid
            live[key] = true
            if (!notified[key]) {
                Quickshell.execDetached(["notify-send", "-a", "zhor", "-u", "critical",
                    a.kind === "stall" ? "System stalled" : "Process stuck",
                    a.name + " (" + a.pid + ") — " + a.why])
            }
        }
        notified = live
    }
    function act(argv) { Quickshell.execDetached(argv) }

    // ── the pill ────────────────────────────────────────────
    Rectangle {
        id: pillRect
        anchors.fill: parent
        implicitWidth: pillRow.implicitWidth + 24
        radius: root.pillRadius
        color: root.cPill
        border.width: 1
        border.color: root.bad ? root.cBad : root.cFaint
        Row {
            id: pillRow
            anchors.centerIn: parent
            spacing: 10
            Rectangle {
                width: 8; height: 8; radius: 4
                anchors.verticalCenter: parent.verticalCenter
                color: root.pillColor
                SequentialAnimation on opacity {
                    running: root.bad; loops: Animation.Infinite
                    NumberAnimation { to: 0.25; duration: 500 }
                    NumberAnimation { to: 1.0;  duration: 500 }
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.alive
                    ? Math.round(root.psi.cpu10) + "%  " + root.fmtMb(root.mem.avail_mb) + "  z" + root.mem.swap_pct + "%"
                    : "zhor ?"
                color: root.cText
                font.pixelSize: 13
                font.family: "monospace"
            }
        }
        MouseArea { anchors.fill: parent; onClicked: root.toggle() }
    }

    // ── the list ────────────────────────────────────────────
    // Click-away is a focus grab, not a transparent catcher window: a catcher on
    // the Top layer would also cover a bar living on Top and eat its clicks.
    HyprlandFocusGrab {
        windows: [popup]
        active: root.popupOpen
        onCleared: root.popupOpen = false
    }
    PanelWindow {
        id: popup
        visible: root.popupOpen && !root.fsActive
        anchors { top: true }
        margins { top: 56 }
        implicitWidth: 760
        implicitHeight: body.implicitHeight + 28
        color: "transparent"
        WlrLayershell.namespace: "zhor"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        exclusionMode: ExclusionMode.Ignore

        Rectangle {
            anchors.fill: parent
            radius: 14
            color: root.cBg
            border.width: 1
            border.color: root.cFaint
            focus: root.popupOpen
            Keys.onEscapePressed: root.popupOpen = false

            Column {
                id: body
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
                spacing: 6
                Row {
                    spacing: 18
                    Text {
                        text: "PSI cpu " + root.psi.cpu10.toFixed(1) + "%   mem " + root.psi.mem_full10.toFixed(1) + "%   io " + root.psi.io_full10.toFixed(1) + "%"
                        color: root.psi.mem_full10 >= 10 ? root.cBad : root.cDim
                        font.pixelSize: 12; font.family: "monospace"
                    }
                    Text {
                        text: "free " + root.fmtMb(root.mem.avail_mb) + " / " + root.fmtMb(root.mem.total_mb) + "   zram " + root.mem.swap_pct + "%"
                        color: root.mem.swap_pct >= 90 ? root.cWarn : root.cDim
                        font.pixelSize: 12; font.family: "monospace"
                    }
                }
                Repeater {
                    model: root.alerts
                    Text {
                        width: body.width
                        text: "⚠ " + modelData.name + " (" + modelData.pid + ") — " + modelData.why
                        color: root.cBad; font.pixelSize: 12; font.bold: true; elide: Text.ElideRight
                    }
                }
                Rectangle { width: body.width; height: 1; color: root.cFaint }
                Row {
                    spacing: 0
                    Text { width: 250; text: "process"; color: root.cDim; font.pixelSize: 11; font.family: "monospace" }
                    Text { width: 70; horizontalAlignment: Text.AlignRight; text: "CPU%"; font.pixelSize: 11; font.family: "monospace"
                           color: root.sortKey === "cpu" ? root.cAccent : root.cDim
                           MouseArea { anchors.fill: parent; onClicked: root.sortKey = "cpu" } }
                    Text { width: 70; horizontalAlignment: Text.AlignRight; text: "RSS"; font.pixelSize: 11; font.family: "monospace"
                           color: root.sortKey === "rss" ? root.cAccent : root.cDim
                           MouseArea { anchors.fill: parent; onClicked: root.sortKey = "rss" } }
                    Text { width: 70; horizontalAlignment: Text.AlignRight; text: "swap"; color: root.cDim; font.pixelSize: 11; font.family: "monospace" }
                    Text { width: 60; horizontalAlignment: Text.AlignRight; text: "hot"; color: root.cDim; font.pixelSize: 11; font.family: "monospace" }
                    Item { width: 12; height: 1 }
                    Text { width: 170; text: "  stop  nice  kill"; color: root.cDim; font.pixelSize: 11; font.family: "monospace" }
                }
                Repeater {
                    model: root.sorted
                    Row {
                        id: line
                        spacing: 0
                        readonly property var proc: modelData
                        readonly property bool mine: modelData.mine
                        property bool armed: false
                        Timer { id: disarm; interval: 5000; onTriggered: line.armed = false }
                        readonly property bool stopped: modelData.state === "T"
                        Text { width: 250; elide: Text.ElideRight; text: modelData.name + "  " + modelData.pid
                               color: line.stopped ? root.cWarn : root.cText; font.pixelSize: 12; font.family: "monospace" }
                        Text { width: 70; horizontalAlignment: Text.AlignRight; text: modelData.cpu.toFixed(0)
                               color: modelData.cpu >= 90 ? root.cWarn : root.cText; font.pixelSize: 12; font.family: "monospace" }
                        Text { width: 70; horizontalAlignment: Text.AlignRight; text: root.fmtMb(modelData.rss_mb)
                               color: modelData.rss_pct >= 25 ? root.cWarn : root.cText; font.pixelSize: 12; font.family: "monospace" }
                        Text { width: 70; horizontalAlignment: Text.AlignRight; text: modelData.swap_mb > 0 ? root.fmtMb(modelData.swap_mb) : "·"
                               color: root.cDim; font.pixelSize: 12; font.family: "monospace" }
                        Text { width: 60; horizontalAlignment: Text.AlignRight; text: modelData.hot_s > 0 ? Math.round(modelData.hot_s) + "s" : "·"
                               color: modelData.hot_s >= 60 ? root.cBad : root.cDim; font.pixelSize: 12; font.family: "monospace" }
                        Item { width: 12; height: 1 }
                        Repeater {
                            model: [
                                { t: line.stopped ? "▶" : "⏸", w: 44, argv: ["kill", line.stopped ? "-CONT" : "-STOP", String(line.proc.pid)] },
                                { t: "↓19", w: 52, argv: ["renice", "-n", "19", "-p", String(line.proc.pid)] },
                                { t: line.armed ? "KILL" : "✕", w: 62, argv: ["kill", line.armed ? "-KILL" : "-TERM", String(line.proc.pid)] },
                            ]
                            Rectangle {
                                width: modelData.w - 4; height: 20; radius: 5
                                anchors.verticalCenter: parent.verticalCenter
                                color: btn.containsMouse ? root.cFaint : "transparent"
                                border.width: 1; border.color: root.cFaint
                                opacity: line.mine ? 1.0 : 0.3
                                Text { anchors.centerIn: parent; text: modelData.t
                                       color: modelData.t === "KILL" ? root.cBad : root.cText; font.pixelSize: 11; font.family: "monospace" }
                                MouseArea {
                                    id: btn
                                    anchors.fill: parent
                                    enabled: line.mine; hoverEnabled: line.mine
                                    property var argv: modelData.argv
                                    onClicked: {
                                        root.act(argv)
                                        if (argv[1] === "-TERM") { line.armed = true; disarm.restart() }
                                        else if (argv[1] === "-KILL") line.armed = false
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
