import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    pluginId: "t3Usage"

    StyledText {
        width: parent.width
        text: "T3 Code Usage"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Shows the subscription limits T3 Code tracks (its Usage → Limits page) in the DankBar. Reads T3 Code's local server with a short-lived, read-only token from the t3 command; T3 Code must be running. Right-click the pill to open T3 Code."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    SelectionSetting {
        settingKey: "pillWindow"
        label: "Pill shows"
        description: "Which limit the bar pill shows for each provider."
        options: [
            { label: "Tightest limit", value: "tightest" },
            { label: "Session (5h)", value: "session" },
            { label: "Weekly", value: "weekly" }
        ]
        defaultValue: "tightest"
    }

    ToggleSetting {
        settingKey: "pillShowName"
        label: "Provider name in pill"
        description: "Show \"Claude 94%\" instead of just \"94%\"."
        defaultValue: true
    }

    StringSetting {
        settingKey: "pillRotateSeconds"
        label: "Pill rotation (seconds)"
        description: "How long each provider stays in the bar before cycling to the next. Set 0 to pin the provider below."
        placeholder: "10"
        defaultValue: "10"
    }

    StringSetting {
        settingKey: "pillProvider"
        label: "Pinned provider"
        description: "Only used when rotation is 0. Provider name or id, e.g. Claude or codex. Empty shows the first one."
        placeholder: "Claude"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "refreshSeconds"
        label: "Refresh interval (seconds)"
        description: "How often to ask T3 Code for its numbers. T3 refreshes them from the providers on its own schedule. Minimum 15."
        placeholder: "60"
        defaultValue: "60"
    }

    StringSetting {
        settingKey: "openCommand"
        label: "Open command"
        description: "Shell command run by \"Open T3 Code\" and right-click. Empty focuses the T3 Code window on niri, or launches it."
        placeholder: "gtk-launch t3code"
        defaultValue: ""
    }
}
