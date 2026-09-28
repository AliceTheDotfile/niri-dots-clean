import Quickshell
import Quickshell.Wayland
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

    Column {
        anchors.centerIn: parent

        spacing: 8

        Text {
            anchors.horizontalCenter: parent.horizontalCenter

            text: Qt.formatDateTime(clock.date, "HH:mm:ss")

            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: 120
            font.weight: Font.Medium

            color: "#D9CFE0"
        }

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
