import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell.Services.UPower

Item {
    id: root

    property var targetScreen: null

    // ============================================================
    // SETTINGS
    // ============================================================

    readonly property int panelWidth: 770
    readonly property int panelHeight: 48
    readonly property int maxExpandedContentHeight: 268
    readonly property int triggerWidth: 180
    readonly property int triggerHeight: 3
    readonly property int borderWidth: 2

    readonly property int animationDuration: 250
    readonly property int triggerExpandDuration: 500
    readonly property int triggerCollapseDuration: 500
    readonly property int triggerColorDuration: 100
    readonly property int hideDelay: 300
    readonly property real panelOpacity: 0.95

    readonly property real triggerExpansionCurve: 0.6

    // ============================================================
    // EASING
    // ============================================================

    readonly property int openingEasing: Easing.OutExpo
    readonly property int closingEasing: Easing.OutExpo

    readonly property int triggerOpeningEasing: Easing.OutExpo
    readonly property int triggerClosingEasing: Easing.OutExpo

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

    property string currentTime: ""
    property string powerProfile: "balanced"
    property bool insideTrigger: false
    property bool insideDrawer: false
    property real progress: 0
    property real triggerProgress: 0.0
    property string activeMenu: ""

    property real volumeLevel: 0.70
    property bool isMuted: false

    property string wifiState: "unknown"
    property string wifiSsid: "Wi-Fi"

    // Wi-Fi password prompt / connect state
    property string wifiPromptSsid: ""       // network we're asking a password for
    property string wifiConnectingSsid: ""   // network currently being connected
    property string wifiError: ""
    property var wifiSaved: []               // saved Wi-Fi profile names

    // fast-refresh burst (after clicks / connects)
    property int burstLeft: 0

    property int sysBatteryPct: -1
    property bool sysBatteryCharging: false
    property bool hasBattery: true

    readonly property var battery: UPower.displayDevice

    readonly property int batteryPercentage: {
        if (root.sysBatteryPct >= 0)
            return root.sysBatteryPct

        if (root.battery && root.battery.ready) {
            const p = root.battery.percentage
            return Math.round(p <= 1 ? p * 100 : p)
        }

        return 0
    }

    readonly property bool batteryCharging: {
        if (root.sysBatteryPct >= 0)
            return root.sysBatteryCharging

        if (root.battery && root.battery.ready)
            return root.battery.changeRate > 0 ||
                   root.battery.batteryState === 1

        return false
    }

    readonly property color batteryColor:
        !root.hasBattery
        ? root.colFgBright
        : root.batteryPercentage <= 15
        ? root.colAccent
        : root.batteryPercentage <= 30
        ? root.colPink
        : root.batteryCharging
        ? root.colRose
        : root.colFgBright

    readonly property bool triggerBarExpanded:
        root.insideTrigger ||
        root.insideDrawer

    onWifiPromptSsidChanged: {
        if (wifiPromptSsid !== "")
            Qt.callLater(function() { wifiPassInput.forceActiveFocus() })
    }

    // ============================================================
    // CLOCK
    // ============================================================

    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true

        onTriggered:
            root.currentTime =
                Qt.formatDateTime(new Date(), "hh:mm:ss AP")
    }

    // ============================================================
    // BLUETOOTH
    // ============================================================

    readonly property var btAdapter: Bluetooth.defaultAdapter

    readonly property var btDevices:
        Bluetooth.devices
        ? Bluetooth.devices.values
        : []

    readonly property bool bluetoothEnabled:
        root.btAdapter !== null &&
        root.btAdapter.enabled

    readonly property bool bluetoothScanning:
        root.btAdapter !== null &&
        root.btAdapter.discovering

    readonly property string bluetoothDeviceName: {
        for (const d of root.btDevices) {
            if (d && d.connected)
                return d.name ||
                       d.deviceName ||
                       d.address ||
                       ""
        }

        return ""
    }

    ListModel { id: wifiModel }
    ListModel { id: btPairedModel }
    ListModel { id: btNearbyModel }

    property bool btOwnsDiscovery: false

    Timer {
        id: btDiscoveryStopTimer
        interval: 8000
        onTriggered: root.stopBtDiscovery()
    }

    Timer {
        interval: 250
        repeat: true
        triggeredOnStart: true
        running: root.activeMenu === "bt"

        onTriggered: root.refreshBtModels()
    }

    Timer {
        id: menuScanDelayTimer
        interval: 100

        onTriggered: {
            if (root.activeMenu === "wifi") {
                wifiSavedProc.running = true
                root.scanWifi()
            } else if (root.activeMenu === "bt") {
                root.startBtDiscovery()
            }
        }
    }

    function setActiveMenu(menu) {
        if (root.activeMenu === menu) {
            root.activeMenu = ""
            menuScanDelayTimer.stop()

            if (menu === "bt")
                root.stopBtDiscovery()

            return
        }

        if (root.activeMenu === "bt")
            root.stopBtDiscovery()

        root.activeMenu = menu
        menuScanDelayTimer.restart()
    }

    onActiveMenuChanged: {
        if (root.activeMenu === "bt")
            root.refreshBtModels()

        if (root.activeMenu !== "wifi") {
            root.wifiPromptSsid = ""
            root.wifiError = ""
            wifiPassInput.text = ""
        }
    }

    function findBtDevice(mac) {
        for (const d of root.btDevices) {
            if (d && d.address === mac)
                return d
        }

        return null
    }

    function refreshBtModels() {
        btPairedModel.clear()
        btNearbyModel.clear()

        const paired = []
        const nearby = []

        for (const d of root.btDevices) {
            if (!d || !d.address)
                continue

            if (d.paired || d.bonded)
                paired.push(d)
            else if (root.bluetoothScanning)
                nearby.push(d)
        }

        const sortDevices = function(a, b) {
            const an = (a.name || a.deviceName || a.address).toLowerCase()
            const bn = (b.name || b.deviceName || b.address).toLowerCase()
            return an.localeCompare(bn)
        }

        paired.sort(sortDevices)
        nearby.sort(sortDevices)

        for (const d of paired) {
            btPairedModel.append({
                mac: d.address,
                name: d.name || d.deviceName || d.address,
                connected: !!d.connected
            })
        }

        for (const d of nearby) {
            btNearbyModel.append({
                mac: d.address,
                name: d.name || d.deviceName || d.address
            })
        }
    }

    function startBtDiscovery() {
        if (!root.btAdapter || !root.btAdapter.enabled)
            return

        if (!root.btAdapter.discovering) {
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

    function toggleBtDevice(mac, connected) {
        const d = root.findBtDevice(mac)

        if (!d)
            return

        if (connected) {
            if (typeof d.disconnect === "function")
                d.disconnect()
        } else {
            if (typeof d.connect === "function")
                d.connect()
        }

        root.refreshBtModels()
    }

    function pairBtDevice(mac) {
        const d = root.findBtDevice(mac)

        if (!d)
            return

        Quickshell.execDetached({
            command: ["bluetoothctl", "agent", "on"]
        })

        Quickshell.execDetached({
            command: ["bluetoothctl", "default-agent"]
        })

        if (typeof d.pair === "function")
            d.pair()

        root.refreshBtModels()
    }

    function toggleBluetooth() {
        if (!root.btAdapter)
            return

        root.btAdapter.enabled = !root.btAdapter.enabled

        if (!root.btAdapter.enabled) {
            root.btOwnsDiscovery = false
            btDiscoveryStopTimer.stop()
        }
    }

    // ============================================================
    // FAST REFRESH HELPERS
    // ============================================================

    function refreshWifiStatus() {
        if (!wifiStatusProc.running)
            wifiStatusProc.running = true
    }

    function refreshVolume() {
        if (!volumeStatusProc.running)
            volumeStatusProc.running = true
    }

    function refreshPower() {
        if (!powerProfileStatusProc.running)
            powerProfileStatusProc.running = true
    }

    function scanWifi() {
        if (!wifiScanProc.running)
            wifiScanProc.running = true
    }

    // poll rapidly for a few seconds (called after clicks / connects)
    function burstRefresh(n) {
        root.burstLeft = n
        refreshWifiStatus()
        refreshVolume()
        refreshPower()
    }

    Timer {
        interval: 350
        repeat: true
        running: root.burstLeft > 0

        onTriggered: {
            root.burstLeft--
            root.refreshWifiStatus()
            root.refreshVolume()

            if (root.activeMenu === "wifi" && root.burstLeft % 4 === 0)
                root.scanWifi()
        }
    }

    // keep the network list fresh while the Wi-Fi menu is open
    Timer {
        interval: 5000
        repeat: true
        running: root.activeMenu === "wifi"
        onTriggered: root.scanWifi()
    }

    // ============================================================
    // POWER PROFILE
    // ============================================================

    Process {
        id: powerProfileStatusProc

        command: [
            "cat",
            "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
        ]

        stdout: StdioCollector {
            onStreamFinished: {
                const r = this.text.trim().toLowerCase()

                root.powerProfile =
                    r === "powersave"
                    ? "powersave"
                    : r === "performance"
                    ? "performance"
                    : "balanced"
            }
        }
    }

    function setPowerProfile(mode) {
        const governor =
            mode === "powersave"
            ? "powersave"
            : mode === "performance"
            ? "performance"
            : "schedutil"

        Quickshell.execDetached({
            command: [
                "sudo",
                "cpupower",
                "frequency-set",
                "-g",
                governor
            ]
        })

        root.powerProfile = mode
        root.burstRefresh(6)
    }

    function cyclePowerProfile() {
        setPowerProfile(
            root.powerProfile === "powersave"
            ? "balanced"
            : root.powerProfile === "balanced"
            ? "performance"
            : "powersave"
        )
    }

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
            "bat=$(find /sys/class/power_supply -maxdepth 1 -type l -name 'BAT*' | head -n1); " +
            "if [ -z \"$bat\" ]; then echo 'N/A|AC'; exit; fi; " +
            "now=$(cat \"$bat/energy_now\" 2>/dev/null); " +
            "full=$(cat \"$bat/energy_full\" 2>/dev/null); " +
            "if [ -z \"$now\" ] || [ -z \"$full\" ]; then " +
            "now=$(cat \"$bat/charge_now\" 2>/dev/null); " +
            "full=$(cat \"$bat/charge_full\" 2>/dev/null); fi; " +
            "if [ -n \"$now\" ] && [ -n \"$full\" ] && [ \"$full\" -gt 0 ]; then " +
            "cap=$((now * 100 / full)); " +
            "else cap=$(cat \"$bat/capacity\" 2>/dev/null); fi; " +
            "stat=$(cat \"$bat/status\" 2>/dev/null); " +
            "printf '%s|%s' \"${cap:-0}\" \"${stat:-Unknown}\""
        ]

        stdout: StdioCollector {
            onStreamFinished: {
                const p = this.text.trim().split("|")

                if (p.length >= 2 && p[0] !== "N/A") {
                    root.hasBattery = true
                    root.sysBatteryPct = Math.max(
                        0,
                        Math.min(100, parseInt(p[0]) || 0)
                    )
                    root.sysBatteryCharging =
                        p[1].toLowerCase() === "charging"
                } else {
                    root.hasBattery = false
                    root.sysBatteryPct = 100
                    root.sysBatteryCharging = false
                }
            }
        }
    }

    // runs wpctl set-volume / set-mute, then refreshes the real value
    Process {
        id: volProc
        onExited: root.refreshVolume()
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
                const t = this.text.trim()
                const m = t.match(/Volume:\s+([0-9.]+)/)

                if (m) {
                    root.volumeLevel = Math.max(
                        0,
                        Math.min(1, parseFloat(m[1]))
                    )
                }

                root.isMuted = t.indexOf("[MUTED]") !== -1
            }
        }
    }

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
                const p = this.text.trim().split("|")

                root.wifiState = p[0] || "unknown"

                root.wifiSsid =
                    p.length > 1 && p[1]
                    ? p[1]
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

                const seen = {}

                for (const raw of this.text.trim().split("\n")) {
                    if (!raw.trim())
                        continue

                    const safe = raw.replace(/\\:/g, "___COLON___")
                    const p = safe.split(":")

                    if (p.length < 4)
                        continue

                    const active = p[0].trim() === "*"
                    const signal = p[p.length - 1].trim()

                    const security =
                        p[p.length - 2]
                        .replace(/___COLON___/g, ":")
                        .trim()

                    const ssid =
                        p.slice(1, p.length - 2)
                        .join(":")
                        .replace(/___COLON___/g, ":")
                        .trim()

                    if (!ssid || seen[ssid] !== undefined)
                        continue

                    seen[ssid] = true

                    wifiModel.append({
                        ssid: ssid,
                        signal: (signal || "0") + "%",
                        security:
                            security && security !== "--"
                            ? security
                            : "Open",
                        active: active
                    })
                }
            }
        }
    }

    // saved Wi-Fi profiles, so known networks don't ask for a password
    Process {
        id: wifiSavedProc

        command: [
            "sh",
            "-c",
            "nmcli -t -f NAME,TYPE connection show | " +
            "grep ':802-11-wireless$' | " +
            "sed 's/:802-11-wireless$//'"
        ]

        stdout: StdioCollector {
            onStreamFinished: {
                root.wifiSaved = this.text.split("\n")
                    .map(s => s.replace(/\\:/g, ":").trim())
                    .filter(s => s.length > 0)
            }
        }
    }

    // connects to a network (command is set in connectWifi)
    Process {
        id: wifiConnectProc

        property string pendingSsid: ""
        property bool usedPassword: false

        onExited: (code, status) => {
            const ssid = pendingSsid
            root.wifiConnectingSsid = ""

            if (code === 0) {
                root.wifiPromptSsid = ""
                root.wifiError = ""
                wifiPassInput.text = ""
                wifiSavedProc.running = true
            } else {
                // remove the half-created profile that has the bad password
                if (usedPassword) {
                    Quickshell.execDetached({
                        command: ["nmcli", "connection", "delete", "id", ssid]
                    })
                }

                root.wifiError = "FAILED - CHECK PASSWORD"
                root.wifiPromptSsid = ssid
                wifiPassInput.text = ""
            }

            root.burstRefresh(12)
            root.scanWifi()
        }
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

        root.burstRefresh(12)
    }

    function connectWifi(ssid, pass) {
        if (wifiConnectProc.running)
            return

        root.wifiConnectingSsid = ssid
        root.wifiError = ""

        wifiConnectProc.pendingSsid = ssid
        wifiConnectProc.usedPassword = pass.length > 0

        wifiConnectProc.command = pass.length > 0
            ? ["nmcli", "-w", "20", "dev", "wifi", "connect", ssid, "password", pass]
            : ["nmcli", "-w", "20", "dev", "wifi", "connect", ssid]

        wifiConnectProc.running = true
        root.burstRefresh(20)
    }

    // click on a network row
    function onWifiTapped(ssid, security, active) {
        if (active || root.wifiConnectingSsid !== "")
            return

        if (security === "Open" || root.wifiSaved.indexOf(ssid) !== -1) {
            root.wifiPromptSsid = ""
            connectWifi(ssid, "")
        } else {
            root.wifiError = ""
            wifiPassInput.text = ""
            root.wifiPromptSsid = ssid
        }
    }

    function submitWifiPassword() {
        if (root.wifiPromptSsid === "" || root.wifiConnectingSsid !== "")
            return

        if (wifiPassInput.text.length < 8) {
            root.wifiError = "MIN 8 CHARACTERS"
            return
        }

        connectWifi(root.wifiPromptSsid, wifiPassInput.text)
    }

    function cancelWifiPrompt() {
        root.wifiPromptSsid = ""
        root.wifiError = ""
        wifiPassInput.text = ""
    }

    // ============================================================
    // STATUS POLLING
    // ============================================================

    property int pollCycle: 0

    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true

        onTriggered: {
            root.pollCycle = (root.pollCycle + 1) % 3

            // fast items: every second
            root.refreshVolume()
            root.refreshWifiStatus()

            // slow items: every 3 seconds
            if (root.pollCycle === 0) {
                if (!batteryStatusProc.running)
                    batteryStatusProc.running = true

                root.refreshPower()
            }
        }
    }

    // ============================================================
    // DRAWER CONTROL
    // ============================================================

    function show() {
        hideTimer.stop()

        revealAnimation.from = root.progress
        revealAnimation.to = 1
        revealAnimation.restart()

        triggerAnimation.from = root.triggerProgress
        triggerAnimation.to = 1.0
        triggerAnimation.restart()
    }

    function scheduleHide() {
        hideTimer.restart()
    }

    Timer {
        id: hideTimer
        interval: root.hideDelay

        onTriggered: {
            // don't close while typing a Wi-Fi password
            if (!root.insideTrigger &&
                !root.insideDrawer &&
                root.wifiPromptSsid === "") {

                root.activeMenu = ""
                root.stopBtDiscovery()

                revealAnimation.from = root.progress
                revealAnimation.to = 0
                revealAnimation.restart()

                triggerAnimation.from = root.triggerProgress
                triggerAnimation.to = 0.0
                triggerAnimation.restart()
            }
        }
    }

    // ============================================================
    // MAIN DRAWER ANIMATION
    // ============================================================

    NumberAnimation {
        id: revealAnimation

        target: root
        property: "progress"
        duration: root.animationDuration

        easing.type:
            to === 0
            ? root.closingEasing
            : root.openingEasing
    }

    NumberAnimation {
        id: triggerAnimation

        target: root
        property: "triggerProgress"

        duration: root.triggerExpandDuration
        easing.type: Easing.OutExpo
    }

    readonly property real targetExpandedHeight: {
        if (root.activeMenu === "wifi") {
            const count = wifiModel.count
            const prompt = root.wifiPromptSsid !== "" ? 40 : 0

            const base = count === 0
                ? 64
                : 36 +
                  count * 32 +
                  (count > 1 ? (count - 1) * 2 : 0) +
                  12

            return Math.min(
                base + prompt,
                root.maxExpandedContentHeight
            )
        }

        if (root.activeMenu === "bt") {
            const paired =
                26 + Math.max(btPairedModel.count * 34, 28)

            const nearby =
                26 + Math.max(btNearbyModel.count * 34, 28)

            return Math.min(
                paired + nearby + 12,
                root.maxExpandedContentHeight
            )
        }

        return 0
    }

    property real currentExpandedHeight: 0

    Behavior on currentExpandedHeight {
        NumberAnimation {
            duration: root.animationDuration
            easing.type: Easing.OutExpo
        }
    }

    onTargetExpandedHeightChanged:
        root.currentExpandedHeight = root.targetExpandedHeight

    // ============================================================
    // TOP TRIGGER
    // ============================================================

    PanelWindow {
        screen: root.targetScreen
        anchors.top: true
        implicitWidth: root.panelWidth
        implicitHeight: Math.max(root.triggerHeight, root.borderWidth)
        exclusiveZone: 0
        focusable: false
        color: "transparent"

        Rectangle {
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter

            height: root.triggerHeight + (root.borderWidth - root.triggerHeight) * root.triggerProgress

            width: root.triggerWidth + (root.panelWidth - root.triggerWidth) * Math.pow(root.triggerProgress, root.triggerExpansionCurve)

            color:
                root.triggerBarExpanded
                ? root.colAccent
                : root.colViolet

            Behavior on color {
                ColorAnimation {
                    duration: root.triggerColorDuration
                }
            }
        }

        MouseArea {
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.triggerWidth
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
    // MAIN DRAWER
    // ============================================================

    PanelWindow {
        id: drawerWindow

        screen: root.targetScreen
        anchors.top: true

        implicitWidth: root.panelWidth

        implicitHeight:
            root.panelHeight +
            root.maxExpandedContentHeight

        exclusiveZone: 0
        focusable: true
        color: "transparent"

        visible: root.progress > 0.01

        Item {
            anchors.fill: parent
            clip: true

            Rectangle {
                id: panel

                width: parent.width

                height:
                    root.panelHeight +
                    root.currentExpandedHeight

                transform: Translate {
                    y: -panel.height + panel.height * root.progress
                }

                color: Qt.rgba(
                    root.colBg.r,
                    root.colBg.g,
                    root.colBg.b,
                    root.panelOpacity
                )

                // left border
                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom

                    width: root.borderWidth

                    color:
                        root.insideDrawer
                        ? root.colAccent
                        : root.colViolet
                }

                // right border
                Rectangle {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom

                    width: root.borderWidth

                    color:
                        root.insideDrawer
                        ? root.colAccent
                        : root.colViolet
                }

                // bottom border
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom

                    height: root.borderWidth

                    color:
                        root.insideDrawer
                        ? root.colAccent
                        : root.colViolet
                }

                HoverHandler {
                    onHoveredChanged: {
                        root.insideDrawer = hovered

                        if (hovered)
                            hideTimer.stop()
                        else
                            root.scheduleHide()
                    }
                }

                // ========================================================
                // TOP BAR
                // ========================================================

                Item {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right

                    height: root.panelHeight

                    Row {
                        anchors.centerIn: parent
                        spacing: 8

                        // TIME
                        Rectangle {
                            width: 78
                            height: 28
                            color: root.colNavy

                            Text {
                                anchors.centerIn: parent

                                text: root.currentTime
                                color: root.colFgBright

                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 8
                                font.bold: true
                            }
                        }

                        // WALL
                        Rectangle {
                            width: 58
                            height: 28

                            color:
                                wallHover.hovered
                                ? root.colSelBg
                                : root.colNavy

                            Text {
                                anchors.centerIn: parent

                                text: "WALL"

                                color:
                                    wallHover.hovered
                                    ? root.colAccent
                                    : root.colFgBright

                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 8
                                font.bold: true
                            }

                            HoverHandler { id: wallHover }

                            TapHandler {
                                onTapped: wallflipperProc.startDetached()
                            }
                        }

                        // WI-FI
                        Rectangle {
                            width: 96
                            height: 28

                            color:
                                wifiHover.hovered ||
                                root.activeMenu === "wifi"
                                ? root.colSelBg
                                : root.colNavy

                            Text {
                                anchors.centerIn: parent

                                width: parent.width - 8

                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight

                                text:
                                    (
                                        root.wifiConnectingSsid !== ""
                                        ? "CONNECTING"
                                        : root.wifiState === "enabled"
                                        ? (
                                            root.wifiSsid === "Wi-Fi"
                                            ? "WIFI"
                                            : root.wifiSsid
                                        )
                                        : "WIFI OFF"
                                    ) +
                                    (
                                        root.activeMenu === "wifi"
                                        ? " ▲"
                                        : " ▼"
                                    )

                                color:
                                    root.wifiState === "enabled"
                                    ? root.colFgBright
                                    : root.colAccent

                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 7
                                font.bold: true
                            }

                            HoverHandler { id: wifiHover }

                            TapHandler {
                                acceptedButtons:
                                    Qt.LeftButton |
                                    Qt.RightButton

                                onTapped: function(_, button) {
                                    if (button === Qt.RightButton)
                                        root.toggleWifi()
                                    else
                                        root.setActiveMenu("wifi")
                                }
                            }
                        }

                        // BLUETOOTH
                        Rectangle {
                            width: 96
                            height: 28

                            color:
                                bluetoothHover.hovered ||
                                root.activeMenu === "bt"
                                ? root.colSelBg
                                : root.colNavy

                            Text {
                                anchors.centerIn: parent

                                width: parent.width - 8

                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight

                                text:
                                    (
                                        root.bluetoothEnabled
                                        ? (
                                            root.bluetoothDeviceName.length > 0
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

                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 7
                                font.bold: true
                            }

                            HoverHandler { id: bluetoothHover }

                            TapHandler {
                                acceptedButtons:
                                    Qt.LeftButton |
                                    Qt.RightButton

                                onTapped: function(_, button) {
                                    if (button === Qt.RightButton)
                                        root.toggleBluetooth()
                                    else
                                        root.setActiveMenu("bt")
                                }
                            }
                        }

                        // POWER
                        Rectangle {
                            width: 68
                            height: 28

                            color:
                                pwrHover.hovered
                                ? root.colSelBg
                                : root.colNavy

                            Text {
                                anchors.centerIn: parent

                                text:
                                    root.powerProfile === "powersave"
                                    ? "PWR: SAV"
                                    : root.powerProfile === "performance"
                                    ? "PWR: PRF"
                                    : "PWR: BAL"

                                color:
                                    root.powerProfile === "powersave"
                                    ? root.colRose
                                    : root.powerProfile === "performance"
                                    ? root.colAccent
                                    : root.colFgBright

                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 7
                                font.bold: true
                            }

                            HoverHandler { id: pwrHover }

                            TapHandler {
                                onTapped: root.cyclePowerProfile()
                            }
                        }

                        // BATTERY
                        Rectangle {
                            width: 58
                            height: 28
                            color: root.colNavy

                            Text {
                                anchors.centerIn: parent

                                text:
                                    !root.hasBattery
                                    ? "AC"
                                    : (
                                        (!root.battery || !root.battery.ready) &&
                                        root.sysBatteryPct < 0
                                    )
                                    ? "--"
                                    : (
                                        root.batteryCharging
                                        ? "CHG " + root.batteryPercentage + "%"
                                        : root.batteryPercentage + "%"
                                    )

                                color: root.batteryColor

                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 8
                                font.bold: true
                            }
                        }

                        // VOLUME TEXT
                        Text {
                            width: 32
                            height: parent.height

                            verticalAlignment: Text.AlignVCenter

                            text:
                                root.isMuted
                                ? "MUT"
                                : Math.round(root.volumeLevel * 100) + "%"

                            color:
                                root.isMuted
                                ? root.colAccent
                                : root.colFgBright

                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 8
                            font.bold: true
                        }

                        // VOLUME BAR
                        Item {
                            id: volTrack

                            width: 145
                            height: 14

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

                                Repeater {
                                    model: volTrack.stepCount

                                    Rectangle {
                                        required property int index

                                        width: volTrack.width / volTrack.stepCount
                                        height: volTrack.height

                                        property bool isActive:
                                            !root.isMuted &&
                                            root.volumeLevel >=
                                            ((index + 1) / volTrack.stepCount)

                                        color:
                                            isActive
                                            ? volTrack.stepColors[index]
                                            : root.colNavy
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent

                                function updateVol(mouse) {
                                    const value = Math.max(
                                        0,
                                        Math.min(1, mouse.x / width)
                                    )

                                    root.volumeLevel = value
                                    root.isMuted = false
                                    root.setVolume(value)
                                }

                                onPressed: mouse => updateVol(mouse)

                                onPositionChanged: mouse => {
                                    if (pressed)
                                        updateVol(mouse)
                                }
                            }
                        }

                        // MUTE
                        Rectangle {
                            width: 46
                            height: 28

                            color:
                                muteHover.hovered
                                ? root.colSelBg
                                : root.colNavy

                            Text {
                                anchors.centerIn: parent

                                text:
                                    root.isMuted
                                    ? "UNM"
                                    : "MUTE"

                                color:
                                    root.isMuted
                                    ? root.colAccent
                                    : root.colFg

                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 7
                                font.bold: true
                            }

                            HoverHandler { id: muteHover }

                            TapHandler {
                                onTapped: {
                                    root.isMuted = !root.isMuted
                                    root.toggleMute()
                                }
                            }
                        }
                    }
                }

                // ========================================================
                // EXPANDED CONTENT
                // ========================================================

                Rectangle {
                    id: expandedPanel

                    anchors.top: parent.top
                    anchors.topMargin: root.panelHeight

                    anchors.left: parent.left
                    anchors.leftMargin: root.borderWidth

                    anchors.right: parent.right
                    anchors.rightMargin: root.borderWidth

                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: root.borderWidth

                    clip: true

                    visible: root.currentExpandedHeight > 0

                    color: root.colNavy

                    // ====================================================
                    // WI-FI
                    // ====================================================

                    Item {
                        anchors.fill: parent

                        visible: root.activeMenu === "wifi"

                        Item {
                            id: wifiHeader

                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right

                            height: 36

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 12
                                anchors.verticalCenter: parent.verticalCenter

                                text: "WI-FI NETWORKS"
                                color: root.colFgBright

                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 9
                                font.bold: true
                            }

                            Row {
                                anchors.right: parent.right
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter

                                spacing: 6

                                Rectangle {
                                    width: 70
                                    height: 22

                                    color:
                                        wifiPwrHover.hovered
                                        ? root.colSelBg
                                        : root.colBg

                                    Text {
                                        anchors.centerIn: parent

                                        text:
                                            root.wifiState === "enabled"
                                            ? "TURN OFF"
                                            : "TURN ON"

                                        color:
                                            root.wifiState === "enabled"
                                            ? root.colAccent
                                            : root.colFgBright

                                        font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 8
                                        font.bold: true
                                    }

                                    HoverHandler { id: wifiPwrHover }

                                    TapHandler {
                                        onTapped: root.toggleWifi()
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
                                        anchors.centerIn: parent

                                        text: "SCAN"
                                        color: root.colFgBright

                                        font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 8
                                        font.bold: true
                                    }

                                    HoverHandler { id: wifiScanHover }

                                    TapHandler {
                                        onTapped: root.scanWifi()
                                    }
                                }
                            }
                        }

                        // ------------------------------------------------
                        // PASSWORD PROMPT
                        // (outside the list so rescans don't wipe typing)
                        // ------------------------------------------------
                        Rectangle {
                            id: wifiPassBar

                            anchors.top: wifiHeader.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: 6
                            anchors.rightMargin: 6

                            height: root.wifiPromptSsid !== "" ? 34 : 0
                            visible: height > 0
                            clip: true

                            color: root.colBg

                            Text {
                                id: passLabel

                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.verticalCenter: parent.verticalCenter

                                width: 190
                                elide: Text.ElideRight

                                text:
                                    root.wifiConnectingSsid !== ""
                                    ? "CONNECTING..."
                                    : root.wifiError !== ""
                                    ? root.wifiError
                                    : "PASSWORD: " + root.wifiPromptSsid

                                color:
                                    root.wifiError !== ""
                                    ? root.colAccent
                                    : root.colFgBright

                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 7
                                font.bold: true
                            }

                            Rectangle {
                                anchors.left: passLabel.right
                                anchors.leftMargin: 8
                                anchors.right: passBtns.left
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter

                                height: 22
                                color: root.colNavy

                                border.width: 1
                                border.color:
                                    wifiPassInput.activeFocus
                                    ? root.colAccent
                                    : root.colViolet

                                TextInput {
                                    id: wifiPassInput

                                    anchors.fill: parent
                                    anchors.margins: 5

                                    verticalAlignment: TextInput.AlignVCenter
                                    clip: true
                                    selectByMouse: true
                                    echoMode: TextInput.Password
                                    passwordCharacter: "•"
                                    enabled: root.wifiConnectingSsid === ""

                                    color: root.colFgBright
                                    font.family: "JetBrainsMono Nerd Font"
                                    font.pixelSize: 8

                                    Keys.onReturnPressed: root.submitWifiPassword()
                                    Keys.onEnterPressed: root.submitWifiPassword()
                                    Keys.onEscapePressed: root.cancelWifiPrompt()

                                    onTextChanged: {
                                        if (root.wifiError !== "")
                                            root.wifiError = ""
                                    }
                                }
                            }

                            Row {
                                id: passBtns

                                anchors.right: parent.right
                                anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter

                                spacing: 6

                                Rectangle {
                                    width: 70
                                    height: 22

                                    color:
                                        passOkHover.hovered
                                        ? root.colSelBg
                                        : root.colNavy

                                    Text {
                                        anchors.centerIn: parent

                                        text: "CONNECT"
                                        color: root.colAccent

                                        font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 7
                                        font.bold: true
                                    }

                                    HoverHandler { id: passOkHover }

                                    TapHandler {
                                        onTapped: root.submitWifiPassword()
                                    }
                                }

                                Rectangle {
                                    width: 56
                                    height: 22

                                    color:
                                        passCancelHover.hovered
                                        ? root.colSelBg
                                        : root.colNavy

                                    Text {
                                        anchors.centerIn: parent

                                        text: "CANCEL"
                                        color: root.colFgBright

                                        font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 7
                                        font.bold: true
                                    }

                                    HoverHandler { id: passCancelHover }

                                    TapHandler {
                                        onTapped: root.cancelWifiPrompt()
                                    }
                                }
                            }
                        }

                        ListView {
                            anchors.top: wifiPassBar.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom

                            anchors.margins: 6

                            clip: true
                            model: wifiModel
                            spacing: 2

                            delegate: Rectangle {
                                required property string ssid
                                required property string signal
                                required property string security
                                required property bool active

                                width: ListView.view.width
                                height: 32

                                color:
                                    wifiItemHover.hovered
                                    ? root.colSelBg
                                    : active
                                    ? root.colPurple
                                    : root.colBg

                                Row {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter

                                    spacing: 8

                                    Text {
                                        text:
                                            ssid === root.wifiConnectingSsid
                                            ? "◌"
                                            : active
                                            ? "●"
                                            : "○"

                                        color:
                                            active
                                            ? root.colAccent
                                            : root.colFg

                                        font.pixelSize: 8
                                    }

                                    Text {
                                        text: ssid
                                        color: root.colFgBright

                                        font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 8
                                        font.bold: active
                                    }
                                }

                                Row {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter

                                    spacing: 10

                                    Text {
                                        text: security
                                        color: root.colFg

                                        font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 7
                                    }

                                    Text {
                                        text: signal
                                        color: root.colFgBright

                                        font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 8
                                    }
                                }

                                HoverHandler { id: wifiItemHover }

                                TapHandler {
                                    onTapped: root.onWifiTapped(ssid, security, active)
                                }
                            }
                        }
                    }

                    // ====================================================
                    // BLUETOOTH
                    // ====================================================

                    Item {
                        anchors.fill: parent

                        visible: root.activeMenu === "bt"

                        Item {
                            id: btHeader

                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right

                            height: 36

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 12
                                anchors.verticalCenter: parent.verticalCenter

                                text: "BLUETOOTH DEVICES"
                                color: root.colFgBright

                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 9
                                font.bold: true
                            }

                            Row {
                                anchors.right: parent.right
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter

                                spacing: 6

                                Rectangle {
                                    width: 70
                                    height: 22

                                    color:
                                        btPwrHover.hovered
                                        ? root.colSelBg
                                        : root.colBg

                                    Text {
                                        anchors.centerIn: parent

                                        text:
                                            root.bluetoothEnabled
                                            ? "TURN OFF"
                                            : "TURN ON"

                                        color:
                                            root.bluetoothEnabled
                                            ? root.colAccent
                                            : root.colFgBright

                                        font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 8
                                        font.bold: true
                                    }

                                    HoverHandler { id: btPwrHover }

                                    TapHandler {
                                        onTapped: root.toggleBluetooth()
                                    }
                                }

                                Rectangle {
                                    width: 70
                                    height: 22

                                    color:
                                        btScanHover.hovered
                                        ? root.colSelBg
                                        : root.colBg

                                    Text {
                                        anchors.centerIn: parent

                                        text:
                                            root.bluetoothScanning
                                            ? "SCANNING"
                                            : "SCAN"

                                        color: root.colFgBright

                                        font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 8
                                        font.bold: true
                                    }

                                    HoverHandler { id: btScanHover }

                                    TapHandler {
                                        onTapped: {
                                            if (root.bluetoothEnabled)
                                                root.startBtDiscovery()
                                        }
                                    }
                                }
                            }
                        }

                        Flickable {
                            id: btFlick

                            anchors.top: btHeader.bottom
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom

                            anchors.margins: 6

                            clip: true

                            contentWidth: width
                            contentHeight: btContent.height

                            boundsBehavior: Flickable.StopAtBounds

                            Column {
                                id: btContent

                                width: btFlick.width
                                spacing: 2

                                Rectangle {
                                    width: parent.width
                                    height: 26

                                    color: root.colPurple

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 8
                                        anchors.verticalCenter: parent.verticalCenter

                                        text: "PAIRED DEVICES"
                                        color: root.colFgBright

                                        font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 8
                                        font.bold: true
                                    }
                                }

                                Repeater {
                                    model: btPairedModel

                                    delegate: Rectangle {
                                        required property string mac
                                        required property string name
                                        required property bool connected

                                        width: btContent.width
                                        height: 32

                                        color:
                                            pairedHover.hovered
                                            ? root.colSelBg
                                            : connected
                                            ? root.colPurple
                                            : root.colBg

                                        Row {
                                            anchors.left: parent.left
                                            anchors.leftMargin: 10
                                            anchors.verticalCenter: parent.verticalCenter

                                            spacing: 8

                                            Text {
                                                width: 10
                                                horizontalAlignment: Text.AlignHCenter

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
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 1

                                                Text {
                                                    width: 390

                                                    text: name
                                                    color: root.colFgBright

                                                    font.family: "JetBrainsMono Nerd Font"
                                                    font.pixelSize: 8
                                                    font.bold: true

                                                    elide: Text.ElideRight
                                                }

                                                Text {
                                                    text: mac
                                                    color: root.colFg

                                                    font.family: "JetBrainsMono Nerd Font"
                                                    font.pixelSize: 6
                                                }
                                            }
                                        }

                                        Rectangle {
                                            anchors.right: parent.right
                                            anchors.rightMargin: 10
                                            anchors.verticalCenter: parent.verticalCenter

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
                                                anchors.centerIn: parent

                                                text:
                                                    connected
                                                    ? "DISCONNECT"
                                                    : "CONNECT"

                                                color:
                                                    connected
                                                    ? root.colPink
                                                    : root.colFgBright

                                                font.family: "JetBrainsMono Nerd Font"
                                                font.pixelSize: 7
                                                font.bold: true
                                            }

                                            HoverHandler { id: pairedButtonHover }

                                            TapHandler {
                                                onTapped: root.toggleBtDevice(mac, connected)
                                            }
                                        }

                                        HoverHandler { id: pairedHover }
                                    }
                                }

                                Rectangle {
                                    visible: btPairedModel.count === 0

                                    width: parent.width
                                    height: 28

                                    color: root.colBg

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter

                                        text: "No paired devices"
                                        color: root.colFg

                                        font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 7
                                    }
                                }

                                Rectangle {
                                    width: parent.width
                                    height: 26

                                    color: root.colPurple

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 8
                                        anchors.verticalCenter: parent.verticalCenter

                                        text: "NEARBY UNPAIRED"
                                        color: root.colFgBright

                                        font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 8
                                        font.bold: true
                                    }
                                }

                                Repeater {
                                    model: btNearbyModel

                                    delegate: Rectangle {
                                        required property string mac
                                        required property string name

                                        width: btContent.width
                                        height: 32

                                        color:
                                            nearbyHover.hovered
                                            ? root.colSelBg
                                            : root.colBg

                                        Row {
                                            anchors.left: parent.left
                                            anchors.leftMargin: 10
                                            anchors.verticalCenter: parent.verticalCenter

                                            spacing: 8

                                            Text {
                                                width: 10
                                                horizontalAlignment: Text.AlignHCenter

                                                text: "○"
                                                color: root.colFg

                                                font.pixelSize: 8
                                            }

                                            Column {
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 1

                                                Text {
                                                    width: 390

                                                    text: name
                                                    color: root.colFgBright

                                                    font.family: "JetBrainsMono Nerd Font"
                                                    font.pixelSize: 8

                                                    elide: Text.ElideRight
                                                }

                                                Text {
                                                    text: mac
                                                    color: root.colFg

                                                    font.family: "JetBrainsMono Nerd Font"
                                                    font.pixelSize: 6
                                                }
                                            }
                                        }

                                        Rectangle {
                                            anchors.right: parent.right
                                            anchors.rightMargin: 10
                                            anchors.verticalCenter: parent.verticalCenter

                                            width: 52
                                            height: 20

                                            color:
                                                nearbyButtonHover.hovered
                                                ? root.colSelBg
                                                : root.colNavy

                                            Text {
                                                anchors.centerIn: parent

                                                text: "PAIR"
                                                color: root.colAccent

                                                font.family: "JetBrainsMono Nerd Font"
                                                font.pixelSize: 7
                                                font.bold: true
                                            }

                                            HoverHandler { id: nearbyButtonHover }

                                            TapHandler {
                                                onTapped: root.pairBtDevice(mac)
                                            }
                                        }

                                        HoverHandler { id: nearbyHover }
                                    }
                                }

                                Rectangle {
                                    visible: btNearbyModel.count === 0

                                    width: parent.width
                                    height: 28

                                    color: root.colBg

                                    Text {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter

                                        text:
                                            root.bluetoothScanning
                                            ? "Scanning for devices..."
                                            : "Press SCAN to find devices"

                                        color: root.colFg

                                        font.family: "JetBrainsMono Nerd Font"
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

    Component.onCompleted: wifiSavedProc.running = true

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
