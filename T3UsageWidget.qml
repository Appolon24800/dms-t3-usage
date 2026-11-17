import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

/**
 * T3 Code Usage - DankBar pill + popout showing the subscription limits that
 * T3 Code itself tracks (Usage -> Limits in T3), read from its local server
 * by scripts/t3_usage.py. Percentages are shown as what is LEFT (100 - used).
 *
 * Left click: popout. Right click: bring T3 Code to the front.
 */
PluginComponent {
    id: root

    property var providers: []
    property var warnings: []
    property string t3State: "loading"     // loading | ok | closed | restart | refused | unsupported | error
    property string message: ""
    property string serverVersion: ""
    property bool isLoading: false
    property real lastSuccessMs: 0
    property real nowMs: Date.now()
    property int pillIndex: 0
    property real savedScrollY: 0

    popoutWidth: 380
    popoutHeight: 460

    pillRightClickAction: () => root.openT3()

    // ---------------------------------------------------------------- settings

    property int refreshSeconds: {
        const parsed = parseInt(pluginData.refreshSeconds === undefined ? "60" : pluginData.refreshSeconds);
        return Number.isFinite(parsed) ? Math.max(15, parsed) : 60;
    }
    property int pillRotateSeconds: {
        const parsed = parseInt(pluginData.pillRotateSeconds === undefined ? "10" : pluginData.pillRotateSeconds);
        return Number.isFinite(parsed) ? Math.max(0, parsed) : 10;
    }
    property string pillWindow: String(pluginData.pillWindow || "tightest")
    property string pillProvider: String(pluginData.pillProvider || "").trim()
    property bool pillShowName: pluginData.pillShowName === undefined ? true : !!pluginData.pillShowName
    property string openCommand: String(pluginData.openCommand || "").trim()

    function localPath(relative) {
        const url = Qt.resolvedUrl(relative).toString();
        return url.indexOf("file://") === 0 ? decodeURIComponent(url.substring("file://".length)) : url;
    }
    readonly property string usageScript: localPath("scripts/t3_usage.py")
    readonly property string openScript: localPath("scripts/open_t3.sh")

    // ------------------------------------------------------------------ data

    function refresh() {
        if (isLoading)
            return;
        isLoading = true;
        Proc.runCommand("t3Usage:usage", ["python3", "-I", usageScript], (output, exitCode) => {
            isLoading = false;
            nowMs = Date.now();
            let doc = null;
            try {
                doc = JSON.parse(String(output || "").trim());
            } catch (e) {
                t3State = "error";
                message = exitCode !== 0 ? ("t3_usage.py exited with code " + exitCode) : "Could not read t3_usage.py output";
                return;
            }
            serverVersion = String(doc.serverVersion || serverVersion);
            message = String(doc.message || "");
            t3State = String(doc.state || (doc.ok ? "ok" : "error"));
            if (!doc.ok) {
                // Keep the last good numbers through a transient failure, but
                // drop them once T3 Code is closed: they would only go stale.
                if (t3State === "closed")
                    providers = [];
                return;
            }
            lastSuccessMs = nowMs;
            const nextWarnings = doc.warnings || [];
            if (JSON.stringify(nextWarnings) !== JSON.stringify(warnings))
                warnings = nextWarnings;
            const next = doc.providers || [];
            // Skip identical documents: a fresh array resets the ListView and
            // jumps the scroll position back to the top.
            if (JSON.stringify(next) !== JSON.stringify(providers))
                providers = next;
        }, 0, 30000);
    }

    function openT3() {
        closePopout();
        if (openCommand.length > 0)
            Quickshell.execDetached(["sh", "-c", openCommand]);
        else
            Quickshell.execDetached(["sh", openScript]);
    }

    // --------------------------------------------------------------- helpers

    function remaining(w) {
        return Math.max(0, Math.min(100, Math.round(100 - (w ? w.usedPercent : 0))));
    }

    function levelColor(left) {
        if (left <= 10)
            return Theme.error;
        if (left <= 30)
            return Theme.warning;
        return Theme.success;
    }

    function tightest(p) {
        const ws = p.windows || [];
        let best = null;
        for (let i = 0; i < ws.length; i++) {
            if (best === null || ws[i].usedPercent > best.usedPercent)
                best = ws[i];
        }
        return best;
    }

    function pillWindowOf(p) {
        const ws = p.windows || [];
        if (ws.length === 0)
            return null;
        if (pillWindow === "session" || pillWindow === "weekly") {
            const match = ws.find(w => w.kind === pillWindow);
            if (match)
                return match;
        }
        return tightest(p);
    }

    readonly property var pillCandidates: providers.filter(p => (p.windows || []).length > 0)

    function pillProviderEntry() {
        const list = pillCandidates;
        if (list.length === 0)
            return null;
        if (pillRotateSeconds > 0)
            return list[pillIndex % list.length];
        if (pillProvider.length > 0) {
            const wanted = pillProvider.toLowerCase();
            const match = list.find(p => p.id.toLowerCase() === wanted || p.driver.toLowerCase() === wanted || p.name.toLowerCase() === wanted);
            if (match)
                return match;
        }
        return list[0];
    }

    function pillText() {
        const p = pillProviderEntry();
        if (!p) {
            if (t3State === "loading")
                return "...";
            return t3State === "ok" ? "T3 --" : "T3 !";
        }
        const w = pillWindowOf(p);
        const pct = remaining(w) + "%";
        return pillShowName ? (p.name + " " + pct) : pct;
    }

    function pillColor() {
        const p = pillProviderEntry();
        if (!p)
            return t3State === "ok" || t3State === "loading" || t3State === "closed" ? Theme.surfaceVariantText : Theme.error;
        return levelColor(remaining(pillWindowOf(p)));
    }

    function duration(ms) {
        const mins = Math.max(0, Math.round(ms / 60000));
        const d = Math.floor(mins / 1440);
        const h = Math.floor((mins % 1440) / 60);
        const m = mins % 60;
        if (d > 0)
            return d + "d " + h + "h";
        if (h > 0)
            return h + "h " + m + "m";
        return m + "m";
    }

    function resetText(w) {
        if (!w || !w.resetsAt)
            return "";
        const at = new Date(w.resetsAt);
        const left = at.getTime() - nowMs;
        if (!Number.isFinite(left))
            return "";
        if (left <= 0)
            return "Resetting now";
        const sameDay = at.toDateString() === new Date(nowMs).toDateString();
        // A pooled window carries its accounts' earliest reset.
        const lead = (w.accounts || []).length > 1 ? "Next reset in " : "Resets in ";
        return lead + duration(left) + " · " + Qt.formatDateTime(at, sameDay ? "HH:mm" : "ddd HH:mm");
    }

    function shortReset(a) {
        if (!a || !a.resetsAt)
            return "";
        const left = new Date(a.resetsAt).getTime() - nowMs;
        if (!Number.isFinite(left))
            return "";
        return left <= 0 ? " · now" : (" · " + duration(left));
    }

    function groupSubtitle(g) {
        if (!g)
            return "";
        if ((g.accountCount || 0) > 1) {
            const via = (g.sources || []).length === 1 ? (" · " + g.sources[0]) : "";
            return g.accountCount + " accounts" + via;
        }
        return g.plan || ((g.sources || []).length === 1 ? g.sources[0] : "");
    }

    function stateText() {
        switch (t3State) {
        case "ok":
            // Hub errors (unreachable hub, bad management key) from T3.
            return warnings.length > 0 ? warnings.join("\n") : "";
        case "loading":
            return "";
        case "closed":
            return "T3 Code isn't running. Open it to see your limits.";
        default:
            return message.length > 0 ? message : "Could not read usage from T3 Code.";
        }
    }

    function footerText() {
        if (lastSuccessMs <= 0)
            return isLoading ? "Loading…" : "";
        const ago = nowMs - lastSuccessMs;
        const when = ago < 60000 ? "just now" : (duration(ago) + " ago");
        const version = serverVersion.length > 0 ? (" · T3 " + serverVersion.replace(/-nightly.*/, " nightly")) : "";
        return "Updated " + when + version;
    }

    // ---------------------------------------------------------------- timers

    Timer {
        interval: root.refreshSeconds * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        // Keeps the "resets in" countdowns and "updated" footer current.
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.nowMs = Date.now()
    }

    Timer {
        interval: Math.max(1, root.pillRotateSeconds) * 1000
        running: root.pillRotateSeconds > 0 && root.pillCandidates.length > 1
        repeat: true
        onTriggered: root.pillIndex = (root.pillIndex + 1) % Math.max(1, root.pillCandidates.length)
    }

    // ------------------------------------------------------------------ pill

    horizontalBarPill: Component {
        RowLayout {
            spacing: Theme.spacingS / 2

            DankIcon {
                name: "data_usage"
                color: root.pillProviderEntry() ? Theme.primary : Theme.surfaceVariantText
                size: root.iconSize
                Layout.alignment: Qt.AlignVCenter
            }

            StyledText {
                text: root.pillText()
                color: root.pillColor()
                font.pixelSize: Theme.fontSizeSmall
                Layout.alignment: Qt.AlignVCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            DankIcon {
                name: "data_usage"
                color: root.pillProviderEntry() ? Theme.primary : Theme.surfaceVariantText
                size: root.iconSize
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: {
                    const p = root.pillProviderEntry();
                    return p ? (root.remaining(root.pillWindowOf(p)) + "%") : (root.t3State === "ok" || root.t3State === "loading" ? "--" : "!");
                }
                color: root.pillColor()
                font.pixelSize: Theme.fontSizeSmall
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // ---------------------------------------------------------------- popout

    popoutContent: Component {
        PopoutComponent {
            id: popoutRoot

            headerText: "T3 Code usage"
            detailsText: ""
            showCloseButton: false

            headerActions: Component {
                Row {
                    spacing: Theme.spacingXS

                    DankActionButton {
                        iconName: "refresh"
                        iconColor: Theme.surfaceVariantText
                        tooltipText: "Refresh now"
                        onClicked: root.refresh()
                    }

                    DankActionButton {
                        iconName: "open_in_new"
                        iconColor: Theme.surfaceVariantText
                        tooltipText: "Open T3 Code"
                        onClicked: root.openT3()
                    }
                }
            }

            Item {
                width: parent.width
                implicitHeight: root.popoutHeight - popoutRoot.headerHeight - popoutRoot.detailsHeight - Theme.spacingXL

                StyledText {
                    id: stateLine
                    visible: text.length > 0
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    text: root.stateText()
                    color: root.t3State === "closed" ? Theme.surfaceVariantText : Theme.error
                    font.pixelSize: Theme.fontSizeSmall
                    wrapMode: Text.WordWrap
                }

                ListView {
                    id: providerList
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    anchors.top: stateLine.visible ? stateLine.bottom : parent.top
                    anchors.topMargin: Theme.spacingS
                    anchors.bottom: footer.top
                    anchors.bottomMargin: Theme.spacingS
                    clip: true
                    spacing: Theme.spacingM
                    model: root.providers

                    onContentYChanged: root.savedScrollY = contentY
                    onModelChanged: Qt.callLater(() => {
                        const maxY = Math.max(0, providerList.contentHeight - providerList.height);
                        providerList.contentY = Math.min(root.savedScrollY, maxY);
                    })

                    delegate: Column {
                        id: providerBlock

                        width: providerList.width
                        spacing: Theme.spacingXS

                        required property var modelData
                        required property int index

                        RowLayout {
                            width: parent.width
                            spacing: Theme.spacingS

                            StyledText {
                                text: providerBlock.modelData.name
                                font.pixelSize: Theme.fontSizeLarge
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }

                            StyledText {
                                visible: text.length > 0
                                text: root.groupSubtitle(providerBlock.modelData)
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                                Layout.alignment: Qt.AlignVCenter
                            }
                        }

                        StyledText {
                            visible: (providerBlock.modelData.windows || []).length === 0
                            width: parent.width
                            text: providerBlock.modelData.unavailableMessage || "T3 Code could not read this provider's limits right now."
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                            wrapMode: Text.WordWrap
                        }

                        Repeater {
                            model: providerBlock.modelData.windows || []

                            Column {
                                id: windowCol

                                required property var modelData

                                readonly property int leftPct: root.remaining(modelData)
                                readonly property color tone: root.levelColor(leftPct)

                                width: providerBlock.width
                                spacing: 3

                                RowLayout {
                                    width: parent.width

                                    StyledText {
                                        text: windowCol.modelData.label
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeSmall
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                    }

                                    StyledText {
                                        text: windowCol.leftPct + "% left"
                                        color: windowCol.tone
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Bold
                                    }
                                }

                                Rectangle {
                                    width: parent.width
                                    height: 4
                                    radius: 2
                                    color: Theme.outline
                                    opacity: 0.4

                                    Rectangle {
                                        width: parent.width * windowCol.leftPct / 100
                                        height: parent.height
                                        radius: 2
                                        color: windowCol.tone
                                    }
                                }

                                StyledText {
                                    visible: text.length > 0
                                    width: parent.width
                                    text: root.resetText(windowCol.modelData)
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                    wrapMode: Text.WordWrap
                                }

                                // One chip per pooled account, like the avatars
                                // on T3's Limits page: badge, share left, reset.
                                Flow {
                                    visible: (windowCol.modelData.accounts || []).length > 0
                                    width: parent.width
                                    spacing: Theme.spacingS

                                    Repeater {
                                        model: windowCol.modelData.accounts || []

                                        Row {
                                            id: accountChip

                                            required property var modelData

                                            readonly property int leftPct: root.remaining(modelData)

                                            spacing: 4

                                            Rectangle {
                                                width: 16
                                                height: 16
                                                radius: 8
                                                color: Theme.primary
                                                opacity: 0.85
                                                anchors.verticalCenter: parent.verticalCenter

                                                StyledText {
                                                    anchors.centerIn: parent
                                                    text: String(accountChip.modelData.badge || "?").substring(0, 1)
                                                    color: Theme.onPrimary
                                                    font.pixelSize: 10
                                                    font.weight: Font.Bold
                                                }
                                            }

                                            StyledText {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: accountChip.leftPct + "%" + root.shortReset(accountChip.modelData)
                                                color: root.levelColor(accountChip.leftPct)
                                                font.pixelSize: Theme.fontSizeSmall
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            visible: providerBlock.index < root.providers.length - 1
                            width: parent.width
                            height: 1
                            color: Theme.outline
                            opacity: 0.3
                        }
                    }
                }

                StyledText {
                    visible: root.providers.length === 0 && root.t3State === "ok"
                    anchors.centerIn: providerList
                    width: providerList.width
                    horizontalAlignment: Text.AlignHCenter
                    text: "T3 Code reports no subscription limits for your providers."
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    wrapMode: Text.WordWrap
                }

                RowLayout {
                    id: footer
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    spacing: Theme.spacingS

                    StyledText {
                        text: root.footerText()
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                    }

                    DankButton {
                        text: "Open T3 Code"
                        iconName: "open_in_new"
                        onClicked: root.openT3()
                    }
                }
            }
        }
    }
}
