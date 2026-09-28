import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell.Services.UPower

Item {
    id: root

    property var targetScreen: null

    // ============================================================
    // EDIT THESE SETTINGS
    // ============================================================

    readonly property int panelWidth: 770
    readonly property int panelHeight: 48
    readonly property int maxExpandedContentHeight: 268

    readonly property int triggerWidth: 180
    readonly property int triggerHeight: 3

    readonly property int borderWidth: 2
    readonly property int animationDuration: 120
    readonly property real triggerExpansionCurve: 0.5
    readonly property int hideDelay: 300
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
    // TIME STATE
    // ============================================================

    property string currentTime: ""

    Timer {
        id: clockTimer

        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true

        onTriggered: {
            root.currentTime =
            Qt.formatDateTime(
                new Date(),
                              "hh:mm:ss AP"
            )
        }
    }

    // ============================================================
    // POWER PROFILE STATE
    // ============================================================

    property string powerProfile: "balanced"

    Process {
        id: powerProfileStatusProc

        command: [
            "cat",
            "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
        ]

        stdout: StdioCollector {
            onStreamFinished: {
                const res =
                this.text.trim().toLowerCase()

                if (res === "powersave") {
                    root.powerProfile = "powersave"
                } else if (res === "performance") {
                    root.powerProfile = "performance"
                } else {
                    root.powerProfile = "balanced"
                }
            }
        }
    }

    function setPowerProfile(mode) {
        let targetGov = "schedutil"

        if (mode === "powersave") {
            targetGov = "powersave"
        } else if (mode === "performance") {
            targetGov = "performance"
        }

        Quickshell.execDetached({
            command: [
                "sudo",
                "cpupower",
                "frequency-set",
                "-g",
                targetGov
            ]
        })

        root.powerProfile = mode

        Qt.callLater(function() {
            if (!powerProfileStatusProc.running)
                powerProfileStatusProc.running = true
        })
    }

    function cyclePowerProfile() {
        if (root.powerProfile === "powersave") {
            setPowerProfile("balanced")
        } else if (root.powerProfile === "balanced") {
            setPowerProfile("performance")
        } else {
            setPowerProfile("powersave")
        }
    }

    // ============================================================
    // STATE & ANIMATION
    // ============================================================

    property bool open: false
    property bool insideTrigger: false
    property bool insideDrawer: false
    property real progress: 0.0

    property string activeMenu: ""

    // ============================================================
    // WI-FI / BLUETOOTH STATE
    // ============================================================

    property real volumeLevel: 0.70
    property bool isMuted: false

    property string wifiState: "unknown"
    property string wifiSsid: "Wi-Fi"

    // Native Quickshell Bluetooth objects.
    readonly property var btAdapter:
    Bluetooth.defaultAdapter

    readonly property var btDevices:
    Bluetooth.devices
    ? Bluetooth.devices.values
    : []

    readonly property bool bluetoothEnabled:
    btAdapter !== null &&
    btAdapter.enabled

    readonly property bool bluetoothScanning:
    btAdapter !== null &&
    btAdapter.discovering

    readonly property string bluetoothDeviceName: {
        const devices = root.btDevices

        for (let i = 0; i < devices.length; i++) {
            const device = devices[i]

            if (
                device &&
                device.connected
            ) {
                if (
                    device.name &&
                    device.name.length > 0
                ) {
                    return device.name
                }

                if (
                    device.deviceName &&
                    device.deviceName.length > 0
                ) {
                    return device.deviceName
                }

                return device.address || ""
            }
        }

        return ""
    }

    // ============================================================
    // DATA MODELS
    //
    // These only contain simple strings/bools.
    // The actual BluetoothDevice object is looked up by MAC when
    // a button is clicked.
    // ============================================================

    ListModel {
        id: wifiModel
    }

    ListModel {
        id: btPairedModel
    }

    ListModel {
        id: btNearbyModel
    }

    // ============================================================
    // BT DISCOVERY OWNERSHIP
    // ============================================================

    property bool btOwnsDiscovery: false

    Timer {
        id: btDiscoveryStopTimer

        interval: 8000
        repeat: false

        onTriggered: {
            root.stopBtDiscovery()
        }
    }

    Timer {
        id: btModelRefreshTimer

        interval: 250
        repeat: true
        triggeredOnStart: true

        running:
        root.activeMenu === "bt"

        onTriggered: {
            root.refreshBtModels()
        }
    }

    // ============================================================
    // MENU OPEN / SCAN DELAY
    // ============================================================

    Timer {
        id: menuScanDelayTimer

        interval: 100
        repeat: false

        onTriggered: {
            if (
                root.activeMenu === "wifi" &&
                !wifiScanProc.running
            ) {
                wifiScanProc.running = true

            } else if (
                root.activeMenu === "bt"
            ) {
                root.startBtDiscovery()
            }
        }
    }

    function setActiveMenuDeferred(menuName) {
        if (root.activeMenu === menuName) {
            root.activeMenu = ""
            menuScanDelayTimer.stop()

            if (menuName === "bt")
                root.stopBtDiscovery()

                return
        }

        if (root.activeMenu === "bt") {
            root.stopBtDiscovery()
        }

        root.activeMenu = menuName
        menuScanDelayTimer.restart()
    }

    onActiveMenuChanged: {
        if (root.activeMenu === "bt") {
            root.refreshBtModels()
        }
    }

    // ============================================================
    // EXPANDED HEIGHT
    // ============================================================

    readonly property real targetExpandedHeight: {
        if (root.activeMenu === "wifi") {
            const count = wifiModel.count

            if (count === 0)
                return 64

                return (
                    36
                    + Math.min(
                        count * 32 +
                        (count > 1 ? (count - 1) * 2 : 0),
                               220
                    )
                    + 12
                )
        }

        if (root.activeMenu === "bt") {
            const pairedCount =
            btPairedModel.count

            const nearbyCount =
            btNearbyModel.count

            const pairedRows =
            26 +
            Math.max(
                pairedCount * 34,
                28
            )

            const nearbyRows =
            26 +
            Math.max(
                nearbyCount * 34,
                28
            )

            return Math.min(
                pairedRows +
                nearbyRows +
                12,
                root.maxExpandedContentHeight
            )
        }

        return 0
    }

    property real currentExpandedHeight: 0

    Behavior on currentExpandedHeight {
        NumberAnimation {
            duration:
            root.animationDuration

            easing.type:
            Easing.OutCubic
        }
    }

    onTargetExpandedHeightChanged: {
        currentExpandedHeight =
        targetExpandedHeight
    }

    // ============================================================
    // BATTERY
    // ============================================================

    property int sysBatteryPct: -1
    property bool sysBatteryCharging: false
    property bool hasBattery: true

    readonly property var battery:
    UPower.displayDevice

    readonly property int batteryPercentage: {
        if (sysBatteryPct >= 0)
            return sysBatteryPct

            if (
                battery &&
                battery.ready
            ) {
                const p = battery.percentage

                return Math.round(
                    p <= 1.0
                    ? p * 100
                    : p
                )
            }

            return 0
    }

    readonly property bool batteryCharging: {
        if (sysBatteryPct >= 0)
            return sysBatteryCharging

            if (
                battery &&
                battery.ready
            ) {
                return (
                    battery.changeRate > 0 ||
                    battery.batteryState === 1
                )
            }

            return false
    }

    readonly property color batteryColor:
    !hasBattery
    ? root.colFgBright
    : batteryPercentage <= 15
    ? root.colAccent
    : batteryPercentage <= 30
    ? root.colPink
    : batteryCharging
    ? root.colRose
    : root.colFgBright

    // ============================================================
    // PROCESSES
    // ============================================================

    Process {
        id: wallflipperProc

        command: [
            "sh",
            "-c",
            "export PATH=$PATH:$HOME/.local/bin:$HOME/bin; " +
            "wallfliper > /tmp/wallflipper.log 2>&1"
        ]
    }

    Process {
        id: batteryStatusProc

        command: [
            "sh",
            "-c",
            "cap=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -n1); " +
            "stat=$(cat /sys/class/power_supply/BAT*/status 2>/dev/null | head -n1); " +
            "if [ -n \"$cap\" ]; then " +
            "printf '%s|%s' \"$cap\" \"$stat\"; " +
            "else echo 'N/A|AC'; fi"
        ]

        stdout: StdioCollector {
            onStreamFinished: {
                const parts =
                this.text.trim().split("|")

                if (
                    parts.length >= 2 &&
                    parts[0] !== "N/A"
                ) {
                    root.hasBattery = true
                    root.sysBatteryPct =
                    parseInt(parts[0]) || 0

                    root.sysBatteryCharging =
                    parts[1].toLowerCase() ===
                    "charging"
                } else {
                    root.hasBattery = false
                    root.sysBatteryPct = 100
                    root.sysBatteryCharging = false
                }
            }
        }
    }

    Process {
        id: volProc
    }

    Process {
        id: volumeStatusProc

        command: [
            "wpctl",
            "get-volume",
            "@DEFAULT_AUDIO_SINK@"
        ]

        stdout: StdioCollector {
            onStreamFinished: {
                const text =
                this.text.trim()

                const match =
                text.match(
                    /Volume:\s+([0-9.]+)/
                )

                if (match) {
                    root.volumeLevel =
                    Math.max(
                        0.0,
                        Math.min(
                            1.0,
                            parseFloat(match[1])
                        )
                    )
                }

                root.isMuted =
                text.indexOf(
                    "[MUTED]"
                ) !== -1
            }
        }
    }

    // ============================================================
    // WI-FI
    // ============================================================

    Process {
        id: wifiStatusProc

        command: [
            "sh",
            "-c",
            "printf '%s|' " +
            "\"$(nmcli -t -f WIFI radio 2>/dev/null)\"; " +
            "nmcli -t -f IN-USE,SSID dev wifi 2>/dev/null | " +
            "sed -n 's/^*://p' | head -n1"
        ]

        stdout: StdioCollector {
            onStreamFinished: {
                const parts =
                this.text.trim().split("|")

                root.wifiState =
                parts[0] || "unknown"

                root.wifiSsid =
                (
                    parts.length > 1 &&
                    parts[1].length > 0
                )
                ? parts[1]
                : "Wi-Fi"
            }
        }
    }

    Process {
        id: wifiScanProc

        command: [
            "nmcli",
            "-t",
            "-f",
            "IN-USE,SSID,SECURITY,SIGNAL",
            "dev",
            "wifi",
            "list"
        ]

        stdout: StdioCollector {
            onStreamFinished: {
                wifiModel.clear()

                if (!this.text)
                    return

                    const lines =
                    this.text.trim().split("\n")

                    const seen = {}

                    for (
                        let i = 0;
                i < lines.length;
                i++
                    ) {
                        const line =
                        lines[i].trim()

                        if (!line)
                            continue

                            const safeLine =
                            line.replace(
                                /\\:/g,
                                "___COLON___"
                            )

                            const parts =
                            safeLine.split(":")

                            if (parts.length < 4)
                                continue

                                const active =
                                parts[0].trim() === "*"

                                const signal =
                                parts[
                                    parts.length - 1
                                ].trim()

                                const security =
                                parts[
                                    parts.length - 2
                                ]
                                .replace(
                                    /___COLON___/g,
                                    ":"
                                )
                                .trim()

                                const ssid =
                                parts
                                .slice(
                                    1,
                                    parts.length - 2
                                )
                                .join(":")
                                .replace(
                                    /___COLON___/g,
                                    ":"
                                )
                                .trim()

                                if (
                                    ssid &&
                                    seen[ssid] === undefined
                                ) {
                                    seen[ssid] = true

                                    wifiModel.append({
                                        ssid: ssid,
                                        signal:
                                        (
                                            signal
                                            ? signal
                                            : "0"
                                        ) + "%",
                                        security:
                                        (
                                            security.length > 0 &&
                                            security !== "--"
                                        )
                                        ? security
                                        : "Open",
                                        active: active
                                    })
                                }
                    }
            }
        }
    }

    // ============================================================
    // BLUETOOTH MODEL BUILDING
    // ============================================================

    function refreshBtModels() {
        btPairedModel.clear()
        btNearbyModel.clear()

        const devices =
        root.btDevices

        const paired = []
        const nearby = []

        for (
            let i = 0;
        i < devices.length;
        i++
        ) {
            const device =
            devices[i]

            if (
                !device ||
                !device.address
            ) {
                continue
            }

            const isPaired =
            device.paired ||
            device.bonded

            if (isPaired) {
                paired.push(device)
            } else if (
                root.bluetoothScanning
            ) {
                nearby.push(device)
            }
        }

        // --------------------------------------------------------
        // Sort paired devices by name
        // --------------------------------------------------------

        paired.sort(function(a, b) {
            const aName =
            (
                a.name ||
                a.deviceName ||
                a.address
            ).toLowerCase()

            const bName =
            (
                b.name ||
                b.deviceName ||
                b.address
            ).toLowerCase()

            return aName.localeCompare(bName)
        })

        // --------------------------------------------------------
        // Sort nearby devices by name
        // --------------------------------------------------------

        nearby.sort(function(a, b) {
            const aName =
            (
                a.name ||
                a.deviceName ||
                a.address
            ).toLowerCase()

            const bName =
            (
                b.name ||
                b.deviceName ||
                b.address
            ).toLowerCase()

            return aName.localeCompare(bName)
        })

        // --------------------------------------------------------
        // Add paired devices
        // --------------------------------------------------------

        for (
            let i = 0;
        i < paired.length;
        i++
        ) {
            const device =
            paired[i]

            btPairedModel.append({
                mac:
                device.address,

                name:
                device.name ||
                device.deviceName ||
                device.address,

                connected:
                !!device.connected
            })
        }

        // --------------------------------------------------------
        // Add unpaired devices
        // --------------------------------------------------------

        for (
            let i = 0;
        i < nearby.length;
        i++
        ) {
            const device =
            nearby[i]

            btNearbyModel.append({
                mac:
                device.address,

                name:
                device.name ||
                device.deviceName ||
                device.address
            })
        }
    }

    // ============================================================
    // LOOK UP ACTUAL BLUETOOTH DEVICE
    // ============================================================

    function findBtDevice(mac) {
        const devices =
        root.btDevices

        for (
            let i = 0;
        i < devices.length;
        i++
        ) {
            const device =
            devices[i]

            if (
                device &&
                device.address === mac
            ) {
                return device
            }
        }

        return null
    }

    // ============================================================
    // BLUETOOTH DISCOVERY
    // ============================================================

    function startBtDiscovery() {
        if (
            !root.btAdapter ||
            !root.btAdapter.enabled
        ) {
            return
        }

        if (
            !root.btAdapter.discovering
        ) {
            root.btOwnsDiscovery = true
            root.btAdapter.discovering = true
        } else {
            root.btOwnsDiscovery = false
        }

        root.refreshBtModels()

        btDiscoveryStopTimer.restart()
    }

    function stopBtDiscovery() {
        btDiscoveryStopTimer.stop()

        if (
            root.btOwnsDiscovery &&
            root.btAdapter &&
            root.btAdapter.discovering
        ) {
            root.btAdapter.discovering = false
        }

        root.btOwnsDiscovery = false

        root.refreshBtModels()
    }

    // ============================================================
    // BLUETOOTH CONNECT / DISCONNECT
    // ============================================================

    function toggleBtDevice(
        mac,
        connected
    ) {
        const device =
        root.findBtDevice(mac)

        if (!device)
            return

            if (connected) {
                if (
                    typeof device.disconnect ===
                    "function"
                ) {
                    device.disconnect()
                } else {
                    device.connected = false
                }
            } else {
                if (
                    typeof device.connect ===
                    "function"
                ) {
                    device.connect()
                } else {
                    device.connected = true
                }
            }

            root.refreshBtModels()
    }

    // ============================================================
    // BLUETOOTH PAIR
    // ============================================================

    function pairBtDevice(mac) {
        const device =
        root.findBtDevice(mac)

        if (!device)
            return

            // Make sure BlueZ has an agent available for pairing.
            Quickshell.execDetached({
                command: [
                    "bluetoothctl",
                    "agent",
                    "on"
                ]
            })

            Quickshell.execDetached({
                command: [
                    "bluetoothctl",
                    "default-agent"
                ]
            })

            if (
                typeof device.pair ===
                "function"
            ) {
                device.pair()
            }

            root.refreshBtModels()
    }

    // ============================================================
    // BLUETOOTH POWER
    // ============================================================

    function toggleBluetooth() {
        if (!root.btAdapter)
            return

            root.btAdapter.enabled =
            !root.btAdapter.enabled

            if (!root.btAdapter.enabled) {
                root.btOwnsDiscovery = false
                btDiscoveryStopTimer.stop()
            }
    }

    // ============================================================
    // VOLUME
    // ============================================================

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
    // WI-FI ACTIONS
    // ============================================================

    function toggleWifi() {
        Quickshell.execDetached({
            command: [
                "nmcli",
                "radio",
                "wifi",
                root.wifiState === "enabled"
                ? "off"
                : "on"
            ]
        })

        Qt.callLater(function() {
            if (!wifiStatusProc.running)
                wifiStatusProc.running = true
        })
    }

    function connectWifi(ssid) {
        Quickshell.execDetached({
            command: [
                "nmcli",
                "dev",
                "wifi",
                "connect",
                ssid
            ]
        })

        Qt.callLater(function() {
            if (!wifiStatusProc.running)
                wifiStatusProc.running = true
        })
    }

    // ============================================================
    // STATUS POLLING
    // ============================================================

    property int pollCycle: 0

    Timer {
        id: statusTimer

        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true

        onTriggered: {
            root.pollCycle =
            (
                root.pollCycle + 1
            ) % 3

            if (
                root.pollCycle === 0
            ) {
                if (
                    !batteryStatusProc.running
                ) {
                    batteryStatusProc.running =
                    true
                }

                if (
                    !powerProfileStatusProc.running
                ) {
                    powerProfileStatusProc.running =
                    true
                }

            } else if (
                root.pollCycle === 1
            ) {
                if (
                    !volumeStatusProc.running
                ) {
                    volumeStatusProc.running =
                    true
                }

            } else if (
                root.pollCycle === 2
            ) {
                if (
                    !wifiStatusProc.running
                ) {
                    wifiStatusProc.running =
                    true
                }
            }
        }
    }

    // ============================================================
    // VISIBILITY
    // ============================================================

    function show() {
        hideTimer.stop()

        root.open = true

        revealAnimation.from =
        root.progress

        revealAnimation.to = 1.0
        revealAnimation.restart()
    }

    function scheduleHide() {
        hideTimer.restart()
    }

    Timer {
        id: hideTimer

        interval:
        root.hideDelay

        onTriggered: {
            if (
                !root.insideTrigger &&
                !root.insideDrawer
            ) {
                root.open = false
                root.activeMenu = ""

                root.stopBtDiscovery()

                revealAnimation.from =
                root.progress

                revealAnimation.to = 0.0
                revealAnimation.restart()
            }
        }
    }

    NumberAnimation {
        id: revealAnimation

        target: root
        property: "progress"

        duration:
        root.animationDuration

        easing.type:
        Easing.OutCubic
    }

    // ============================================================
    // TRIGGER WINDOW
    // ============================================================

    PanelWindow {
        id: trigger

        screen:
        root.targetScreen

        anchors.top: true

        implicitWidth:
        root.panelWidth

        implicitHeight:
        Math.max(
            root.triggerHeight,
            root.borderWidth
        )

        exclusiveZone: 0
        focusable: false
        color: "transparent"

        Rectangle {
            id: indicatorBar

            anchors.horizontalCenter:
            parent.horizontalCenter

            anchors.top:
            parent.top

            height:
            (
                root.insideTrigger ||
                root.insideDrawer ||
                root.progress > 0
            )
            ? root.borderWidth
            : root.triggerHeight

            width:
            (
                root.insideTrigger ||
                root.insideDrawer ||
                root.progress > 0
            )
            ? root.panelWidth
            : root.triggerWidth

            color:
            (
                root.insideTrigger ||
                root.insideDrawer ||
                root.progress > 0
            )
            ? root.colAccent
            : root.colViolet

            Behavior on width {
                NumberAnimation {
                    duration:
                    root.animationDuration

                    easing.type:
                    Easing.OutCubic
                }
            }

            Behavior on height {
                NumberAnimation {
                    duration:
                    root.animationDuration

                    easing.type:
                    Easing.OutCubic
                }
            }

            Behavior on color {
                ColorAnimation {
                    duration:
                    root.animationDuration
                }
            }
        }

        MouseArea {
            anchors.horizontalCenter:
            parent.horizontalCenter

            anchors.top:
            parent.top

            width:
            root.triggerWidth

            height:
            parent.height

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
    // MAIN DRAWER
    // ============================================================

    PanelWindow {
        id: drawerWindow

        screen:
        root.targetScreen

        anchors.top: true

        implicitWidth:
        root.panelWidth

        implicitHeight:
        root.panelHeight +
        root.maxExpandedContentHeight

        exclusiveZone: 0
        focusable: true
        color: "transparent"

        visible:
        root.progress > 0.01

        Item {
            anchors.fill: parent
            clip: true

            Rectangle {
                id: panel

                width:
                parent.width

                height:
                root.panelHeight +
                root.currentExpandedHeight

                transform: Translate {
                    y:
                    -panel.height +
                    (
                        panel.height *
                        root.progress
                    )
                }

                color:
                Qt.rgba(
                    root.colBg.r,
                    root.colBg.g,
                    root.colBg.b,
                    root.panelOpacity
                )

                // ----------------------------------------------------
                // BORDERS
                // ----------------------------------------------------

                Rectangle {
                    anchors.top:
                    parent.top

                    anchors.left:
                    parent.left

                    anchors.bottom:
                    parent.bottom

                    width:
                    root.borderWidth

                    color:
                    root.insideDrawer
                    ? root.colAccent
                    : root.colViolet
                }

                Rectangle {
                    anchors.top:
                    parent.top

                    anchors.right:
                    parent.right

                    anchors.bottom:
                    parent.bottom

                    width:
                    root.borderWidth

                    color:
                    root.insideDrawer
                    ? root.colAccent
                    : root.colViolet
                }

                Rectangle {
                    anchors.bottom:
                    parent.bottom

                    anchors.left:
                    parent.left

                    anchors.right:
                    parent.right

                    height:
                    root.borderWidth

                    color:
                    root.insideDrawer
                    ? root.colAccent
                    : root.colViolet
                }

                HoverHandler {
                    onHoveredChanged: {
                        root.insideDrawer =
                        hovered

                        if (hovered)
                            hideTimer.stop()
                            else
                                root.scheduleHide()
                    }
                }

                // ====================================================
                // TOP BAR
                // ====================================================

                Item {
                    id: innerArea

                    anchors.top:
                    parent.top

                    anchors.left:
                    parent.left

                    anchors.right:
                    parent.right

                    height:
                    root.panelHeight

                    Row {
                        anchors.centerIn:
                        parent

                        spacing: 8

                        // ------------------------------------------------
                        // TIME
                        // ------------------------------------------------

                        Rectangle {
                            width: 78
                            height: 28

                            color:
                            root.colNavy

                            Text {
                                anchors.centerIn:
                                parent

                                text:
                                root.currentTime

                                color:
                                root.colFgBright

                                font.family:
                                "JetBrainsMono Nerd Font"

                                font.pixelSize: 8
                                font.bold: true
                            }
                        }

                        // ------------------------------------------------
                        // WALL
                        // ------------------------------------------------

                        Rectangle {
                            width: 58
                            height: 28

                            color:
                            wallHover.hovered
                            ? root.colSelBg
                            : root.colNavy

                            Text {
                                anchors.centerIn:
                                parent

                                text:
                                "WALL"

                                color:
                                wallHover.hovered
                                ? root.colAccent
                                : root.colFgBright

                                font.family:
                                "JetBrainsMono Nerd Font"

                                font.pixelSize: 8
                                font.bold: true
                            }

                            HoverHandler {
                                id: wallHover
                            }

                            TapHandler {
                                onTapped:
                                wallflipperProc
                                .startDetached()
                            }
                        }

                        // ------------------------------------------------
                        // WI-FI
                        // ------------------------------------------------

                        Rectangle {
                            width: 96
                            height: 28

                            color:
                            (
                                wifiHover.hovered ||
                                root.activeMenu === "wifi"
                            )
                            ? root.colSelBg
                            : root.colNavy

                            Text {
                                anchors.centerIn:
                                parent

                                width:
                                parent.width - 8

                                horizontalAlignment:
                                Text.AlignHCenter

                                elide:
                                Text.ElideRight

                                text:
                                (
                                    root.wifiState === "enabled"
                                    ? (
                                        root.wifiSsid ===
                                        "Wi-Fi"
                                        ? "WIFI"
                                        : root.wifiSsid
                                    )
                                    : "WIFI OFF"
                                ) +
                                (
                                    root.activeMenu ===
                                    "wifi"
                                    ? " ▲"
                                    : " ▼"
                                )

                                color:
                                root.wifiState === "enabled"
                                ? root.colFgBright
                                : root.colAccent

                                font.family:
                                "JetBrainsMono Nerd Font"

                                font.pixelSize: 7
                                font.bold: true
                            }

                            HoverHandler {
                                id: wifiHover
                            }

                            TapHandler {
                                acceptedButtons:
                                Qt.LeftButton |
                                Qt.RightButton

                                onTapped:
                                function(
                                    eventPoint,
                                    button
                                ) {
                                    if (
                                        button ===
                                        Qt.RightButton
                                    ) {
                                        root.toggleWifi()
                                    } else {
                                        root.setActiveMenuDeferred(
                                            "wifi"
                                        )
                                    }
                                }
                            }
                        }

                        // ------------------------------------------------
                        // BLUETOOTH
                        // ------------------------------------------------

                        Rectangle {
                            width: 96
                            height: 28

                            color:
                            (
                                bluetoothHover.hovered ||
                                root.activeMenu === "bt"
                            )
                            ? root.colSelBg
                            : root.colNavy

                            Text {
                                anchors.centerIn:
                                parent

                                width:
                                parent.width - 8

                                horizontalAlignment:
                                Text.AlignHCenter

                                elide:
                                Text.ElideRight

                                text:
                                (
                                    root.bluetoothEnabled
                                    ? (
                                        root.bluetoothDeviceName
                                        .length > 0
                                        ? root.bluetoothDeviceName
                                        : "BT ON"
                                    )
                                    : "BT OFF"
                                ) +
                                (
                                    root.activeMenu === "bt"
                                    ? " ▲"
                                    : " ▼"
                                )

                                color:
                                root.bluetoothEnabled
                                ? root.colFgBright
                                : root.colAccent

                                font.family:
                                "JetBrainsMono Nerd Font"

                                font.pixelSize: 7
                                font.bold: true
                            }

                            HoverHandler {
                                id: bluetoothHover
                            }

                            TapHandler {
                                acceptedButtons:
                                Qt.LeftButton |
                                Qt.RightButton

                                onTapped:
                                function(
                                    eventPoint,
                                    button
                                ) {
                                    if (
                                        button ===
                                        Qt.RightButton
                                    ) {
                                        root.toggleBluetooth()
                                    } else {
                                        root.setActiveMenuDeferred(
                                            "bt"
                                        )
                                    }
                                }
                            }
                        }

                        // ------------------------------------------------
                        // POWER
                        // ------------------------------------------------

                        Rectangle {
                            width: 68
                            height: 28

                            color:
                            pwrHover.hovered
                            ? root.colSelBg
                            : root.colNavy

                            Text {
                                anchors.centerIn:
                                parent

                                text:
                                root.powerProfile ===
                                "powersave"
                                ? "PWR: SAV"
                                : root.powerProfile ===
                                "performance"
                                ? "PWR: PRF"
                                : "PWR: BAL"

                                color:
                                root.powerProfile ===
                                "powersave"
                                ? root.colRose
                                : root.powerProfile ===
                                "performance"
                                ? root.colAccent
                                : root.colFgBright

                                font.family:
                                "JetBrainsMono Nerd Font"

                                font.pixelSize: 7
                                font.bold: true
                            }

                            HoverHandler {
                                id: pwrHover
                            }

                            TapHandler {
                                onTapped:
                                root.cyclePowerProfile()
                            }
                        }

                        // ------------------------------------------------
                        // BATTERY
                        // ------------------------------------------------

                        Rectangle {
                            width: 58
                            height: 28

                            color:
                            root.colNavy

                            Text {
                                anchors.centerIn:
                                parent

                                text:
                                !root.hasBattery
                                ? "AC"
                                : (
                                    !root.battery.ready &&
                                    root.sysBatteryPct < 0
                                )
                                ? "--"
                                : (
                                    root.batteryCharging
                                    ? "CHG " +
                                    root.batteryPercentage +
                                    "%"
                                    : root.batteryPercentage +
                                    "%"
                                )

                                color:
                                root.batteryColor

                                font.family:
                                "JetBrainsMono Nerd Font"

                                font.pixelSize: 8
                                font.bold: true
                            }
                        }

                        // ------------------------------------------------
                        // VOLUME TEXT
                        // ------------------------------------------------

                        Text {
                            width: 32
                            height: parent.height

                            verticalAlignment:
                            Text.AlignVCenter

                            text:
                            root.isMuted
                            ? "MUT"
                            : Math.round(
                                root.volumeLevel *
                                100
                            ) + "%"

                            color:
                            root.isMuted
                            ? root.colAccent
                            : root.colFgBright

                            font.family:
                            "JetBrainsMono Nerd Font"

                            font.pixelSize: 8
                            font.bold: true
                        }

                        // ------------------------------------------------
                        // VOLUME BAR
                        // ------------------------------------------------

                        Item {
                            id: volTrack

                            width: 145
                            height: 14

                            anchors.verticalCenter:
                            parent.verticalCenter

                            readonly property int stepCount:
                            10

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
                                anchors.fill:
                                parent

                                spacing: 0

                                Repeater {
                                    model:
                                    volTrack.stepCount

                                    Rectangle {
                                        required property int index

                                        width:
                                        volTrack.width /
                                        volTrack.stepCount

                                        height:
                                        volTrack.height

                                        property bool isActive:
                                        !root.isMuted &&
                                        root.volumeLevel >=
                                        (
                                            (index + 1) /
                                            volTrack.stepCount
                                        )

                                        color:
                                        isActive
                                        ? volTrack.stepColors[index]
                                        : root.colNavy
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill:
                                parent

                                function updateVol(mouse) {
                                    const val =
                                    Math.max(
                                        0.0,
                                        Math.min(
                                            1.0,
                                            mouse.x /
                                            width
                                        )
                                    )

                                    root.volumeLevel =
                                    val

                                    root.isMuted =
                                    false

                                    root.setVolume(val)
                                }

                                onPressed:
                                function(mouse) {
                                    updateVol(mouse)
                                }

                                onPositionChanged:
                                function(mouse) {
                                    if (pressed)
                                        updateVol(mouse)
                                }
                            }
                        }

                        // ------------------------------------------------
                        // MUTE
                        // ------------------------------------------------

                        Rectangle {
                            width: 46
                            height: 28

                            color:
                            muteHover.hovered
                            ? root.colSelBg
                            : root.colNavy

                            Text {
                                anchors.centerIn:
                                parent

                                text:
                                root.isMuted
                                ? "UNM"
                                : "MUTE"

                                color:
                                root.isMuted
                                ? root.colAccent
                                : root.colFg

                                font.family:
                                "JetBrainsMono Nerd Font"

                                font.pixelSize: 7
                                font.bold: true
                            }

                            HoverHandler {
                                id: muteHover
                            }

                            TapHandler {
                                onTapped: {
                                    root.isMuted =
                                    !root.isMuted

                                    root.toggleMute()
                                }
                            }
                        }
                    }
                }

                // ====================================================
                // EXPANDED PANEL
                // ====================================================

                Rectangle {
                    id: expandedPanel

                    anchors.top:
                    parent.top

                    anchors.topMargin:
                    root.panelHeight

                    anchors.left:
                    parent.left

                    anchors.leftMargin:
                    root.borderWidth

                    anchors.right:
                    parent.right

                    anchors.rightMargin:
                    root.borderWidth

                    anchors.bottom:
                    parent.bottom

                    anchors.bottomMargin:
                    root.borderWidth

                    clip: true

                    visible:
                    root.currentExpandedHeight > 0

                    color:
                    root.colNavy

                    // =================================================
                    // WI-FI DRAWER
                    // =================================================

                    Item {
                        anchors.fill:
                        parent

                        visible:
                        root.activeMenu === "wifi"

                        Item {
                            id: wifiHeader

                            anchors.top:
                            parent.top

                            anchors.left:
                            parent.left

                            anchors.right:
                            parent.right

                            height: 36

                            Text {
                                anchors.left:
                                parent.left

                                anchors.leftMargin:
                                12

                                anchors.verticalCenter:
                                parent.verticalCenter

                                text:
                                "WI-FI NETWORKS"

                                color:
                                root.colFgBright

                                font.family:
                                "JetBrainsMono Nerd Font"

                                font.pixelSize: 9
                                font.bold: true
                            }

                            Row {
                                anchors.right:
                                parent.right

                                anchors.rightMargin:
                                12

                                anchors.verticalCenter:
                                parent.verticalCenter

                                spacing: 6

                                Rectangle {
                                    width: 70
                                    height: 22

                                    color:
                                    wifiPwrHover.hovered
                                    ? root.colSelBg
                                    : root.colBg

                                    Text {
                                        anchors.centerIn:
                                        parent

                                        text:
                                        root.wifiState ===
                                        "enabled"
                                        ? "TURN OFF"
                                        : "TURN ON"

                                        color:
                                        root.wifiState ===
                                        "enabled"
                                        ? root.colAccent
                                        : root.colFgBright

                                        font.family:
                                        "JetBrainsMono Nerd Font"

                                        font.pixelSize: 8
                                        font.bold: true
                                    }

                                    HoverHandler {
                                        id: wifiPwrHover
                                    }

                                    TapHandler {
                                        onTapped:
                                        root.toggleWifi()
                                    }
                                }

                                Rectangle {
                                    width: 60
                                    height: 22

                                    color:
                                    wifiScanHover.hovered
                                    ? root.colSelBg
                                    : root.colBg

                                    Text {
                                        anchors.centerIn:
                                        parent

                                        text:
                                        "SCAN"

                                        color:
                                        root.colFgBright

                                        font.family:
                                        "JetBrainsMono Nerd Font"

                                        font.pixelSize: 8
                                        font.bold: true
                                    }

                                    HoverHandler {
                                        id: wifiScanHover
                                    }

                                    TapHandler {
                                        onTapped: {
                                            if (
                                                !wifiScanProc.running
                                            ) {
                                                wifiScanProc.running =
                                                true
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        ListView {
                            anchors.top:
                            wifiHeader.bottom

                            anchors.left:
                            parent.left

                            anchors.right:
                            parent.right

                            anchors.bottom:
                            parent.bottom

                            anchors.margins:
                            6

                            clip: true

                            model:
                            wifiModel

                            spacing: 2

                            delegate: Rectangle {
                                required property string ssid
                                required property string signal
                                required property string security
                                required property bool active

                                width:
                                ListView.view.width

                                height: 32

                                color:
                                wifiItemHover.hovered
                                ? root.colSelBg
                                : (
                                    active
                                    ? root.colPurple
                                    : root.colBg
                                )

                                Row {
                                    anchors.left:
                                    parent.left

                                    anchors.leftMargin:
                                    10

                                    anchors.verticalCenter:
                                    parent.verticalCenter

                                    spacing: 8

                                    Text {
                                        text:
                                        active
                                        ? "●"
                                        : "○"

                                        color:
                                        active
                                        ? root.colAccent
                                        : root.colFg

                                        font.pixelSize: 8
                                    }

                                    Text {
                                        text:
                                        ssid

                                        color:
                                        root.colFgBright

                                        font.family:
                                        "JetBrainsMono Nerd Font"

                                        font.pixelSize: 8

                                        font.bold:
                                        active
                                    }
                                }

                                Row {
                                    anchors.right:
                                    parent.right

                                    anchors.rightMargin:
                                    10

                                    anchors.verticalCenter:
                                    parent.verticalCenter

                                    spacing: 10

                                    Text {
                                        text:
                                        security

                                        color:
                                        root.colFg

                                        font.family:
                                        "JetBrainsMono Nerd Font"

                                        font.pixelSize: 7
                                    }

                                    Text {
                                        text:
                                        signal

                                        color:
                                        root.colFgBright

                                        font.family:
                                        "JetBrainsMono Nerd Font"

                                        font.pixelSize: 8
                                    }
                                }

                                HoverHandler {
                                    id: wifiItemHover
                                }

                                TapHandler {
                                    onTapped:
                                    root.connectWifi(
                                        ssid
                                    )
                                }
                            }
                        }
                    }

                    // =================================================
                    // BLUETOOTH DRAWER
                    // =================================================

                    Item {
                        anchors.fill:
                        parent

                        visible:
                        root.activeMenu === "bt"

                        Item {
                            id: btHeader

                            anchors.top:
                            parent.top

                            anchors.left:
                            parent.left

                            anchors.right:
                            parent.right

                            height: 36

                            Text {
                                anchors.left:
                                parent.left

                                anchors.leftMargin:
                                12

                                anchors.verticalCenter:
                                parent.verticalCenter

                                text:
                                "BLUETOOTH DEVICES"

                                color:
                                root.colFgBright

                                font.family:
                                "JetBrainsMono Nerd Font"

                                font.pixelSize: 9
                                font.bold: true
                            }

                            Row {
                                anchors.right:
                                parent.right

                                anchors.rightMargin:
                                12

                                anchors.verticalCenter:
                                parent.verticalCenter

                                spacing: 6

                                // -----------------------------------------
                                // BT POWER
                                // -----------------------------------------

                                Rectangle {
                                    width: 70
                                    height: 22

                                    color:
                                    btPwrHover.hovered
                                    ? root.colSelBg
                                    : root.colBg

                                    Text {
                                        anchors.centerIn:
                                        parent

                                        text:
                                        root.bluetoothEnabled
                                        ? "TURN OFF"
                                        : "TURN ON"

                                        color:
                                        root.bluetoothEnabled
                                        ? root.colAccent
                                        : root.colFgBright

                                        font.family:
                                        "JetBrainsMono Nerd Font"

                                        font.pixelSize: 8
                                        font.bold: true
                                    }

                                    HoverHandler {
                                        id: btPwrHover
                                    }

                                    TapHandler {
                                        onTapped:
                                        root.toggleBluetooth()
                                    }
                                }

                                // -----------------------------------------
                                // BT SCAN
                                // -----------------------------------------

                                Rectangle {
                                    width: 70
                                    height: 22

                                    color:
                                    btScanHover.hovered
                                    ? root.colSelBg
                                    : root.colBg

                                    Text {
                                        anchors.centerIn:
                                        parent

                                        text:
                                        root.bluetoothScanning
                                        ? "SCANNING"
                                        : "SCAN"

                                        color:
                                        root.colFgBright

                                        font.family:
                                        "JetBrainsMono Nerd Font"

                                        font.pixelSize: 8
                                        font.bold: true
                                    }

                                    HoverHandler {
                                        id: btScanHover
                                    }

                                    TapHandler {
                                        onTapped: {
                                            if (
                                                root.bluetoothEnabled
                                            ) {
                                                root.startBtDiscovery()
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // =================================================
                        // BLUETOOTH CONTENT
                        // =================================================

                        Flickable {
                            id: btFlick

                            anchors.top:
                            btHeader.bottom

                            anchors.left:
                            parent.left

                            anchors.right:
                            parent.right

                            anchors.bottom:
                            parent.bottom

                            anchors.margins:
                            6

                            clip: true

                            contentWidth:
                            width

                            contentHeight:
                            btContent.height

                            boundsBehavior:
                            Flickable.StopAtBounds

                            Column {
                                id: btContent

                                width:
                                btFlick.width

                                spacing: 2

                                // -----------------------------------------
                                // PAIRED HEADER
                                // -----------------------------------------

                                Rectangle {
                                    width:
                                    parent.width

                                    height: 26

                                    color:
                                    root.colPurple

                                    Text {
                                        anchors.left:
                                        parent.left

                                        anchors.leftMargin:
                                        8

                                        anchors.verticalCenter:
                                        parent.verticalCenter

                                        text:
                                        "PAIRED DEVICES"

                                        color:
                                        root.colFgBright

                                        font.family:
                                        "JetBrainsMono Nerd Font"

                                        font.pixelSize: 8
                                        font.bold: true
                                    }
                                }

                                // -----------------------------------------
                                // PAIRED DEVICES
                                // -----------------------------------------

                                Repeater {
                                    model:
                                    btPairedModel

                                    delegate: Rectangle {
                                        required property string mac
                                        required property string name
                                        required property bool connected

                                        width:
                                        btContent.width

                                        height: 32

                                        color:
                                        pairedHover.hovered
                                        ? root.colSelBg
                                        : (
                                            connected
                                            ? root.colPurple
                                            : root.colBg
                                        )

                                        Row {
                                            anchors.left:
                                            parent.left

                                            anchors.leftMargin:
                                            10

                                            anchors.verticalCenter:
                                            parent.verticalCenter

                                            spacing: 8

                                            Text {
                                                width: 10

                                                horizontalAlignment:
                                                Text.AlignHCenter

                                                text:
                                                connected
                                                ? "●"
                                                : "◆"

                                                color:
                                                connected
                                                ? root.colAccent
                                                : root.colPink

                                                font.pixelSize: 8
                                            }

                                            Column {
                                                anchors.verticalCenter:
                                                parent.verticalCenter

                                                spacing: 1

                                                Text {
                                                    width: 390

                                                    text:
                                                    name

                                                    color:
                                                    root.colFgBright

                                                    font.family:
                                                    "JetBrainsMono Nerd Font"

                                                    font.pixelSize: 8
                                                    font.bold: true

                                                    elide:
                                                    Text.ElideRight
                                                }

                                                Text {
                                                    text:
                                                    mac

                                                    color:
                                                    root.colFg

                                                    font.family:
                                                    "JetBrainsMono Nerd Font"

                                                    font.pixelSize: 6
                                                }
                                            }
                                        }

                                        Rectangle {
                                            anchors.right:
                                            parent.right

                                            anchors.rightMargin:
                                            10

                                            anchors.verticalCenter:
                                            parent.verticalCenter

                                            width:
                                            connected
                                            ? 82
                                            : 72

                                            height: 20

                                            color:
                                            pairedButtonHover.hovered
                                            ? root.colSelBg
                                            : root.colNavy

                                            Text {
                                                anchors.centerIn:
                                                parent

                                                text:
                                                connected
                                                ? "DISCONNECT"
                                                : "CONNECT"

                                                color:
                                                connected
                                                ? root.colPink
                                                : root.colFgBright

                                                font.family:
                                                "JetBrainsMono Nerd Font"

                                                font.pixelSize: 7
                                                font.bold: true
                                            }

                                            HoverHandler {
                                                id: pairedButtonHover
                                            }

                                            TapHandler {
                                                onTapped:
                                                root.toggleBtDevice(
                                                    mac,
                                                    connected
                                                )
                                            }
                                        }

                                        HoverHandler {
                                            id: pairedHover
                                        }
                                    }
                                }

                                // -----------------------------------------
                                // NO PAIRED DEVICES
                                // -----------------------------------------

                                Rectangle {
                                    visible:
                                    btPairedModel.count === 0

                                    width:
                                    parent.width

                                    height: 28

                                    color:
                                    root.colBg

                                    Text {
                                        anchors.left:
                                        parent.left

                                        anchors.leftMargin:
                                        10

                                        anchors.verticalCenter:
                                        parent.verticalCenter

                                        text:
                                        "No paired devices"

                                        color:
                                        root.colFg

                                        font.family:
                                        "JetBrainsMono Nerd Font"

                                        font.pixelSize: 7
                                    }
                                }

                                // -----------------------------------------
                                // NEARBY HEADER
                                // -----------------------------------------

                                Rectangle {
                                    width:
                                    parent.width

                                    height: 26

                                    color:
                                    root.colPurple

                                    Text {
                                        anchors.left:
                                        parent.left

                                        anchors.leftMargin:
                                        8

                                        anchors.verticalCenter:
                                        parent.verticalCenter

                                        text:
                                        "NEARBY UNPAIRED"

                                        color:
                                        root.colFgBright

                                        font.family:
                                        "JetBrainsMono Nerd Font"

                                        font.pixelSize: 8
                                        font.bold: true
                                    }
                                }

                                // -----------------------------------------
                                // NEARBY UNPAIRED
                                // -----------------------------------------

                                Repeater {
                                    model:
                                    btNearbyModel

                                    delegate: Rectangle {
                                        required property string mac
                                        required property string name

                                        width:
                                        btContent.width

                                        height: 32

                                        color:
                                        nearbyHover.hovered
                                        ? root.colSelBg
                                        : root.colBg

                                        Row {
                                            anchors.left:
                                            parent.left

                                            anchors.leftMargin:
                                            10

                                            anchors.verticalCenter:
                                            parent.verticalCenter

                                            spacing: 8

                                            Text {
                                                width: 10

                                                horizontalAlignment:
                                                Text.AlignHCenter

                                                text:
                                                "○"

                                                color:
                                                root.colFg

                                                font.pixelSize: 8
                                            }

                                            Column {
                                                anchors.verticalCenter:
                                                parent.verticalCenter

                                                spacing: 1

                                                Text {
                                                    width: 390

                                                    text:
                                                    name

                                                    color:
                                                    root.colFgBright

                                                    font.family:
                                                    "JetBrainsMono Nerd Font"

                                                    font.pixelSize: 8

                                                    elide:
                                                    Text.ElideRight
                                                }

                                                Text {
                                                    text:
                                                    mac

                                                    color:
                                                    root.colFg

                                                    font.family:
                                                    "JetBrainsMono Nerd Font"

                                                    font.pixelSize: 6
                                                }
                                            }
                                        }

                                        Rectangle {
                                            anchors.right:
                                            parent.right

                                            anchors.rightMargin:
                                            10

                                            anchors.verticalCenter:
                                            parent.verticalCenter

                                            width: 52
                                            height: 20

                                            color:
                                            nearbyButtonHover.hovered
                                            ? root.colSelBg
                                            : root.colNavy

                                            Text {
                                                anchors.centerIn:
                                                parent

                                                text:
                                                "PAIR"

                                                color:
                                                root.colAccent

                                                font.family:
                                                "JetBrainsMono Nerd Font"

                                                font.pixelSize: 7
                                                font.bold: true
                                            }

                                            HoverHandler {
                                                id: nearbyButtonHover
                                            }

                                            TapHandler {
                                                onTapped:
                                                root.pairBtDevice(
                                                    mac
                                                )
                                            }
                                        }

                                        HoverHandler {
                                            id: nearbyHover
                                        }
                                    }
                                }

                                // -----------------------------------------
                                // NO NEARBY DEVICES
                                // -----------------------------------------

                                Rectangle {
                                    visible:
                                    btNearbyModel.count === 0

                                    width:
                                    parent.width

                                    height: 28

                                    color:
                                    root.colBg

                                    Text {
                                        anchors.left:
                                        parent.left

                                        anchors.leftMargin:
                                        10

                                        anchors.verticalCenter:
                                        parent.verticalCenter

                                        text:
                                        root.bluetoothScanning
                                        ? "Scanning for devices..."
                                        : "Press SCAN to find devices"

                                        color:
                                        root.colFg

                                        font.family:
                                        "JetBrainsMono Nerd Font"

                                        font.pixelSize: 7
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ============================================================
    // CLEANUP
    // ============================================================

    Component.onDestruction: {
        if (
            root.btOwnsDiscovery &&
            root.btAdapter &&
            root.btAdapter.discovering
        ) {
            root.btAdapter.discovering = false
        }
    }
}
