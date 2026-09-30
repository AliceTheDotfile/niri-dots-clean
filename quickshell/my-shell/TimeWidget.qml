import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import QtQuick

PanelWindow {
    id: root

    required property var targetScreen

    screen: targetScreen

    color: "transparent"

    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    exclusionMode: ExclusionMode.Ignore

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    // Completely click-through
    mask: Region {}

    // System metrics tracking
    property int cpuUsage: 0
    property string ramDisplay: "0MB"

    property real memTotalKb: 0
    property real memAvailKb: 0
    property real prevCpuIdle: 0
    property real prevCpuTotal: 0

    // Process to pull system stats cleanly from procfs
    Process {
        id: statsProc
        command: ["sh", "-c", "head -n 1 /proc/stat; grep -E 'MemTotal|MemAvailable' /proc/meminfo"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                var output = this.text;
                if (!output) return;

                var lines = output.trim().split("\n");

                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i];

                    // --- Parse CPU Usage ---
                    if (line.startsWith("cpu ")) {
                        var parts = line.trim().split(/\s+/);
                        if (parts.length >= 8) {
                            var user = parseFloat(parts[1]);
                            var nice = parseFloat(parts[2]);
                            var system = parseFloat(parts[3]);
                            var idle = parseFloat(parts[4]);
                            var iowait = parseFloat(parts[5]);
                            var irq = parseFloat(parts[6]);
                            var softirq = parseFloat(parts[7]);

                            var currentIdle = idle + iowait;
                            var currentTotal = user + nice + system + idle + iowait + irq + softirq;

                            var totalDelta = currentTotal - root.prevCpuTotal;
                            var idleDelta = currentIdle - root.prevCpuIdle;

                            if (totalDelta > 0) {
                                root.cpuUsage = Math.max(0, Math.round(((totalDelta - idleDelta) / totalDelta) * 100));
                            }

                            root.prevCpuIdle = currentIdle;
                            root.prevCpuTotal = currentTotal;
                        }
                    }
                    // --- Parse RAM Usage ---
                    else if (line.startsWith("MemTotal:")) {
                        var totalMatch = line.match(/\d+/);
                        if (totalMatch) root.memTotalKb = parseFloat(totalMatch[0]);
                    } else if (line.startsWith("MemAvailable:")) {
                        var availMatch = line.match(/\d+/);
                        if (availMatch) root.memAvailKb = parseFloat(availMatch[0]);
                    }
                }

                if (root.memTotalKb > 0) {
                    var usedKb = root.memTotalKb - root.memAvailKb;
                    var usedMb = usedKb / 1024;
                    var usedGb = usedMb / 1024;

                    if (usedGb >= 1.0) {
                        root.ramDisplay = usedGb.toFixed(1) + "GB";
                    } else {
                        root.ramDisplay = Math.round(usedMb) + "MB";
                    }
                }
            }
        }
    }

    Timer {
        id: sysStatsTimer
        interval: 3000 // Sample stats every 3 seconds
        running: true
        repeat: true
        triggeredOnStart: true

        onTriggered: {
            statsProc.running = false;
            statsProc.running = true;
        }
    }

    Column {
        anchors.centerIn: parent
        spacing: 0

        // Minimal CPU & RAM Status Line
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 32

            Text {
                text: "CPU " + root.cpuUsage + "%"
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 24
                font.weight: Font.Normal
                color: "#D9CFE0"
            }

            Text {
                text: "RAM " + root.ramDisplay
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 24
                font.weight: Font.Normal
                color: "#D9CFE0"
            }
        }

        // Tighter gap between CPU/RAM line and Time text
        Item { width: 1; height: 2 }

        // Time Text
        Text {
            anchors.horizontalCenter: parent.horizontalCenter

            text: Qt.formatDateTime(clock.date, "HH:mm:ss")

            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: 120
            font.weight: Font.Medium

            color: "#D9CFE0"
        }

        // Spacing above Date text
        Item { width: 1; height: 12 }

        // Date Text
        Text {
            anchors.horizontalCenter: parent.horizontalCenter

            text: Qt.formatDateTime(clock.date, "dddd, MMMM d, yyyy")

            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: 24
            font.weight: Font.Normal

            color: "#D9CFE0"
        }
    }

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }
}
