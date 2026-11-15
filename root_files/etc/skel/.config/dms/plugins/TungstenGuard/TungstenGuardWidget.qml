// Tungsten Guard: a shield in the bar for updates (TungstenOS, Flatpaks, firmware and the
// Secure Boot dbx), for programs the system refused to run, and for new desktop defaults
// (/etc/skel) an update brought, which it shows for approval.
// Reads what root services write to /run/tungsten-guard (tungsten-guard-check.timer,
// tungsten-guard-execwatch.service); it runs nothing privileged itself.
import QtQuick
import QtQuick.Controls
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
    property var usb: null            // /run/tungsten-guard/usb.json (usb-lock)
    property bool usbAutolock: false  // ~/.config/tungsten/usb-autolock exists
    readonly property string autolockFile: Quickshell.env("HOME") + "/.config/tungsten/usb-autolock"

    function setUsbLocked(locked) {
        Quickshell.execDetached(["systemctl", locked ? "start" : "stop", "tungsten-usb-lock.service"]);
    }

    function setUsbAutolock(on) {
        Quickshell.execDetached(["sh", "-c", on ? 'mkdir -p "$(dirname "$1")" && : > "$1"' : 'rm -f "$1"', "sh", autolockFile]);
        usbAutolock = on;
    }

    // Desktop defaults an update changed (/usr/lib/tungsten/skel-sync, run as the user).
    readonly property string skelSync: "/usr/lib/tungsten/skel-sync"
    property var skelChanges: []      // [{path, kind, added, removed}]
    property string skelOpen: ""      // the file whose diff is shown
    property string skelDiff: ""
    property bool skelDiffLoading: false

    function refreshSkel() {
        if (!skelStatusProc.running)
            skelStatusProc.running = true;
    }

    function skelAction(verb, path) {
        skelActionProc.command = [skelSync, verb, path];
        skelActionProc.running = true;
    }

    function toggleSkelDiff(path) {
        if (skelOpen === path) {
            skelOpen = "";
            return;
        }
        skelOpen = path;
        skelDiff = "";
        skelDiffLoading = true;
        skelDiffProc.command = [skelSync, "diff", path];
        skelDiffProc.running = true;
    }

    function skelKindText(kind) {
        return {
            "add": "New file",
            "update": "Updated default (you had not changed it)",
            "merge": "Updated default, merged with your changes",
            "replace": "Replaces your version (yours is backed up)",
            "differs": "Differs from the default (yours is backed up)"
        }[kind] ?? kind;
    }

    // A unified diff as rich text: additions and removals in the theme's colors.
    function diffHtml(text) {
        const esc = t => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/ /g, "&nbsp;");
        return text.split("\n").filter(l => l.length > 0).map(l => {
            const c = l.startsWith("+") ? Theme.success : l.startsWith("-") ? Theme.error
                    : l.startsWith("@@") ? Theme.primary : Theme.onSurfaceVariant;
            return "<span style='color:" + c + "'>" + esc(l) + "</span>";
        }).join("<br>");
    }

    readonly property string osAvailable: status?.os?.available ?? ""
    // Installing a TungstenOS update (updatectl update), with sysupdated's job progress.
    property bool osInstalling: false
    property int osProgress: 0
    property string osInstalled: ""   // the version installed, active after a reboot
    property string osInstallError: ""

    function installOs() {
        if (osInstalling)
            return;
        osInstalling = true;
        osProgress = 0;
        osInstallError = "";
        osInstallProc.running = true;
    }
    readonly property int flatpakCount: status?.flatpaks ?? 0
    readonly property var firmware: status?.firmware ?? []
    // Warnings the user dismissed, by key; a key includes the state it was about, so a
    // different problem (a new dbx version, another Secure Boot state) warns again.
    property var dismissed: []
    // Events at or before this time are cleared from the history.
    property real clearedTime: 0
    readonly property var dbxEntry: firmware.find(f => f.dbx) ?? null
    readonly property string dbxKey: dbxEntry ? "dbx:" + dbxEntry.new : ""
    readonly property bool dbxUpdate: dbxEntry !== null && !isDismissed(dbxKey)
    readonly property int updateCount: (osAvailable ? 1 : 0) + (flatpakCount > 0 ? 1 : 0) + firmware.length
                                       + (skelChanges.length > 0 ? 1 : 0)
    readonly property var hw: status?.hardware ?? null
    readonly property bool secureBootOn: (hw?.secure_boot ?? "").startsWith("enabled")
    readonly property bool imageVerified: (hw?.verity ?? false) && (hw?.selinux ?? "") === "Enforcing"
    readonly property string sbKey: "secureboot:" + (hw?.secure_boot ?? "")
    readonly property string diskKey: "disk:weak"
    readonly property string verifyKey: "verify:" + (hw?.verity ?? "") + ":" + (hw?.ipe ?? "") + ":" + (hw?.selinux ?? "")
    readonly property bool sbWarn: hw !== null && !secureBootOn && !isDismissed(sbKey)
    readonly property bool diskWarn: hw !== null && hw.disk === "weak" && !isDismissed(diskKey)
    readonly property bool verifyWarn: hw !== null && !imageVerified && !isDismissed(verifyKey)
    // TungstenOS Secure Boot database updates held back (they would revoke something on the ESP).
    readonly property var sbdb: hw?.secureboot_updates ?? null
    readonly property var sbdbPending: sbdb?.pending ?? []
    readonly property string sbdbKey: "sbdb:" + sbdbPending.map(p => p.name).join(",")
    readonly property bool sbdbWarn: sbdbPending.length > 0 && !isDismissed(sbdbKey)
    // Problems that weaken the system itself (not just pending updates), unless dismissed.
    readonly property bool hwProblem: sbWarn || diskWarn || verifyWarn || sbdbWarn
    readonly property var history: blocked.filter(e => e.time > clearedTime)
    // Blocked programs within the last day keep the shield on alert, until cleared.
    readonly property bool recentBlock: history.length > 0 && (Date.now() / 1000 - history[0].time) < 86400

    function isDismissed(key) {
        return dismissed.indexOf(key) >= 0;
    }

    function dismiss(key) {
        if (isDismissed(key))
            return;
        dismissed = dismissed.concat([key]);
        saveState("dismissed", dismissed);
    }

    function restore(key) {
        dismissed = dismissed.filter(k => k !== key);
        saveState("dismissed", dismissed);
    }

    function clearHistory() {
        if (blocked.length === 0)
            return;
        clearedTime = blocked[0].time;
        saveState("clearedTime", clearedTime);
    }

    onPluginServiceChanged: {
        if (pluginService) {
            dismissed = loadState("dismissed", []) || [];
            clearedTime = loadState("clearedTime", 0) || 0;
        }
    }

    function stateIcon() {
        if (dbxUpdate || recentBlock || hwProblem)
            return "gpp_maybe";
        if (updateCount > 0)
            return "security_update_good";
        return "verified_user";
    }

    function stateColor() {
        if (dbxUpdate || recentBlock || hwProblem)
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
        root.refreshSkel();
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

    FileView {
        path: root.dir + "/usb.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                root.usb = JSON.parse(text());
            } catch (e) {}
        }
    }

    FileView {
        path: root.autolockFile
        printErrors: false
        onLoaded: root.usbAutolock = true
        onLoadFailed: root.usbAutolock = false
    }

    Process {
        id: skelStatusProc
        command: [root.skelSync, "status"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.skelChanges = JSON.parse(text);
                } catch (e) {
                    root.skelChanges = [];
                }
                // Tell once per set of changes.
                const key = root.skelChanges.map(c => c.path).join(",");
                if (key && key !== root.loadState("notifiedSkel", "")) {
                    root.saveState("notifiedSkel", key);
                    root.notify("New desktop defaults", root.skelChanges.length
                                + (root.skelChanges.length === 1 ? " file" : " files")
                                + " changed by a TungstenOS update. Review them in Tungsten Guard.");
                }
            }
        }
    }

    Process {
        id: osInstallProc
        command: ["updatectl", "update"]
        stderr: StdioCollector {
            id: osInstallErr
        }
        onExited: exitCode => {
            root.osInstalling = false;
            if (exitCode === 0) {
                root.osInstalled = root.osAvailable;
                root.notify("TungstenOS " + root.osInstalled + " installed", "Restart to use it.");
            } else {
                const lines = (osInstallErr.text || "").trim().split("\n");
                root.osInstallError = lines[lines.length - 1] || ("updatectl exited with " + exitCode);
                root.notify("TungstenOS update failed", root.osInstallError, "critical");
            }
        }
    }

    // sysupdated's jobs: (id, type, progress in percent, object path).
    Process {
        id: osJobsProc
        command: ["busctl", "--system", "--json=short", "call", "org.freedesktop.sysupdate1",
                  "/org/freedesktop/sysupdate1", "org.freedesktop.sysupdate1.Manager", "ListJobs"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const jobs = JSON.parse(text).data[0];
                    const job = jobs.find(j => j[1] === "update") ?? jobs[0];
                    if (job)
                        root.osProgress = job[2];
                } catch (e) {}
            }
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.osInstalling
        onTriggered: if (!osJobsProc.running) osJobsProc.running = true
    }

    Process {
        id: skelDiffProc
        stdout: StdioCollector {
            onStreamFinished: {
                root.skelDiff = text;
                root.skelDiffLoading = false;
            }
        }
    }

    Process {
        id: skelActionProc
        onExited: {
            root.skelOpen = "";
            root.refreshSkel();
        }
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

    popoutWidth: 440

    readonly property string headline: {
        if (!status)
            return "Waiting for the first check";
        if (hwProblem || dbxUpdate || recentBlock)
            return "Needs attention";
        if (updateCount > 0)
            return updateCount === 1 ? "1 update" : updateCount + " updates";
        return "Protected";
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: ""
            property int tab: 0

            // One item of a grouped list: tonal card, large radii only at the group's ends.
            component Tile: DCard {
                id: tile
                property string icon
                property string title
                property string detail
                property color tint: Theme.onSurface
                property bool first: false
                property bool last: false
                // A warning the user can dismiss (warnKey) or restore once dismissed.
                property string warnKey: ""
                property bool warning: false
                readonly property bool dismissedWarning: warnKey !== "" && root.isDismissed(warnKey)
                default property alias actions: actionSlot.data
                readonly property real startR: first ? Theme.cornerRadiusL : Theme.groupedListInnerRadius
                readonly property real endR: last ? Theme.cornerRadiusL : Theme.groupedListInnerRadius

                width: parent ? parent.width : 0
                height: Math.max(tileRow.implicitHeight, Theme.iconSize) + pad * 2
                restRadius: Theme.groupedListInnerRadius
                topLeftRadius: startR
                topRightRadius: startR
                bottomLeftRadius: endR
                bottomRightRadius: endR

                Row {
                    id: tileRow
                    width: parent.width
                    spacing: Theme.spacingM

                    DIcon {
                        name: tile.icon
                        size: Theme.iconSize
                        color: tile.dismissedWarning ? Theme.onSurfaceVariant : tile.tint
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        width: parent.width - Theme.iconSize - Theme.spacingM
                               - (actionSlot.width > 0 ? actionSlot.width + Theme.spacingM : 0)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        StyledText {
                            width: parent.width
                            text: tile.title
                            color: Theme.onSurface
                            font.pixelSize: Theme.fontSizeMedium
                            wrapMode: Text.WordWrap
                        }

                        StyledText {
                            width: parent.width
                            visible: text !== ""
                            text: tile.detail + (tile.dismissedWarning ? (tile.detail ? " · " : "") + "warning dismissed" : "")
                            color: Theme.onSurfaceVariant
                            font.pixelSize: Theme.fontSizeSmall
                            wrapMode: Text.WordWrap
                        }
                    }

                    Row {
                        id: actionSlot
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingXS

                        DIconButton {
                            visible: tile.warnKey !== "" && (tile.warning || tile.dismissedWarning)
                            iconName: tile.dismissedWarning ? "undo" : "close"
                            tooltipText: tile.dismissedWarning ? "Warn about this again" : "Dismiss this warning"
                            onClicked: tile.dismissedWarning ? root.restore(tile.warnKey) : root.dismiss(tile.warnKey)
                        }
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingM

                // --- Hero: overall state ---
                DCard {
                    width: parent.width
                    height: heroRow.implicitHeight + pad * 2
                    restRadius: Theme.cornerRadiusL

                    Row {
                        id: heroRow
                        width: parent.width
                        spacing: Theme.spacingL

                        DIcon {
                            name: root.stateIcon()
                            size: Theme.iconSize * 2.2
                            color: (root.hwProblem || root.dbxUpdate || root.recentBlock) ? Theme.warning : Theme.primary
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - Theme.iconSize * 2.2 - Theme.spacingL

                            StyledText {
                                width: parent.width
                                text: root.headline
                                color: Theme.onSurface
                                font.pixelSize: Theme.fontSizeXLarge
                                font.weight: Font.Medium
                                wrapMode: Text.WordWrap
                            }

                            StyledText {
                                width: parent.width
                                text: root.status ? "Tungsten Guard · checked "
                                      + new Date(root.status.checked).toLocaleTimeString(Qt.locale(), Locale.ShortFormat)
                                    : "Tungsten Guard"
                                color: Theme.onSurfaceVariant
                                font.pixelSize: Theme.fontSizeSmall
                            }
                        }
                    }
                }

                DTabBar {
                    width: parent.width
                    currentIndex: popout.tab
                    model: [
                        { text: "Updates" + (root.updateCount > 0 ? " · " + root.updateCount : ""), icon: "system_update" },
                        { text: "Security", icon: root.hwProblem ? "gpp_maybe" : "shield" },
                        { text: "Activity" + (root.history.length > 0 ? " · " + root.history.length : ""), icon: "history" }
                    ]
                    onTabClicked: index => popout.tab = index
                }

                // The pages lie on top of each other and cross-fade, in an area of one height
                // for every tab: the tallest page, at most about four and a half rows, and a
                // longer page scrolls. A height that follows the tab flickers: the shell
                // animates its frame with a spring while the content jumps.
                Item {
                    id: pages
                    width: parent.width
                    readonly property real rowHeight: updatesPage.children.length > 0 && updatesPage.children[0].height > 0
                                                      ? updatesPage.children[0].height + updatesPage.spacing : 72
                    height: Math.min(Math.max(updatesPage.implicitHeight, securityPage.implicitHeight,
                                              activityPage.implicitHeight + clearRow.height + Theme.spacingS),
                                     rowHeight * 4.5)

                    component Page: Flickable {
                        id: page
                        required property int index
                        anchors.fill: parent
                        contentWidth: width
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        opacity: popout.tab === index ? 1 : 0
                        visible: opacity > 0
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                        // The shell's own scrollbar (as in DFlickable): a thin pill, shown while
                        // scrolling or hovered.
                        ScrollBar.vertical: DScrollbar {
                            z: 2
                            targetFlickable: page
                        }
                    }

                // --- Updates ---
                Page {
                    index: 0
                    contentHeight: updatesPage.implicitHeight
                Column {
                    id: updatesPage
                    width: parent.width
                    spacing: 2

                    Tile {
                        first: true
                        icon: root.osAvailable ? "system_update" : "check_circle"
                        tint: root.osAvailable ? Theme.primary : Theme.onSurfaceVariant
                        title: root.osInstalled ? "TungstenOS " + root.osInstalled + " installed"
                             : root.osAvailable ? "TungstenOS " + root.osAvailable : "TungstenOS is up to date"
                        detail: root.osInstalling ? "Downloading and installing… " + root.osProgress + " %"
                              : root.osInstalled ? "Restart to use it · running " + (root.status?.os?.current || "unknown")
                              : root.osInstallError ? "Update failed: " + root.osInstallError
                              : "Installed: " + (root.status?.os?.current || "unknown")
                                + (root.osAvailable ? " · active after a reboot" : "")

                        DButton {
                            visible: root.osAvailable !== "" && root.osInstalled === ""
                            enabled: !root.osInstalling
                            text: root.osInstalling ? "Installing " + root.osProgress + " %"
                                : root.osInstallError ? "Retry" : "Install"
                            iconName: root.osInstalling ? "downloading" : "download"
                            onClicked: root.installOs()
                        }

                        DButton {
                            visible: root.osInstalled !== ""
                            text: "Restart"
                            iconName: "restart_alt"
                            onClicked: Quickshell.execDetached(["systemctl", "reboot"])
                        }
                    }

                    Tile {
                        icon: root.flatpakCount > 0 ? "apps" : "check_circle"
                        tint: root.flatpakCount > 0 ? Theme.primary : Theme.onSurfaceVariant
                        title: root.flatpakCount > 0 ? root.flatpakCount + " Flatpak updates" : "Flatpak apps are up to date"
                        detail: root.flatpakCount > 0 ? "Installed automatically once a day" : ""
                    }

                    Tile {
                        last: root.firmware.length === 0
                        visible: root.firmware.length === 0
                        icon: "check_circle"
                        tint: Theme.onSurfaceVariant
                        title: "Firmware is up to date"
                    }

                    Repeater {
                        model: root.firmware
                        delegate: Tile {
                            required property var modelData
                            required property int index
                            last: index === root.firmware.length - 1
                            warnKey: modelData.dbx ? root.dbxKey : ""
                            warning: modelData.dbx === true
                            icon: modelData.dbx ? "gpp_maybe" : "memory"
                            tint: modelData.dbx ? Theme.warning : Theme.primary
                            title: modelData.dbx ? "Secure Boot revocations (dbx)" : modelData.name
                            detail: modelData.version + " → " + modelData.new + " · fwupdmgr update"
                        }
                    }

                    // Desktop defaults an update changed: each one shown before it is applied.
                    Item {
                        width: parent.width
                        height: Theme.spacingM
                        visible: root.skelChanges.length > 0
                    }

                    Tile {
                        first: true
                        visible: root.skelChanges.length > 0
                        icon: "tune"
                        tint: Theme.primary
                        title: "New desktop defaults"
                        detail: root.skelChanges.length + (root.skelChanges.length === 1 ? " file" : " files")
                                + " changed by a TungstenOS update · your edits are kept where they do not overlap"

                        DButton {
                            text: "Apply all"
                            iconName: "done_all"
                            onClicked: root.skelAction("apply", "--all")
                        }
                    }

                    Repeater {
                        model: root.skelChanges
                        delegate: Column {
                            id: skelItem
                            required property var modelData
                            required property int index
                            readonly property bool open: root.skelOpen === modelData.path
                            readonly property bool lastItem: index === root.skelChanges.length - 1
                            width: parent.width
                            spacing: 2

                            Tile {
                                last: skelItem.lastItem && !skelItem.open
                                icon: skelItem.modelData.kind === "add" ? "note_add" : "description"
                                tint: skelItem.modelData.kind === "replace" || skelItem.modelData.kind === "differs"
                                      ? Theme.warning : Theme.onSurfaceVariant
                                title: "~/" + skelItem.modelData.path
                                detail: root.skelKindText(skelItem.modelData.kind)
                                        + " · +" + skelItem.modelData.added + " −" + skelItem.modelData.removed

                                DIconButton {
                                    iconName: skelItem.open ? "visibility_off" : "visibility"
                                    tooltipText: skelItem.open ? "Hide the changes" : "Show the changes"
                                    onClicked: root.toggleSkelDiff(skelItem.modelData.path)
                                }
                                DIconButton {
                                    iconName: "check"
                                    tooltipText: "Apply"
                                    onClicked: root.skelAction("apply", skelItem.modelData.path)
                                }
                                DIconButton {
                                    iconName: "close"
                                    tooltipText: "Keep mine (asks again after the next change)"
                                    onClicked: root.skelAction("skip", skelItem.modelData.path)
                                }
                            }

                            DCard {
                                visible: skelItem.open
                                width: parent.width
                                height: diffText.implicitHeight + pad * 2
                                restRadius: Theme.groupedListInnerRadius
                                topLeftRadius: Theme.groupedListInnerRadius
                                topRightRadius: Theme.groupedListInnerRadius
                                bottomLeftRadius: skelItem.lastItem ? Theme.cornerRadiusL : Theme.groupedListInnerRadius
                                bottomRightRadius: skelItem.lastItem ? Theme.cornerRadiusL : Theme.groupedListInnerRadius

                                StyledText {
                                    id: diffText
                                    width: parent.width
                                    textFormat: Text.RichText
                                    wrapMode: Text.WrapAnywhere
                                    font.family: Theme.monoFontFamily
                                    font.pixelSize: Theme.fontSizeSmall
                                    text: root.skelDiffLoading ? "Loading…"
                                          : root.skelDiff ? root.diffHtml(root.skelDiff)
                                          : "No line changes (only permissions, or skel-sync could not read the file)"
                                }
                            }
                        }
                    }
                }
                }

                // --- Security ---
                Page {
                    index: 1
                    contentHeight: securityPage.implicitHeight
                Column {
                    id: securityPage
                    width: parent.width
                    spacing: 2

                    Tile {
                        first: true
                        visible: root.hw === null
                        last: true
                        icon: "hourglass_empty"
                        tint: Theme.onSurfaceVariant
                        title: "Not checked yet"
                    }

                    Tile {
                        first: true
                        visible: root.hw !== null
                        warnKey: root.secureBootOn ? "" : root.sbKey
                        warning: !root.secureBootOn
                        icon: root.secureBootOn ? "verified" : "gpp_bad"
                        tint: root.secureBootOn ? Theme.primary : Theme.warning
                        title: root.secureBootOn ? "Secure Boot is on" : "Secure Boot is off"
                        detail: root.secureBootOn ? "Only boot software signed for this computer starts"
                                                  : (root.hw?.secure_boot || "unknown") + " · turn it on in the firmware setup"
                    }

                    Tile {
                        visible: root.hw !== null
                        readonly property string d: root.hw?.disk ?? "unknown"
                        warnKey: d === "weak" ? root.diskKey : ""
                        warning: d === "weak"
                        icon: d === "weak" ? "lock_open" : "lock"
                        tint: d === "weak" ? Theme.warning : Theme.primary
                        title: d === "tpm-pin" ? "Disk bound to the TPM, with PIN"
                             : d === "tpm" ? "Disk bound to the TPM"
                             : d === "passphrase" ? "Disk unlocks with the passphrase"
                             : d === "weak" ? "Disk unlocks with any TungstenOS boot"
                             : "Disk encryption unknown"
                        detail: d === "weak" ? "Bind it to this computer: run0 tungsten-tpm-enroll"
                              : d.startsWith("tpm") ? "Unlocks only if firmware, Secure Boot and boot loader are unchanged"
                              : d === "passphrase" ? "Bind it to the TPM: run0 tungsten-tpm-enroll" : ""
                    }

                    Tile {
                        visible: root.hw !== null && root.secureBootOn
                        readonly property int applied: root.sbdb?.applied ?? 0
                        readonly property var refused: root.sbdb?.refused ?? []
                        warnKey: root.sbdbPending.length > 0 ? root.sbdbKey : ""
                        warning: root.sbdbPending.length > 0
                        icon: root.sbdbPending.length > 0 ? "gpp_maybe" : "policy"
                        tint: root.sbdbPending.length > 0 ? Theme.warning : Theme.primary
                        title: root.sbdbPending.length > 0
                               ? root.sbdbPending.length + " Secure Boot update" + (root.sbdbPending.length > 1 ? "s" : "") + " held back"
                               : "Secure Boot database up to date"
                        detail: root.sbdbPending.length > 0
                                ? root.sbdbPending.map(p => p.name + ": " + p.reason).join("\n")
                                  + "\nApplies at a boot once the affected files are replaced"
                                : (applied > 0 ? applied + " TungstenOS revocation update" + (applied > 1 ? "s" : "") + " applied"
                                               : "No TungstenOS revocations needed so far")
                                  + (refused.length > 0 ? " · " + refused.length + " not for this machine's keys" : "")
                    }

                    Tile {
                        visible: root.usb !== null && (root.usb.external ?? 0) > 0
                        readonly property bool locked: root.usb?.locked ?? false
                        icon: locked ? "usb_off" : "usb"
                        tint: locked ? Theme.primary : Theme.onSurfaceVariant
                        title: locked ? "USB ports locked" : "USB ports open"
                        detail: (locked ? (root.usb.disabled + " of " + root.usb.external + " external ports off; plugged-in devices keep working")
                                        : "New devices are checked by USBGuard")
                                + " · auto-lock with the screen " + (root.usbAutolock ? "on" : "off")

                        DIconButton {
                            iconName: root.usbAutolock ? "screen_lock_portrait" : "lock_clock"
                            tooltipText: root.usbAutolock ? "Stop locking USB ports with the screen" : "Lock USB ports whenever the screen locks"
                            onClicked: root.setUsbAutolock(!root.usbAutolock)
                        }

                        DIconButton {
                            iconName: (root.usb?.locked ?? false) ? "lock_open" : "lock"
                            tooltipText: (root.usb?.locked ?? false) ? "Unlock the USB ports" : "Lock the empty external USB ports now"
                            onClicked: root.setUsbLocked(!(root.usb?.locked ?? false))
                        }
                    }

                    Tile {
                        visible: root.hw !== null
                        readonly property bool present: root.hw?.tpm !== null && root.hw?.tpm !== undefined
                        icon: "memory"
                        tint: present ? Theme.primary : Theme.onSurfaceVariant
                        title: present ? "TPM " + root.hw.tpm + ".0" : "No TPM"
                        detail: present ? (root.hw.tpm_lockout ? "PIN guessing is rate-limited; the lockout cannot be reset"
                                                               : "PIN lockout not set up (tungsten-tpm-enroll)") : ""
                    }

                    Tile {
                        visible: root.hw !== null
                        warnKey: root.imageVerified ? "" : root.verifyKey
                        warning: !root.imageVerified
                        icon: root.imageVerified ? "verified_user" : "gpp_bad"
                        tint: root.imageVerified ? Theme.primary : Theme.warning
                        title: root.imageVerified ? "Verified system" : "System verification incomplete"
                        detail: "dm-verity " + (root.hw?.verity ? "✓" : "✗")
                                + " · IPE " + (root.hw?.ipe ? "✓" : "✗")
                                + " · SELinux " + (root.hw?.selinux || "?")
                    }

                    Tile {
                        visible: root.hw !== null
                        last: true
                        icon: "developer_board"
                        tint: Theme.primary
                        // fwupd's level, e.g. "HSI:3!": "!" means runtime issues (fwupdmgr security).
                        readonly property string hsi: root.hw?.hsi ?? ""
                        title: "Platform security " + (hsi ? hsi.replace("!", "") : "unknown")
                        detail: ((root.hw?.hsi_failed ?? []).length > 0
                                 ? "Not met: " + root.hw.hsi_failed.join(", ")
                                 : (hsi ? "All firmware platform checks pass" : "fwupd not available"))
                                + (hsi.indexOf("!") >= 0 ? " · runtime issues (fwupdmgr security)" : "")
                    }
                }
                }

                // --- Activity ---
                Page {
                    index: 2
                    contentHeight: activityPage.y + activityPage.implicitHeight
                Row {
                    id: clearRow
                    anchors.right: parent.right
                    visible: root.history.length > 0
                    height: visible ? clearButton.implicitHeight : 0

                    DButton {
                        id: clearButton
                        text: "Clear history"
                        iconName: "delete_sweep"
                        onClicked: root.clearHistory()
                    }
                }

                Column {
                    id: activityPage
                    width: parent.width
                    y: clearRow.visible ? clearRow.height + Theme.spacingS : 0
                    spacing: 2

                    Tile {
                        first: true
                        last: true
                        visible: root.history.length === 0
                        icon: "check_circle"
                        tint: Theme.onSurfaceVariant
                        title: "Nothing blocked"
                        detail: "Programs run only from the system image and Flatpak apps"
                    }

                    Repeater {
                        model: root.history.slice(0, 8)
                        delegate: Tile {
                            required property var modelData
                            required property int index
                            first: index === 0
                            last: index === Math.min(root.history.length, 8) - 1
                            icon: "block"
                            tint: (Date.now() / 1000 - modelData.time) < 86400 ? Theme.warning : Theme.onSurfaceVariant
                            title: modelData.path.split("/").pop()
                            detail: new Date(modelData.time * 1000).toLocaleString(Qt.locale(), Locale.ShortFormat)
                                    + " · " + modelData.path + (modelData.by ? " · from " + modelData.by : "")
                        }
                    }
                }
                }
                }
            }
        }
    }
}
