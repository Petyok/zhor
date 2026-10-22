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
    property real warnC: 80            // pill degree turns amber here…
    property real badC:  95            // …and red here (crit − 10 on this laptop)
    property int  historyLen: 1200     // one hour at the 3 s tick
    property bool thermalOpen: false   // the sensor table is long; closed by default
    property real quietMin: 30         // an alert re-notifies only after this long without it

    // ── state, fed by zhor.py ───────────────────────────────
    property var  psi:    ({ cpu10: 0, mem_full10: 0, io_full10: 0 })
    property var  mem:    ({ avail_mb: 0, total_mb: 0, swap_pct: 0 })
    property var  procs:  []
    property var  alerts: []
    property bool alive:  false
    property bool popupOpen: false
    property string sortKey: "cpu"
    // Thermal block of the tick. `thermal` (the full block, drives the popup) is
    // only updated while the popup is open: the sensor Repeater re-creates ~60
    // delegates on every model change. `pillC` is updated always.
    property var  thermal: null
    property real pillC: NaN
    property var  lastTick: null
    property var  histT: []            // °C per tick, null = unknown (breaks the line)
    property var  histF: []            // freq % per tick
    property var  histFan: []          // rpm per tick
    function degColor(c) { return c >= badC ? cBad : c >= warnC ? cWarn : cText }
    function pushHist(arr, v) { arr.push(v === undefined ? null : v); if (arr.length > historyLen) arr.shift() }
    onPopupOpenChanged: {
        if (popupOpen && lastTick && lastTick.thermal) thermal = lastTick.thermal
        if (popupOpen) Qt.callLater(root.repaintSparks)      // Canvas is only `available` once the window shows
    }
    onThermalOpenChanged: if (thermalOpen) Qt.callLater(root.repaintSparks)
    function repaintSparks() { sparkT.repaint(); sparkF.repaint(); sparkFan.repaint() }

    // A sparkline over one history array. Canvas does not repaint on its own when the
    // array mutates in place, so the owner calls repaint() after each push; a Canvas in
    // a hidden window never paints (available=false), hence repaint on popup open too.
    component Spark: Canvas {
        id: cv
        property var series: []
        property real lo: 0
        property real hi: 100
        property real mark: NaN          // horizontal guide line (warn threshold)
        property string label: ""
        property string current: ""
        width: 240; height: 48
        function repaint() { if (available) requestPaint() }
        onPaint: {
            var ctx = getContext("2d"), w = width, h = height, n = series.length
            var top = 14                     // label band; the plot lives below it
            ctx.clearRect(0, 0, w, h)
            ctx.fillStyle = root.cFaint; ctx.fillRect(0, h - 1, w, 1)
            if (!isNaN(mark) && hi > lo) {
                var ym = h - (mark - lo) / (hi - lo) * (h - top)
                ctx.strokeStyle = root.cWarn; ctx.lineWidth = 1; ctx.setLineDash([3, 3])
                ctx.beginPath(); ctx.moveTo(0, ym); ctx.lineTo(w, ym); ctx.stroke(); ctx.setLineDash([])
            }
            if (n < 2 || hi <= lo) return
            // The x axis spans at least 60 points (3 min) so a young history is still
            // readable, then compresses toward the full hour as points accumulate.
            var span = Math.max(n, 60), step = w / (span - 1), x0 = w - (n - 1) * step
            ctx.lineWidth = 1.5; ctx.strokeStyle = root.cAccent
            ctx.fillStyle = Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.15)
            var pen = false, startX = 0, lastX = 0
            for (var i = 0; i < n; i++) {
                var v = series[i]
                if (v === null || v === undefined) {
                    if (pen) { ctx.stroke(); ctx.lineTo(lastX, h); ctx.lineTo(startX, h); ctx.closePath(); ctx.fill(); pen = false }
                    continue
                }
                var x = x0 + i * step, y = h - Math.min(1, Math.max(0, (v - lo) / (hi - lo))) * (h - top - 2) - 2
                if (!pen) { ctx.beginPath(); ctx.moveTo(x, y); pen = true; startX = x } else ctx.lineTo(x, y)
                lastX = x
            }
            if (pen) { ctx.stroke(); ctx.lineTo(lastX, h); ctx.lineTo(startX, h); ctx.closePath(); ctx.fill() }
        }
        Text { x: 4; y: 2; text: cv.label; color: root.cDim; font.pixelSize: 10; font.family: "monospace" }
        Text { anchors { right: parent.right; rightMargin: 4; top: parent.top; topMargin: 2 } text: cv.current; color: root.cText; font.pixelSize: 10; font.family: "monospace" }
    }
    function toggle() { popupOpen = !popupOpen }

    readonly property bool bad: alerts.length > 0
    readonly property color pillColor: !alive ? cDim
        : bad || psi.cpu10 >= redPsi ? cBad
        : psi.cpu10 >= amberPsi ? cWarn : cAccent
    function fmtMb(mb) { return mb >= 1024 ? (mb / 1024).toFixed(1) + "G" : mb + "M" }
    function alertTitle(kind) {
        return kind === "stall" ? "System stalled" : kind === "throttle" ? "CPU throttling" : "Process stuck"
    }
    function alertBody(a) { return (a.pid ? a.name + " (" + a.pid + ")" : a.name) + " — " + a.why }
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
                    root.lastTick = j
                    root.psi = j.psi; root.mem = j.mem
                    root.procs = j.procs; root.alerts = j.alerts
                    root.alive = true
                    if (j.thermal) {
                        root.pillC = j.thermal.cpu_c === null ? NaN : j.thermal.cpu_c
                        root.pushHist(root.histT, j.thermal.cpu_c)
                        root.pushHist(root.histF, j.thermal.freq_pct)
                        root.pushHist(root.histFan, j.thermal.fan_rpm)
                        if (root.popupOpen) root.thermal = j.thermal
                        if (root.popupOpen && root.thermalOpen) root.repaintSparks()
                    }
                    root.notifyNew(j.alerts)
                } catch (e) { console.log("zhor: bad line:", e) }
            }
        }
        stderr: SplitParser { onRead: data => console.log("zhor.py:", data) }
        onExited: { root.alive = false; respawn.start() }
    }
    Timer { id: respawn; interval: 3000; onTriggered: collector.running = true }

    // One notification per episode, not per flap: throttling and temperature hover
    // around their thresholds and would re-raise every few ticks. A key stays quiet
    // until it has been absent for quietMin; every live tick pushes that further.
    property var lastLive: ({})        // "kind:pid" -> ms of the last tick it was live
    function notifyNew(list) {
        var now = Date.now(), quiet = root.quietMin * 60000, next = {}
        for (var k in lastLive) if (now - lastLive[k] < quiet) next[k] = lastLive[k]
        for (var i = 0; i < list.length; i++) {
            var a = list[i], key = a.kind + ":" + a.pid
            if (!(key in next))
                Quickshell.execDetached(["notify-send", "-a", "zhor", "-u", "critical",
                    root.alertTitle(a.kind), root.alertBody(a)])
            next[key] = now
        }
        lastLive = next
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
            Text {
                visible: root.alive && !isNaN(root.pillC)
                anchors.verticalCenter: parent.verticalCenter
                text: Math.round(root.pillC) + "°"
                color: root.degColor(root.pillC)
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
                Text {
                    visible: root.thermal !== null && root.thermal.cpu_c !== null
                    readonly property var t: root.thermal ?? ({})
                    text: {
                        var s = []
                        if (t.cpu_c !== null && t.cpu_c !== undefined) s.push("cpu " + t.cpu_c + "°")
                        if (t.freq_mhz) s.push((t.freq_mhz / 1000).toFixed(1) + " GHz" + (t.freq_pct !== null && t.freq_pct !== undefined ? " (" + t.freq_pct + "%)" : ""))
                        if (t.fan_rpm !== null && t.fan_rpm !== undefined) s.push("fan " + t.fan_rpm)
                        if (t.bat_c !== null && t.bat_c !== undefined) s.push("bat " + t.bat_c + "°")
                        if (t.turbo === false) s.push("turbo off")
                        return s.join("  ")
                    }
                    color: root.cDim; font.pixelSize: 12; font.family: "monospace"
                }
                Column {
                    id: thermalSec
                    visible: root.thermal !== null && root.thermal.cpu_c !== null
                    width: body.width
                    spacing: 6
                    readonly property var t: root.thermal ?? ({})
                    Text {
                        text: (root.thermalOpen ? "▾ " : "▸ ") + "thermal"
                        color: root.cDim; font.pixelSize: 11; font.family: "monospace"
                        MouseArea { anchors.fill: parent; onClicked: root.thermalOpen = !root.thermalOpen }
                    }
                    Row {
                        visible: root.thermalOpen
                        spacing: 6
                        readonly property real cw: (body.width - 12) / 3
                        Spark { id: sparkT; width: parent.cw; series: root.histT; lo: 30; hi: thermalSec.t.crit_c ?? 100; mark: root.warnC
                                label: "cpu °C"; current: (thermalSec.t.cpu_c ?? null) !== null ? thermalSec.t.cpu_c + "°" : "" }
                        Spark { id: sparkF; width: parent.cw; series: root.histF; lo: 0; hi: 100
                                label: "freq %"; current: (thermalSec.t.freq_pct ?? null) !== null ? thermalSec.t.freq_pct + "%" : "" }
                        Spark { id: sparkFan; width: parent.cw; series: root.histFan; lo: 0; hi: thermalSec.t.fan_max ?? 6500
                                label: "fan rpm"; current: (thermalSec.t.fan_rpm ?? null) !== null ? thermalSec.t.fan_rpm + "" : "" }
                    }
                    Grid {
                        visible: root.thermalOpen
                        columns: 4; columnSpacing: 8; rowSpacing: 2   // 4 sensors per row: 31 sensors → 8 rows
                        Repeater {
                            model: thermalSec.t.extra ?? []
                            // Each sensor is a name/°C pair.
                            Row {
                                spacing: 6
                                Text { text: modelData.name; color: root.cDim; font.pixelSize: 11; font.family: "monospace"; width: 60; elide: Text.ElideRight }
                                Text { text: modelData.c + "°"; color: root.degColor(modelData.c); font.pixelSize: 11; font.family: "monospace"; width: 36 }
                            }
                        }
                    }
                }
                Repeater {
                    model: root.alerts
                    Text {
                        width: body.width
                        text: "⚠ " + root.alertBody(modelData)
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
