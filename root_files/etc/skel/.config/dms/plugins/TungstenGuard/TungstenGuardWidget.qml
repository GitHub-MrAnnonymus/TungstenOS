// Tungsten Guard: a shield in the bar for updates (TungstenOS, Flatpaks, firmware and the
// Secure Boot dbx) and for programs the system refused to run.
// Reads what root services write to /run/tungsten-guard (tungsten-guard-check.timer,
// tungsten-guard-execwatch.service); it runs nothing privileged itself.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import qs.DCommon.Widgets

PluginComponent {
    id: root

    readonly property string dir: "/run/tungsten-guard"
    property string uid: ""
    property var status: null
    property var blocked: []          // newest first, at most 20

    readonly property string osAvailable: status?.os?.available ?? ""
    readonly property int flatpakCount: status?.flatpaks ?? 0
    readonly property var firmware: status?.firmware ?? []
    readonly property bool dbxUpdate: firmware.some(f => f.dbx)
    readonly property int updateCount: (osAvailable ? 1 : 0) + (flatpakCount > 0 ? 1 : 0) + firmware.length
    // Blocked programs within the last day keep the shield on alert.
    readonly property bool recentBlock: blocked.length > 0 && (Date.now() / 1000 - blocked[0].time) < 86400

    function stateIcon() {
        if (dbxUpdate || recentBlock)
            return "gpp_maybe";
        if (updateCount > 0)
            return "security_update_good";
        return "verified_user";
    }

    function stateColor() {
        if (dbxUpdate || recentBlock)
            return Theme.warning;
        if (updateCount > 0)
            return Theme.primary;
        return Theme.widgetTextColor;
    }

    function notify(summary, body, urgency) {
        Quickshell.execDetached(["notify-send", "--app-name=Tungsten Guard", "--icon=security-high",
                                 "--urgency=" + (urgency || "normal"), summary, body]);
    }

    function loadState(key, fallback) {
        const v = pluginService ? pluginService.loadPluginState("tungstenGuard", key) : null;
        return v === null || v === undefined ? fallback : v;
    }

    function saveState(key, value) {
        if (pluginService)
            pluginService.savePluginState("tungstenGuard", key, value);
    }

    function onStatus(text) {
        let s;
        try {
            s = JSON.parse(text);
        } catch (e) {
            return;
        }
        root.status = s;
        // Notify once per new TungstenOS version and once per dbx update.
        const os = s?.os?.available ?? "";
        if (os && os !== loadState("notifiedOs", "")) {
            saveState("notifiedOs", os);
            notify("TungstenOS update available", "Version " + os + " is ready to install.");
        }
        const dbx = (s?.firmware ?? []).find(f => f.dbx);
        const dbxKey = dbx ? (dbx.new || "dbx") : "";
        if (dbxKey && dbxKey !== loadState("notifiedDbx", "")) {
            saveState("notifiedDbx", dbxKey);
            notify("Security update: Secure Boot revocation list",
                   "A new UEFI dbx revokes compromised boot software. Install it with: fwupdmgr update", "critical");
        }
    }

    function onEvents(text) {
        const lines = text.split("\n").filter(l => l.trim().length > 0);
        const events = [];
        for (const l of lines) {
            try {
                events.push(JSON.parse(l));
            } catch (e) {}
        }
        events.sort((a, b) => b.time - a.time);
        root.blocked = events.slice(0, 20);
        // Notify for events newer than the last one shown.
        const seen = loadState("seenTime", 0);
        const fresh = events.filter(e => e.time > seen);
        if (fresh.length === 0)
            return;
        saveState("seenTime", fresh[0].time);
        if (seen === 0)
            return;           // first run: old events are history, not news
        const e = fresh[0];
        const more = fresh.length > 1 ? " (and " + (fresh.length - 1) + " more)" : "";
        notify("Blocked: " + e.path.split("/").pop(),
               e.path + " may not run here" + more + ". Programs run only from the system image and Flatpak apps.");
    }

    Process {
        command: ["id", "-u"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: root.uid = text.trim()
        }
    }

    FileView {
        path: root.dir + "/status.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.onStatus(text())
    }

    FileView {
        path: root.uid ? root.dir + "/exec-" + root.uid + ".jsonl" : ""
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.onEvents(text())
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter

            DIcon {
                name: root.stateIcon()
                size: Theme.barIconSize(root.barThickness, undefined, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                color: root.stateColor()
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: root.updateCount > 0
                text: root.updateCount
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                color: Theme.widgetTextColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            anchors.horizontalCenter: parent.horizontalCenter

            DIcon {
                name: root.stateIcon()
                size: Theme.barIconSize(root.barThickness, undefined, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                color: root.stateColor()
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutWidth: 420

    popoutContent: Component {
        PopoutComponent {
            headerText: "Tungsten Guard"
            detailsText: root.status ? "Checked " + new Date(root.status.checked).toLocaleString(Qt.locale(), Locale.ShortFormat) : "Waiting for the first check…"

            Column {
                width: parent.width
                spacing: Theme.spacingM

                component Line: Row {
                    property string icon
                    property string title
                    property string detail
                    property color tint: Theme.surfaceText
                    width: parent.width
                    spacing: Theme.spacingM

                    DIcon {
                        name: parent.icon
                        size: Theme.iconSize
                        color: parent.tint
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        width: parent.width - Theme.iconSize - Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter

                        StyledText {
                            text: parent.parent.title
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                        }

                        StyledText {
                            text: parent.parent.detail
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                            width: parent.width
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                Line {
                    icon: root.osAvailable ? "system_update" : "check_circle"
                    tint: root.osAvailable ? Theme.primary : Theme.surfaceText
                    title: root.osAvailable ? "TungstenOS " + root.osAvailable + " is available" : "TungstenOS is up to date"
                    detail: "Installed: " + (root.status?.os?.current || "unknown") + (root.osAvailable ? ". Installs into the inactive slot; active after a reboot." : "")
                }

                DButton {
                    visible: root.osAvailable !== ""
                    text: "Install update"
                    iconName: "download"
                    onClicked: Quickshell.execDetached(["updatectl", "update"])
                }

                Line {
                    icon: root.flatpakCount > 0 ? "apps" : "check_circle"
                    tint: root.flatpakCount > 0 ? Theme.primary : Theme.surfaceText
                    title: root.flatpakCount > 0 ? root.flatpakCount + " Flatpak updates" : "Flatpak apps are up to date"
                    detail: root.flatpakCount > 0 ? "Installed automatically by the daily Flatpak update." : ""
                }

                Line {
                    icon: root.dbxUpdate ? "gpp_maybe" : (root.firmware.length > 0 ? "memory" : "check_circle")
                    tint: root.dbxUpdate ? Theme.warning : (root.firmware.length > 0 ? Theme.primary : Theme.surfaceText)
                    title: root.firmware.length > 0 ? root.firmware.length + " firmware updates" : "Firmware is up to date"
                    detail: root.firmware.map(f => f.name + " " + f.version + " → " + f.new).join("\n")
                            + (root.firmware.length > 0 ? "\nInstall with: fwupdmgr update" : "")
                }

                Line {
                    icon: root.blocked.length > 0 ? "block" : "check_circle"
                    tint: root.recentBlock ? Theme.warning : Theme.surfaceText
                    title: root.blocked.length > 0 ? "Blocked programs" : "No blocked programs"
                    detail: root.blocked.slice(0, 5).map(e => new Date(e.time * 1000).toLocaleTimeString(Qt.locale(), Locale.ShortFormat)
                                                          + "  " + e.path + (e.by ? " (" + e.by + ")" : "")).join("\n")
                }
            }
        }
    }
}
