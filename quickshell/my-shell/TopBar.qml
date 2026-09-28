import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io

Item {
    id: root

    property var targetScreen: null

    // ============================================================
    // EDIT THESE SETTINGS
    // ============================================================

    // Widget dimensions
    readonly property int panelWidth: 340
    readonly property int panelHeight: 44

    // Small trigger bar shown when closed
    readonly property int triggerWidth: 160
    readonly property int triggerHeight: 3

    // Widget border thickness
    readonly property int borderWidth: 2

    // How long opening/closing takes
    readonly property int animationDuration: 100

    // Higher = top bar expands more slowly.
    // 1.0 = same movement as the widget
    // 1.5 = slightly slower
    // 1.8 = slower
    // 2.2 = very slow
    readonly property real triggerExpansionCurve: 0.5

    // Delay before closing after leaving the widget
    readonly property int hideDelay: 300

    // Widget background opacity
    readonly property real panelOpacity: 0.95

    // ============================================================
    // COLORS
    // ============================================================

    readonly property color colBg: "#09152F"
    readonly property color colFg: "#D9CFE0"
    readonly property color colFgBright: "#F3EAF2"
    readonly property color colSelBg: "#2C1F4E"
    readonly property color colAccent: "#EF6261"
    readonly property color colPink: "#B63A6C"
    readonly property color colRose: "#9B346B"
    readonly property color colPurple: "#67315F"
    readonly property color colNavy: "#0F183D"
    readonly property color colViolet: "#5F295D"

    // ============================================================
    // STATE
    // ============================================================

    property bool open: false
    property bool insideTrigger: false
    property bool insideDrawer: false

    // 0 = closed
    // 1 = fully open
    property real progress: 0.0

    // Audio
    property real volumeLevel: 0.70
    property bool isMuted: false

    // ============================================================
    // PROCESSES
    // ============================================================

    Process {
        id: wallflipperProc

        command: [
            "sh",
            "-c",
            "export PATH=$PATH:$HOME/.local/bin:$HOME/bin; wallfliper > /tmp/wallflipper.log 2>&1"
        ]
    }

    Process {
        id: volProc
    }

    function setVolume(pct) {
        volProc.command = [
            "wpctl",
            "set-volume",
            "@DEFAULT_AUDIO_SINK@",
            Math.round(pct * 100) + "%"
        ]

        volProc.running = true
    }

    function toggleMute() {
        volProc.command = [
            "wpctl",
            "set-mute",
            "@DEFAULT_AUDIO_SINK@",
            "toggle"
        ]

        volProc.running = true
    }

    // ============================================================
    // OPEN / CLOSE
    // ============================================================

    function show() {
        hideTimer.stop()

        root.open = true

        revealAnimation.from = root.progress
        revealAnimation.to = 1.0
        revealAnimation.restart()
    }

    function scheduleHide() {
        hideTimer.restart()
    }

    Timer {
        id: hideTimer

        interval: root.hideDelay

        onTriggered: {
            if (!root.insideTrigger && !root.insideDrawer) {
                root.open = false

                revealAnimation.from = root.progress
                revealAnimation.to = 0.0
                revealAnimation.restart()
            }
        }
    }

    NumberAnimation {
        id: revealAnimation

        target: root
        property: "progress"

        duration: root.animationDuration

        easing.type: Easing.OutCubic
    }

    // ============================================================
    // TOP TRIGGER
    //
    // THIS IS THE TOP BORDER.
    //
    // It grows from triggerWidth -> panelWidth while the widget
    // slides down at the same time.
    // ============================================================

    PanelWindow {
        id: trigger

        screen: root.targetScreen

        anchors {
            top: true
        }

        implicitWidth:
        root.triggerWidth +
        (root.panelWidth - root.triggerWidth) *
        Math.pow(root.progress, root.triggerExpansionCurve)

        implicitHeight: root.triggerHeight

        exclusiveZone: 0
        focusable: false
        color: "transparent"

        Rectangle {
            anchors.fill: parent

            color: root.insideTrigger || root.insideDrawer
            ? root.colAccent
            : root.colViolet
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true

            onEntered: {
                root.insideTrigger = true
                root.show()
            }

            onExited: {
                root.insideTrigger = false
                root.scheduleHide()
            }
        }
    }

    // ============================================================
    // DRAWER
    // ============================================================

    PanelWindow {
        id: drawerWindow

        screen: root.targetScreen

        anchors {
            top: true
        }

        implicitWidth: root.panelWidth
        implicitHeight: root.panelHeight

        exclusiveZone: 0
        focusable: true
        color: "transparent"

        visible: root.open || root.progress > 0

        Item {
            anchors.fill: parent
            clip: true

            Rectangle {
                id: panel

                width: parent.width
                height: parent.height

                // Starts completely above the screen.
                // Moves down using the SAME progress as the trigger.
                y: -height + (height * root.progress)

                color: Qt.rgba(
                    root.colBg.r,
                    root.colBg.g,
                    root.colBg.b,
                    root.panelOpacity
                )

                // ====================================================
                // IMPORTANT:
                // NO TOP BORDER HERE.
                //
                // The trigger bar is the top border.
                // ====================================================

                // ====================================================
                // LEFT BORDER
                // ====================================================

                Rectangle {
                    id: leftBorder

                    anchors {
                        top: parent.top
                        left: parent.left
                        bottom: parent.bottom
                    }

                    width: root.borderWidth

                    color: root.insideDrawer
                    ? root.colAccent
                    : root.colViolet

                    Behavior on color {
                        ColorAnimation {
                            duration: 120
                        }
                    }
                }

                // ====================================================
                // RIGHT BORDER
                // ====================================================

                Rectangle {
                    id: rightBorder

                    anchors {
                        top: parent.top
                        right: parent.right
                        bottom: parent.bottom
                    }

                    width: root.borderWidth

                    color: root.insideDrawer
                    ? root.colAccent
                    : root.colViolet

                    Behavior on color {
                        ColorAnimation {
                            duration: 120
                        }
                    }
                }

                // ====================================================
                // BOTTOM BORDER
                // ====================================================

                Rectangle {
                    id: bottomBorder

                    anchors {
                        bottom: parent.bottom
                        left: parent.left
                        right: parent.right
                    }

                    height: root.borderWidth

                    color: root.insideDrawer
                    ? root.colAccent
                    : root.colViolet

                    Behavior on color {
                        ColorAnimation {
                            duration: 120
                        }
                    }
                }

                // ====================================================
                // DRAWER HOVER
                // ====================================================

                HoverHandler {
                    onHoveredChanged: {
                        root.insideDrawer = hovered

                        if (hovered) {
                            hideTimer.stop()
                        } else {
                            root.scheduleHide()
                        }
                    }
                }

                // ====================================================
                // INNER CONTENT
                // ====================================================

                Item {
                    id: innerArea

                    anchors {
                        top: parent.top
                        bottom: bottomBorder.top
                        left: leftBorder.right
                        right: rightBorder.left

                        leftMargin: 10
                        rightMargin: 10
                    }

                    Row {
                        anchors.centerIn: parent

                        width: parent.width
                        height: 28

                        spacing: 12

                        // =================================================
                        // WALL BUTTON
                        // =================================================

                        Rectangle {
                            width: 65
                            height: parent.height

                            color: wallHover.hovered
                            ? root.colSelBg
                            : root.colNavy

                            Behavior on color {
                                ColorAnimation {
                                    duration: 100
                                }
                            }

                            Text {
                                anchors.centerIn: parent

                                text: "WALL"

                                color: wallHover.hovered
                                ? root.colAccent
                                : root.colFgBright

                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 8
                                font.bold: true
                            }

                            HoverHandler {
                                id: wallHover
                            }

                            TapHandler {
                                onTapped: {
                                    wallflipperProc.startDetached()
                                }
                            }
                        }

                        // =================================================
                        // AUDIO CONTROLS
                        // =================================================

                        Row {
                            width: parent.width - 65 - 12
                            height: parent.height

                            spacing: 8

                            // -------------------------------
                            // VOLUME TEXT
                            // -------------------------------

                            Text {
                                anchors.verticalCenter: parent.verticalCenter

                                text: root.isMuted
                                ? "MUT"
                                : Math.round(root.volumeLevel * 100) + "%"

                                color: root.isMuted
                                ? root.colAccent
                                : root.colFgBright

                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 8
                                font.bold: true

                                width: 32
                            }

                            // -------------------------------
                            // VOLUME TRACK
                            // -------------------------------

                            Item {
                                id: volTrack

                                height: 14
                                width: 140

                                anchors.verticalCenter: parent.verticalCenter

                                readonly property int stepCount: 10

                                readonly property var stepColors: [
                                    root.colViolet,
                                    root.colViolet,
                                    root.colPurple,
                                    root.colPurple,
                                    root.colRose,
                                    root.colRose,
                                    root.colPink,
                                    root.colPink,
                                    root.colAccent,
                                    root.colAccent
                                ]

                                Row {
                                    anchors.fill: parent
                                    spacing: 0

                                    Repeater {
                                        model: volTrack.stepCount

                                        Rectangle {
                                            required property int index

                                            width:
                                            volTrack.width /
                                            volTrack.stepCount

                                            height: parent.height

                                            property bool isActive:
                                            !root.isMuted &&
                                            root.volumeLevel >=
                                            ((index + 1) /
                                            volTrack.stepCount)

                                            color: isActive
                                            ? volTrack.stepColors[index]
                                            : root.colNavy

                                            Behavior on color {
                                                ColorAnimation {
                                                    duration: 80
                                                }
                                            }
                                        }
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent

                                    function updateVol(mouse) {
                                        var val = mouse.x / width

                                        root.volumeLevel = Math.max(
                                            0.0,
                                            Math.min(1.0, val)
                                        )

                                        root.isMuted = false
                                        root.setVolume(root.volumeLevel)
                                    }

                                    onPressed: function(mouse) {
                                        updateVol(mouse)
                                    }

                                    onPositionChanged: function(mouse) {
                                        if (pressed) {
                                            updateVol(mouse)
                                        }
                                    }
                                }
                            }

                            // -------------------------------
                            // MUTE BUTTON
                            // -------------------------------

                            Rectangle {
                                width: 44
                                height: parent.height

                                color: muteHover.hovered
                                ? root.colSelBg
                                : root.colNavy

                                Text {
                                    anchors.centerIn: parent

                                    text: root.isMuted
                                    ? "UNM"
                                    : "MUTE"

                                    color: root.isMuted
                                    ? root.colAccent
                                    : root.colFg

                                    font.family: "JetBrainsMono Nerd Font"
                                    font.pixelSize: 7
                                    font.bold: true
                                }

                                HoverHandler {
                                    id: muteHover
                                }

                                TapHandler {
                                    onTapped: {
                                        root.isMuted = !root.isMuted
                                        root.toggleMute()
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
