import QtQuick
import QtQuick.Window
import org.kde.layershell as LayerShell

Window {
    id: win

    visible: true
    width: Screen.width
    height: Screen.height
    color: "transparent"

    LayerShell.Window.scope: "wallfliper"
    LayerShell.Window.layer: LayerShell.Window.LayerOverlay
    LayerShell.Window.keyboardInteractivity: LayerShell.Window.KeyboardInteractivityExclusive
    LayerShell.Window.anchors:
    LayerShell.Window.AnchorTop
    | LayerShell.Window.AnchorBottom
    | LayerShell.Window.AnchorLeft
    | LayerShell.Window.AnchorRight

    Component.onCompleted: win.requestActivate()

    onActiveChanged: {
        if (active)
            mainScope.forceActiveFocus()
    }

    MouseArea {
        id: dismissArea
        anchors.fill: parent

        onClicked: {
            if (win.searching)
                win.exitSearchClear()
                else if (win.colorMode)
                    win.exitColorClear()
                    else
                        Qt.quit()
        }
    }

    property bool settingsOpen: false

    property string searchText: ""
    property bool searching: false

    onSearchTextChanged: {
        controller.setFilter(searchText)
        carousel.focusIndex(carousel.count > 0 ? 0 : -1)
    }

    function applyCurrent() {
        if (carousel.currentIndex >= 0)
            controller.apply(carousel.currentIndex)
    }

    function applyAndExit() {
        if (carousel.currentIndex < 0)
            return

            if (controller.apply(carousel.currentIndex)) {
                win.quitAfterTransition = true
                win.visible = false
            } else {
                Qt.quit()
            }
    }

    property var transitionSurface: null
    property bool quitAfterTransition: false

    Component {
        id: transitionComponent
        TransitionSurface {}
    }

    function startShaderTransition(oldUrl, newUrl, shaderUrl, ms) {
        win.dropTransitionSurface()

        const surface = transitionComponent.createObject(null, {
            oldSource: oldUrl,
            newSource: newUrl,
            shaderUrl: shaderUrl,
            durationMs: ms
        })

        if (surface === null) {
            controller.shaderTransitionFailed()
            win.finishTransition()
            return
        }

        surface.covered.connect(controller.shaderSurfaceReady)

        surface.finished.connect(function() {
            controller.shaderTransitionDone()
            win.finishTransition()
        })

        surface.failed.connect(function() {
            controller.shaderTransitionFailed()
            win.finishTransition()
        })

        win.transitionSurface = surface
    }

    function finishTransition() {
        win.dropTransitionSurface()

        if (win.quitAfterTransition)
            Qt.quit()
    }

    function dropTransitionSurface() {
        if (win.transitionSurface !== null) {
            win.transitionSurface.destroy()
            win.transitionSurface = null
        }
    }

    function exitSearchKeep() {
        win.searching = false
    }

    function exitSearchClear() {
        win.searching = false
        win.searchText = ""
    }

    property bool colorMode: false

    readonly property var colorEntries:
    [{ name: "all", hex: "#161616" }].concat(controller.colorPalette)

    function enterColorMode() {
        controller.ensureColorIndex()
        win.colorMode = true
    }

    function exitColorKeep() {
        win.colorMode = false
    }

    function exitColorClear() {
        win.colorMode = false
        controller.setColorFilter("all")
    }

    function moveColor(step: int): void {
        let i = colorEntries.findIndex(
            e => e.name === controller.colorFilter
        )

        if (i < 0)
            i = 0

            i = Math.min(
                Math.max(i + step, 0),
                         colorEntries.length - 1
            )

            controller.setColorFilter(colorEntries[i].name)
    }

    property bool folderEntryOpen: false

    function openFolderPicker() {
        if (controller.folderPortalAvailable()) {
            win.visible = false
            controller.pickFolder()
        } else {
            win.showFolderEntry()
        }
    }

    function closeFolderPicker() {
        win.visible = true

        if (settingsLoader.item)
            settingsLoader.item.forceActiveFocus()
    }

    function showFolderEntry() {
        win.visible = true
        win.folderEntryOpen = true
    }

    function closeFolderEntry() {
        win.folderEntryOpen = false

        if (settingsLoader.item)
            settingsLoader.item.forceActiveFocus()
            else
                mainScope.forceActiveFocus()
    }

    Connections {
        target: controller

        function onFolderPickerClosed() {
            win.closeFolderPicker()
        }

        function onFolderManualRequested() {
            win.showFolderEntry()
        }

        function onShaderTransitionRequested(oldUrl, newUrl, shaderUrl, ms) {
            win.startShaderTransition(oldUrl, newUrl, shaderUrl, ms)
        }
    }

    FocusScope {
        id: mainScope

        anchors.fill: parent
        focus: true

        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Escape) {
                if (win.searching)
                    win.exitSearchClear()
                    else if (win.colorMode)
                        win.exitColorClear()
                        else
                            Qt.quit()

                            event.accepted = true
                            return
            }

            if (win.searching) {
                if (
                    event.key === Qt.Key_Return
                    || event.key === Qt.Key_Enter
                ) {
                    if (win.searchText === "config") {
                        win.exitSearchClear()
                        win.settingsOpen = true
                    } else {
                        win.exitSearchKeep()
                    }
                }

                else if (
                    event.key === Qt.Key_Up
                    || event.key === Qt.Key_Left
                ) {
                    win.exitSearchKeep()
                    carousel.scrollBy(-1, event.isAutoRepeat)
                }

                else if (
                    event.key === Qt.Key_Down
                    || event.key === Qt.Key_Right
                ) {
                    win.exitSearchKeep()
                    carousel.scrollBy(1, event.isAutoRepeat)
                }

                else if (event.text === "/") {
                    win.exitSearchClear()
                }

                else if (event.key === Qt.Key_Backspace) {
                    if (win.searchText === "")
                        win.exitSearchKeep()
                        else
                            win.searchText = win.searchText.slice(0, -1)
                }

                else if (
                    event.text.length === 1
                    && event.text >= " "
                ) {
                    win.searchText += event.text
                }

                else {
                    return
                }

                event.accepted = true
                return
            }

            if (win.colorMode) {
                if (
                    event.key === Qt.Key_Return
                    || event.key === Qt.Key_Enter
                ) {
                    win.exitColorKeep()
                }

                else if (event.text === "c") {
                    win.exitColorClear()
                }

                else if (
                    event.key === Qt.Key_Up
                    || event.key === Qt.Key_W
                    || event.key === Qt.Key_K
                    || event.key === Qt.Key_Left
                    || event.key === Qt.Key_A
                    || event.key === Qt.Key_H
                ) {
                    win.moveColor(-1)
                }

                else if (
                    event.key === Qt.Key_Down
                    || event.key === Qt.Key_S
                    || event.key === Qt.Key_J
                    || event.key === Qt.Key_Right
                    || event.key === Qt.Key_D
                    || event.key === Qt.Key_L
                ) {
                    win.moveColor(1)
                }

                else {
                    return
                }

                event.accepted = true
                return
            }

            if (
                event.key === Qt.Key_Return
                || event.key === Qt.Key_Enter
            ) {
                win.applyAndExit()
            }

            else if (event.key === Qt.Key_Space) {
                win.applyCurrent()
            }

            else if (event.text === "/") {
                win.searching = true
            }

            else if (event.text === "i") {
                controller.setKindFilter("image")
            }

            else if (event.text === "v") {
                controller.setKindFilter("video")
            }

            else if (event.text === "e") {
                controller.setKindFilter("all")
            }

            else if (event.text === "c") {
                win.enterColorMode()
            }

            else if (
                event.key === Qt.Key_D
                && (event.modifiers & Qt.ShiftModifier)
            ) {
                if (carousel.currentIndex >= 0)
                    controller.deleteWallpaper(carousel.currentIndex)
            }

            else if (
                event.key === Qt.Key_Up
                || event.key === Qt.Key_W
                || event.key === Qt.Key_K
                || event.key === Qt.Key_Left
                || event.key === Qt.Key_A
                || event.key === Qt.Key_H
            ) {
                carousel.scrollBy(-1, event.isAutoRepeat)
            }

            else if (
                event.key === Qt.Key_Down
                || event.key === Qt.Key_S
                || event.key === Qt.Key_J
                || event.key === Qt.Key_Right
                || event.key === Qt.Key_D
                || event.key === Qt.Key_L
            ) {
                carousel.scrollBy(1, event.isAutoRepeat)
            }

            else {
                return
            }

            event.accepted = true
        }

        PathView {
            id: carousel

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter

            width: parent.width
            height: Math.min(
                Math.round(win.height * 0.40),
                             480
            )

            clip: true
            interactive: false

            preferredHighlightBegin: 0.5
            preferredHighlightEnd: 0.5
            highlightRangeMode: PathView.StrictlyEnforceRange
            movementDirection: PathView.Shortest

            readonly property int navMoveDuration: 300
            readonly property int glidePerStep: 90

            property bool _primed: false

            highlightMoveDuration:
            _primed ? navMoveDuration : 0

            function scrollBy(steps: int, chained: bool): void {
                if (count <= 0 || steps === 0)
                    return

                    const sameDir =
                    glide.running
                    && Math.sign(
                        glide.to - glide.from
                    ) === Math.sign(-steps)

                    const target =
                    (chained && sameDir)
                    ? glide.to - steps
                    : Math.round(offset) - steps

                    glide.stop()

                    glide.from = offset
                    glide.to = target

                    glide.duration =
                    navMoveDuration
                    + glidePerStep
                    * Math.max(
                        0,
                        Math.abs(target - offset) - 1
                    )

                    glide.restart()
            }

            function focusIndex(i: int): void {
                glide.stop()
                currentIndex = i
            }

            NumberAnimation {
                id: glide

                target: carousel
                property: "offset"

                easing.type: Easing.OutQuart
            }

            readonly property real step:
            portraitW + 6

            readonly property int slots:
            2 * Math.ceil(
                (width / step + 2) / 2
            ) + 1

            readonly property int pathSlots:
            count > 0
            ? Math.min(slots, count)
            : slots

            pathItemCount: pathSlots
            cacheItemCount: 2

            path: Path {
                startX:
                carousel.width / 2
                - carousel.pathSlots
                * carousel.step / 2

                startY:
                carousel.height / 2

                PathAttribute {
                    name: "wallScale"
                    value: 0.74
                }

                PathAttribute {
                    name: "wallOpacity"
                    value: 0.0
                }

                PathLine {
                    x:
                    carousel.width / 2
                    - carousel.pathSlots
                    * carousel.step / 6

                    y:
                    carousel.height / 2
                }

                PathAttribute {
                    name: "wallScale"
                    value: 0.88
                }

                PathAttribute {
                    name: "wallOpacity"
                    value: 0.32
                }

                PathLine {
                    x: carousel.width / 2
                    y: carousel.height / 2
                }

                PathAttribute {
                    name: "wallScale"
                    value: 1.0
                }

                PathAttribute {
                    name: "wallOpacity"
                    value: 1.0
                }

                PathLine {
                    x:
                    carousel.width / 2
                    + carousel.pathSlots
                    * carousel.step / 6

                    y:
                    carousel.height / 2
                }

                PathAttribute {
                    name: "wallScale"
                    value: 0.88
                }

                PathAttribute {
                    name: "wallOpacity"
                    value: 0.32
                }

                PathLine {
                    x:
                    carousel.width / 2
                    + carousel.pathSlots
                    * carousel.step / 2

                    y:
                    carousel.height / 2
                }

                PathAttribute {
                    name: "wallScale"
                    value: 0.74
                }

                PathAttribute {
                    name: "wallOpacity"
                    value: 0.0
                }
            }

            WheelHandler {
                onWheel: (event) => {
                    if (
                        event.angleDelta.y < 0
                        || event.angleDelta.x < 0
                    ) {
                        carousel.scrollBy(1, true)
                    }

                    else if (
                        event.angleDelta.y > 0
                        || event.angleDelta.x > 0
                    ) {
                        carousel.scrollBy(-1, true)
                    }
                }
            }

            readonly property real cardH: height

            readonly property real portraitW:
            Math.round(cardH * 0.66)

            readonly property real poppedW:
            Math.round(cardH * 0.80)

            readonly property real idleH:
            Math.round(cardH * 0.92)

            readonly property int expandDelay: 450

            readonly property int decodeH:
            Math.round(cardH * 2)

            model: controller.model

            Component.onCompleted: {
                if (count > 0)
                    currentIndex = controller.appliedRow()

                    Qt.callLater(() => _primed = true)
            }

            delegate: Item {
                id: cell

                required property int index
                required property string name
                required property string kind
                required property string thumbnail
                required property string preview

                property bool selected:
                PathView.isCurrentItem

                property bool expanded: false

                property real pathScale:
                PathView.wallScale

                property real pathOpacity:
                PathView.wallOpacity

                height: carousel.cardH
                width: carousel.portraitW

                scale: pathScale
                opacity: pathOpacity

                z: selected ? 100 : Math.round(pathScale * 10)

                Timer {
                    id: expandTimer

                    interval: carousel.expandDelay

                    onTriggered:
                    cell.expanded = true
                }

                onSelectedChanged: {
                    if (selected) {
                        if (kind === "video")
                            controller.ensurePreview(index)

                            expandTimer.restart()
                    } else {
                        expandTimer.stop()
                        cell.expanded = false
                    }
                }

                Component.onCompleted: {
                    if (selected) {
                        if (kind === "video")
                            controller.ensurePreview(index)

                            expandTimer.restart()
                    }
                }

                readonly property bool previewing:
                selected
                && kind === "video"
                && preview !== ""

                readonly property real imgAspect:
                thumb.status === Image.Ready
                && thumb.implicitHeight > 0
                ? thumb.implicitWidth
                / thumb.implicitHeight
                : 16 / 9

                readonly property real expandedW:
                Math.min(
                    Math.round(
                        carousel.cardH * imgAspect
                    ),
                    Math.round(
                        carousel.width * 0.64
                    )
                )

                Rectangle {
                    id: cardVisual

                    anchors.verticalCenter:
                    parent.verticalCenter

                    x: (cell.width - width) / 2

                    width: carousel.portraitW
                    height: carousel.idleH

                    color: "transparent"

                    border.width: 0
                    border.color: "transparent"

                    clip: true
                    antialiasing: true

                    readonly property real slant:
                    Theme.cardSlant

                    transform: Matrix4x4 {
                        matrix: Qt.matrix4x4(
                            1,
                            cardVisual.slant,
                            0,
                            -cardVisual.slant
                            * cardVisual.height / 2,

                            0, 1, 0, 0,
                            0, 0, 1, 0,
                            0, 0, 0, 1
                        )
                    }

                    states: [
                        State {
                            name: "popped"
                            when: cell.selected
                            && !cell.expanded

                            PropertyChanges {
                                cardVisual.width:
                                carousel.poppedW

                                cardVisual.height:
                                carousel.cardH
                            }
                        },

                        State {
                            name: "expanded"
                            when: cell.selected
                            && cell.expanded

                            PropertyChanges {
                                cardVisual.width:
                                cell.expandedW

                                cardVisual.height:
                                carousel.cardH
                            }
                        }
                    ]

                    transitions: [
                        Transition {
                            to: "popped"

                            NumberAnimation {
                                properties: "width,height"
                                duration: 190
                                easing.type: Easing.OutBack
                                easing.overshoot: 1.05
                            }
                        },

                        Transition {
                            to: "expanded"

                            NumberAnimation {
                                properties: "width,height"
                                duration: 340
                                easing.type: Easing.OutCubic
                            }
                        },

                        Transition {
                            to: ""

                            NumberAnimation {
                                properties: "width,height"
                                duration: 220
                                easing.type: Easing.InOutCubic
                            }
                        }
                    ]

                    Image {
                        id: thumb

                        anchors.fill: parent
                        anchors.margins: 0

                        source: cell.thumbnail

                        visible:
                        cell.thumbnail !== ""
                        && !cell.previewing

                        asynchronous: true
                        cache: true

                        opacity:
                        status === Image.Ready
                        ? 1
                        : 0

                        Behavior on opacity {
                            NumberAnimation {
                                duration: 260
                                easing.type: Easing.OutCubic
                            }
                        }

                        fillMode:
                        Image.PreserveAspectCrop

                        sourceSize.height:
                        carousel.decodeH
                    }

                    AnimatedImage {
                        anchors.fill: parent
                        anchors.margins: 0

                        source:
                        cell.previewing
                        ? cell.preview
                        : ""

                        visible: cell.previewing
                        playing: cell.previewing
                        cache: false
                        asynchronous: true

                        opacity:
                        status === AnimatedImage.Ready
                        ? 1
                        : 0

                        Behavior on opacity {
                            NumberAnimation {
                                duration: 300
                                easing.type: Easing.OutCubic
                            }
                        }

                        fillMode:
                        Image.PreserveAspectCrop
                    }

                    Text {
                        anchors.centerIn: parent

                        visible:
                        cell.thumbnail === ""
                        && !cell.previewing

                        text:
                        cell.kind === "video"
                        ? "▶"
                        : "…"

                        color: "#3a3a3a"
                        font.family: Theme.fontFamily
                        font.pixelSize: 24
                    }

                    MouseArea {
                        anchors.fill: parent

                        cursorShape:
                        Qt.PointingHandCursor

                        onClicked: {
                            carousel.focusIndex(cell.index)

                            if (win.searching)
                                win.exitSearchKeep()
                        }

                        onDoubleClicked: {
                            carousel.focusIndex(cell.index)
                            win.applyAndExit()
                        }
                    }
                }
            }
        }

        Rectangle {
            id: colorBar

            anchors.horizontalCenter:
            parent.horizontalCenter

            anchors.top:
            carousel.bottom

            anchors.topMargin: 24

            width:
            swatchRow.implicitWidth + 28

            height:
            swatchRow.implicitHeight + 20

            color: Theme.bg

            border.width: 0
            border.color: "transparent"

            visible:
            win.colorMode
            || controller.colorFilter !== "all"

            MouseArea {
                anchors.fill: parent
            }

            Row {
                id: swatchRow

                anchors.centerIn: parent
                spacing: 8

                Repeater {
                    model: win.colorEntries

                    delegate: Rectangle {
                        id: swatch

                        required property var modelData

                        width: 26
                        height: 40

                        color:
                        modelData.hex

                        border.width: 0
                        border.color: "transparent"

                        antialiasing: true

                        readonly property real slant:
                        Theme.cardSlant

                        transform: Matrix4x4 {
                            matrix: Qt.matrix4x4(
                                1,
                                swatch.slant,
                                0,
                                -swatch.slant
                                * swatch.height / 2,

                                0, 1, 0, 0,
                                0, 0, 1, 0,
                                0, 0, 0, 1
                            )
                        }

                        Text {
                            anchors.centerIn: parent

                            visible:
                            swatch.modelData.name === "all"

                            text: "×"

                            color: Theme.muted
                            font.family: Theme.fontFamily
                            font.pixelSize: 14
                        }

                        MouseArea {
                            anchors.fill: parent

                            cursorShape:
                            Qt.PointingHandCursor

                            onClicked:
                            controller.setColorFilter(
                                swatch.modelData.name
                            )
                        }
                    }
                }
            }
        }
    }

    Loader {
        id: settingsLoader

        anchors.fill: parent
        z: 100

        active: win.settingsOpen
        source: "Settings.qml"

        onLoaded:
        item.forceActiveFocus()
    }

    Connections {
        target: settingsLoader.item

        function onClosed() {
            win.settingsOpen = false
            mainScope.forceActiveFocus()
        }

        function onFolderRequested() {
            win.openFolderPicker()
        }
    }

    Loader {
        id: folderEntryLoader

        anchors.fill: parent
        z: 200

        active: win.folderEntryOpen
        source: "FolderInput.qml"
    }

    Connections {
        target: folderEntryLoader.item

        function onAccepted() {
            win.closeFolderEntry()
        }

        function onCancelled() {
            win.closeFolderEntry()
        }
    }
}
