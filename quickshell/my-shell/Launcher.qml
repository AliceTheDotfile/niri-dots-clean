import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Widgets

Item {
    id: root

    property var targetScreen: null

    // ============================================================
    // EDIT THESE SETTINGS
    // ============================================================

    // Launcher size
    readonly property int panelWidth: 620
    readonly property int panelHeight: 360

    // Bottom trigger
    readonly property int triggerWidth: 260
    readonly property int triggerHeight: 3

    // Launcher border thickness
    readonly property int borderWidth: 2

    // Animation speeds (in ms)
    readonly property int panelAnimationDuration: 250
    readonly property int triggerAnimationDuration: 500 // Independent speed for bar expansion

    // Higher = trigger expands more slowly across its own timeline.
    // 1.0 = linear
    // 1.2 = smooth, natural tracking
    readonly property real triggerExpansionCurve: 0.6

    // Delay before closing
    readonly property int hideDelay: 300

    // Launcher opacity
    readonly property real panelOpacity: 0.96

    // ============================================================
    // PALETTE
    // ============================================================

    readonly property color colBg: "#09152F"
    readonly property color colFg: "#D9CFE0"
    readonly property color colFgBright: "#F3EAF2"
    readonly property color colSelBg: "#2C1F4E"
    readonly property color colAccent: "#EF6261"
    readonly property color colPink: "#B63A6C"
    readonly property color colRose: "#9B346B"
    readonly property color colViolet: "#5F295D"
    readonly property color colPurple: "#67315F"
    readonly property color colNavy: "#0F183D"

    // ============================================================
    // STATE
    // ============================================================

    property bool open: false
    property bool insideTrigger: false
    property bool insideLauncher: false

    // 0 = closed, 1 = fully open
    property real progress: 0.0
    property real triggerProgress: 0.0

    property real volumeLevel: 0.70
    property bool isMuted: false

    // ---- search query state ----
    property string searchQuery: ""

    // ---- unified border color ----
    readonly property color currentBorderColor:
    root.insideLauncher
    ? root.colAccent
    : root.colViolet

    // ============================================================
    // SORTING & FILTERING
    // ============================================================

    property string sortMode: "A-Z"

    readonly property var sortModes: [
        "A-Z",
        "Z-A",
        "Category"
    ]

    readonly property var categoryMap: {
        return {
            "Internet": ["Network", "WebBrowser", "Email"],
            "Development": ["Development", "IDE"],
            "Media": ["AudioVideo", "Audio", "Video", "Player"],
            "Graphics": ["Graphics", "VectorGraphics", "RasterGraphics"],
            "Office": ["Office", "WordProcessor", "Spreadsheet"],
            "System": ["System", "Settings", "TerminalEmulator", "FileManager"],
            "Utilities": ["Utility", "Core", "Archiving"]
        }
    }

    function getAppCategory(app) {
        const cats = app.categories || []

        for (const [groupName, matchCats] of Object.entries(root.categoryMap)) {
            if (cats.some(c => matchCats.includes(c)))
                return groupName
        }

        return "Utilities"
    }

    function getCategoryColor(category) {
        switch (category) {
            case "Internet":
                return root.colAccent

            case "Development":
                return root.colPink

            case "Media":
                return root.colRose

            case "Graphics":
                return root.colPurple

            case "Office":
                return root.colFgBright

            case "System":
                return root.colViolet

            case "Utilities":
                return root.colNavy

            default:
                return root.colSelBg
        }
    }

    function getSortColor(mode) {
        switch (mode) {
            case "A-Z":
                return root.colAccent

            case "Z-A":
                return root.colPink

            case "Category":
                return root.colRose

            default:
                return root.colAccent
        }
    }

    function getIconSource(icon) {
        if (!icon || icon.length === 0)
            return Quickshell.iconPath("application-x-executable")

            if (icon.startsWith("file://"))
                return icon

                if (icon.startsWith("/") || icon.startsWith("./"))
                    return "file://" + icon

                    return Quickshell.iconPath(icon, "application-x-executable")
    }

    readonly property var allAppEntries: {
        let list = [...DesktopEntries.applications.values]
        .filter(e => e.name && !e.noDisplay)

        if (root.sortMode === "A-Z") {
            list.sort((a, b) => a.name.localeCompare(b.name))

        } else if (root.sortMode === "Z-A") {
            list.sort((a, b) => b.name.localeCompare(a.name))

        } else if (root.sortMode === "Category") {
            list.sort((a, b) => {
                const catA = root.getAppCategory(a)
                const catB = root.getAppCategory(b)

                if (catA !== catB)
                    return catA.localeCompare(catB)

                    return a.name.localeCompare(b.name)
            })
        }

        return list
    }

    readonly property var filteredAppEntries: {
        let list = root.allAppEntries
        let q = root.searchQuery.trim().toLowerCase()

        if (q.length === 0)
            return list

            return list.filter(e => {
                const name = (e.name || "").toLowerCase()
                const genName = (e.genericName || "").toLowerCase()
                const comment = (e.comment || "").toLowerCase()
                const cats = (e.categories || []).join(" ").toLowerCase()
                const exec = (e.exec || "").toLowerCase()

                return name.includes(q) ||
                genName.includes(q) ||
                comment.includes(q) ||
                cats.includes(q) ||
                exec.includes(q)
            })
    }

    function cycleSort(reverse) {
        let index = root.sortModes.indexOf(root.sortMode)

        if (reverse)
            index--
            else
                index++

                if (index < 0)
                    index = root.sortModes.length - 1

                    if (index >= root.sortModes.length)
                        index = 0

                        root.sortMode = root.sortModes[index]

                        appGrid.currentIndex = 0
                        appGrid.positionViewAtBeginning()
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

        triggerAnimation.from = root.triggerProgress
        triggerAnimation.to = 1.0
        triggerAnimation.restart()

        focusTimer.restart()
    }

    function close() {
        root.open = false

        revealAnimation.from = root.progress
        revealAnimation.to = 0.0
        revealAnimation.restart()

        triggerAnimation.from = root.triggerProgress
        triggerAnimation.to = 0.0
        triggerAnimation.restart()

        root.searchQuery = ""
        searchInput.text = ""
    }

    function scheduleHide() {
        hideTimer.restart()
    }

    function launch(entry) {
        if (entry && (entry.id === "kitty" || entry.name === "Kitty")) {
            Quickshell.execDetached({
                command: [
                    "kitty",
                    "--config",
                    "@HOME@/.config/alice-rice/kitty.conf"
                ]
            })
        } else if (entry) {
            entry.execute()
        }

        root.close()
    }

    Timer {
        id: hideTimer

        interval: root.hideDelay

        onTriggered: {
            if (!root.insideTrigger && !root.insideLauncher) {
                root.close()
            }
        }
    }

    Timer {
        id: focusTimer

        interval: 10

        onTriggered: {
            searchInput.forceActiveFocus()
            searchInput.selectAll()
        }
    }

    NumberAnimation {
        id: revealAnimation

        target: root
        property: "progress"

        duration: root.panelAnimationDuration
        easing.type: Easing.OutExpo
    }

    NumberAnimation {
        id: triggerAnimation

        target: root
        property: "triggerProgress"

        duration: root.triggerAnimationDuration
        easing.type: Easing.OutExpo
    }

    // ============================================================
    // BOTTOM TRIGGER / BOTTOM BORDER
    // ============================================================

    PanelWindow {
        id: trigger

        screen: root.targetScreen

        anchors {
            left: true
            right: true
            bottom: true
        }

        implicitHeight: 10

        exclusiveZone: 0
        focusable: false
        color: "transparent"

        Rectangle {
            id: triggerBar

            anchors {
                horizontalCenter: parent.horizontalCenter
                bottom: parent.bottom
            }

            width:
            root.triggerWidth +
            (root.panelWidth - root.triggerWidth) *
            Math.pow(root.triggerProgress, root.triggerExpansionCurve)

            height: root.triggerHeight

            color: root.insideTrigger || root.insideLauncher
            ? root.colAccent
            : root.colViolet
        }

        MouseArea {
            anchors {
                horizontalCenter: triggerBar.horizontalCenter
                bottom: parent.bottom
            }
            width: triggerBar.width
            height: parent.height

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
    // LAUNCHER
    // ============================================================

    PanelWindow {
        id: launcherWindow

        screen: root.targetScreen

        anchors {
            bottom: true
        }

        implicitWidth: root.panelWidth
        implicitHeight: root.panelHeight

        exclusiveZone: 0
        focusable: true

        color: "transparent"

        visible: root.open || root.progress > 0 || root.triggerProgress > 0

        Item {
            anchors.fill: parent
            clip: true

            Rectangle {
                id: panel

                width: parent.width
                height: parent.height

                // Starts below the screen and rises upward.
                y: height * (1.0 - root.progress)

                color: Qt.rgba(
                    root.colBg.r,
                    root.colBg.g,
                    root.colBg.b,
                    root.panelOpacity
                )

                radius: 0

                // ====================================================
                // TOP BORDER
                // ====================================================

                Rectangle {
                    anchors {
                        top: parent.top
                        left: parent.left
                        right: parent.right
                    }

                    height: root.borderWidth
                    radius: 0

                    color: root.currentBorderColor

                    Behavior on color {
                        ColorAnimation {
                            duration: 120
                        }
                    }
                }

                // ====================================================
                // LEFT BORDER
                // ====================================================

                Rectangle {
                    anchors {
                        top: parent.top
                        left: parent.left
                        bottom: parent.bottom
                    }

                    width: root.borderWidth
                    radius: 0

                    color: root.currentBorderColor

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
                    anchors {
                        top: parent.top
                        right: parent.right
                        bottom: parent.bottom
                    }

                    width: root.borderWidth
                    radius: 0

                    color: root.currentBorderColor

                    Behavior on color {
                        ColorAnimation {
                            duration: 120
                        }
                    }
                }

                HoverHandler {
                    onHoveredChanged: {
                        root.insideLauncher = hovered

                        if (hovered) {
                            hideTimer.stop()
                        } else {
                            root.scheduleHide()
                        }
                    }
                }

                Keys.onEscapePressed: {
                    root.close()
                }

                Keys.onPressed: function(event) {
                    if (
                        event.key === Qt.Key_S &&
                        (event.modifiers & Qt.ControlModifier)
                    ) {
                        root.cycleSort(
                            event.modifiers & Qt.ShiftModifier
                        )

                        event.accepted = true
                    }
                }

                // ====================================================
                // HEADER
                // ====================================================

                Item {
                    id: header

                    anchors {
                        top: parent.top
                        left: parent.left
                        right: parent.right

                        topMargin: root.borderWidth
                        leftMargin: root.borderWidth
                        rightMargin: root.borderWidth
                    }

                    height: 28

                    Rectangle {
                        anchors.fill: parent

                        color: root.colNavy
                        opacity: 0.5
                        radius: 0
                    }

                    Text {
                        anchors {
                            left: parent.left
                            leftMargin: 12
                            verticalCenter: parent.verticalCenter
                        }

                        text: "APPLICATIONS"

                        color: root.colFgBright

                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 9
                        font.bold: true
                    }

                    Text {
                        id: sortLabel

                        anchors {
                            right: parent.right
                            rightMargin: 12
                            verticalCenter: parent.verticalCenter
                        }

                        text: root.sortMode

                        color: root.getSortColor(root.sortMode)

                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 8
                        font.bold: true

                        Behavior on color {
                            ColorAnimation {
                                duration: 100
                            }
                        }

                        HoverHandler {
                            id: sortHover
                        }

                        TapHandler {
                            onTapped: {
                                root.cycleSort(false)
                            }
                        }
                    }

                    Rectangle {
                        anchors {
                            right: sortLabel.left
                            rightMargin: 8
                            verticalCenter: parent.verticalCenter
                        }

                        width: 1
                        height: 10
                        radius: 0

                        color: root.colPurple
                    }
                }

                // ====================================================
                // SEARCH BAR
                // ====================================================

                Rectangle {
                    id: searchBarContainer

                    anchors {
                        top: header.bottom
                        left: parent.left
                        right: parent.right
                        topMargin: 4
                        leftMargin: 12
                        rightMargin: 12
                    }

                    height: 26
                    color: root.colNavy
                    radius: 0

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: searchInput.activeFocus ? 1 : 0
                        border.color: root.colAccent
                    }

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        spacing: 8

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: ""
                            color: searchInput.activeFocus ? root.colAccent : root.colViolet
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 10

                            Behavior on color {
                                ColorAnimation { duration: 100 }
                            }
                        }

                        Item {
                            width: parent.width - 24
                            height: parent.height
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                text: "Search applications..."
                                color: Qt.rgba(root.colFg.r, root.colFg.g, root.colFg.b, 0.4)
                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 9
                                visible: searchInput.text.length === 0
                            }

                            TextInput {
                                id: searchInput

                                anchors.fill: parent
                                verticalAlignment: Text.AlignVCenter

                                color: root.colFgBright
                                selectionColor: root.colSelBg
                                selectedTextColor: root.colFgBright

                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 9

                                focus: true

                                onTextChanged: {
                                    root.searchQuery = text
                                    appGrid.currentIndex = 0
                                    appGrid.positionViewAtBeginning()
                                }

                                Keys.onDownPressed: {
                                    appGrid.forceActiveFocus()
                                }

                                Keys.onReturnPressed: launchCurrent()
                                Keys.onEnterPressed: launchCurrent()

                                function launchCurrent() {
                                    if (root.filteredAppEntries.length > 0) {
                                        let idx = Math.max(0, Math.min(appGrid.currentIndex, root.filteredAppEntries.length - 1))
                                        root.launch(root.filteredAppEntries[idx])
                                    }
                                }

                                Keys.onEscapePressed: {
                                    if (text.length > 0) {
                                        text = ""
                                    } else {
                                        root.close()
                                    }
                                }
                            }
                        }
                    }
                }

                // ====================================================
                // EMPTY SEARCH STATE
                // ====================================================

                Text {
                    anchors.centerIn: appGrid
                    visible: root.filteredAppEntries.length === 0

                    text: "No applications found"
                    color: Qt.rgba(root.colFg.r, root.colFg.g, root.colFg.b, 0.5)

                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 10
                }

                // ====================================================
                // APP GRID
                // ====================================================

                GridView {
                    id: appGrid

                    anchors {
                        top: searchBarContainer.bottom
                        left: parent.left
                        right: parent.right
                        bottom: parent.bottom

                        topMargin: 4
                        leftMargin: 12
                        rightMargin: 12
                        bottomMargin: 12
                    }

                    cellWidth: 88
                    cellHeight: 88

                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    model: root.filteredAppEntries
                    focus: root.open

                    keyNavigationEnabled: true
                    keyNavigationWraps: true
                    highlightFollowsCurrentItem: true

                    highlight: Rectangle {
                        color: "transparent"
                        border.width: 2
                        border.color: root.colAccent
                        radius: 0
                    }

                    Keys.onUpPressed: function(event) {
                        if (appGrid.currentIndex < 6) {
                            searchInput.forceActiveFocus()
                            event.accepted = true
                        } else {
                            event.accepted = false
                        }
                    }

                    Keys.onReturnPressed: {
                        if (root.filteredAppEntries.length > 0) {
                            root.launch(
                                root.filteredAppEntries[appGrid.currentIndex]
                            )
                        }
                    }

                    Keys.onEnterPressed: {
                        if (root.filteredAppEntries.length > 0) {
                            root.launch(
                                root.filteredAppEntries[appGrid.currentIndex]
                            )
                        }
                    }

                    Keys.onEscapePressed: {
                        root.close()
                    }

                    delegate: Item {
                        id: tile

                        required property var modelData
                        required property int index

                        width: appGrid.cellWidth
                        height: appGrid.cellHeight

                        property bool hovered: hoverHandler.hovered

                        property color categoryColor:
                        root.getCategoryColor(
                            root.getAppCategory(tile.modelData)
                        )

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 2

                            radius: 0

                            color: tile.hovered
                            ? root.colSelBg
                            : "transparent"

                            Behavior on color {
                                ColorAnimation {
                                    duration: 100
                                }
                            }

                            Rectangle {
                                anchors {
                                    top: parent.top
                                    right: parent.right

                                    topMargin: 3
                                    rightMargin: 3
                                }

                                width: 4
                                height: 4

                                radius: 0

                                color: tile.categoryColor
                                opacity: tile.hovered ? 1.0 : 0.6
                            }
                        }

                        Column {
                            anchors.centerIn: parent

                            spacing: 6
                            width: parent.width - 8

                            IconImage {
                                id: appIcon

                                anchors.horizontalCenter:
                                parent.horizontalCenter

                                implicitSize: 34
                                asynchronous: true
                                mipmap: true

                                source:
                                root.getIconSource(
                                    tile.modelData.icon
                                )
                            }

                            Text {
                                anchors.horizontalCenter:
                                parent.horizontalCenter

                                width: parent.width

                                horizontalAlignment:
                                Text.AlignHCenter

                                wrapMode:
                                Text.WordWrap

                                maximumLineCount: 2
                                elide: Text.ElideRight

                                text: tile.modelData.name

                                color:
                                (tile.hovered ||
                                tile.GridView.isCurrentItem)
                                ? root.colAccent
                                : root.colFg

                                font.family:
                                "JetBrainsMono Nerd Font"

                                font.pixelSize: 9

                                Behavior on color {
                                    ColorAnimation {
                                        duration: 100
                                    }
                                }
                            }
                        }

                        HoverHandler {
                            id: hoverHandler

                            onHoveredChanged: {
                                if (hovered) {
                                    root.insideLauncher = true
                                    hideTimer.stop()

                                    appGrid.currentIndex = tile.index
                                }
                            }
                        }

                        TapHandler {
                            onTapped: {
                                root.launch(tile.modelData)
                            }
                        }
                    }
                }

                // ====================================================
                // SCROLL BAR
                // ====================================================

                Rectangle {
                    anchors {
                        top: appGrid.top
                        right: parent.right
                        bottom: appGrid.bottom
                    }

                    anchors.rightMargin: 4

                    width: 3
                    radius: 0

                    visible:
                    appGrid.contentHeight > appGrid.height

                    color: root.colNavy

                    Rectangle {
                        width: parent.width
                        radius: 0

                        color: root.colRose

                        y:
                        appGrid.visibleArea.yPosition *
                        parent.height

                        height:
                        Math.max(
                            24,
                            appGrid.visibleArea.heightRatio *
                            parent.height
                        )
                    }
                }
            }
        }
    }
}
