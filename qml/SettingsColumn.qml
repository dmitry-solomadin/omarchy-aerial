import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "."

Item {
    id: column

    readonly property var s: AerialStore.strings

    component Divider: Rectangle {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(10)
        Layout.bottomMargin: Style.space(4)
        implicitHeight: 1
        color: Tone.divider
    }

    component SwitchRow: RowLayout {
        id: row
        property string text: ""
        property string switchName: ""
        property bool checked: false
        signal toggled()
        Layout.fillWidth: true
        Label {
            Layout.fillWidth: true
            text: row.text
        }
        Ui.ToggleSwitch {
            objectName: row.switchName
            function activate() { toggled() }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            cursorPad: Style.space(4)
            checked: row.checked
            Accessible.role: Accessible.CheckBox
            Accessible.name: row.text
            Accessible.checkable: true
            Accessible.checked: checked
            Accessible.onToggleAction: toggled()
            onToggled: row.toggled()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(20)
        spacing: Style.space(8)

        // Short screens scroll the settings, so the library and the buttons below
        // stay in view at any window height.
        Controls.ScrollView {
            id: settingsScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            contentHeight: settings.implicitHeight
            clip: true
            FastWheel { flickable: settingsScroll.contentItem }

            ColumnLayout {
                id: settings
                width: settingsScroll.availableWidth
                spacing: Style.space(8)

                Label {
                    Layout.fillWidth: true
                    text: "Aerial"
                    font.pixelSize: Style.font.heading * 1.5
                    font.bold: true
                }
                Divider {}

                SectionHeading { text: column.s.t("settings.whatPlays") }
                SegmentedControl {
                    objectName: "modeChoice"
                    objectNamePrefix: "mode_"
                    Layout.fillWidth: true
                    activeFocusOnTab: false
                    options: [
                        {value: "cycle", label: column.s.t("mode.cycle")},
                        {value: "one", label: column.s.t("mode.one")}
                    ]
                    value: AerialStore.mode
                    onActivated: value => { if (value === "one") AerialStore.keepSomething(); else AerialStore.cycle() }
                }

                Ui.Dropdown {
                    objectName: "cycleCategory"
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    Layout.fillWidth: true
                    visible: AerialStore.mode === "cycle"
                    showLabel: false
                    options: [
                        {value: "all", label: column.s.t("category.all")},
                        {value: "Landscapes", label: column.s.t("category.landscapes")},
                        {value: "Cities", label: column.s.t("category.cities")},
                        {value: "Underwater", label: column.s.t("category.underwater")},
                        {value: "Space", label: column.s.t("category.space")}
                    ]
                    value: AerialStore.cycleCategory || "all"
                    onChanged: value => AerialStore.setCycleCategory(value === "all" ? "" : value)
                }
                Label {
                    objectName: "rotationCount"
                    Layout.fillWidth: true
                    visible: AerialStore.mode === "cycle"
                    text: column.s.tn("settings.inRotation", AerialStore.cycleCount).arg(Commons.I18n.formatNumber(AerialStore.cycleCount))
                    color: Tone.muted
                    font.pixelSize: Style.font.bodySmall
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    visible: AerialStore.mode === "one"
                    spacing: Style.space(6)
                    ClipImage {
                        Layout.fillWidth: true
                        Layout.preferredHeight: width * 9 / 16
                        source: AerialStore.thumbnail(AerialStore.keptClip)
                    }
                    Label {
                        objectName: "keptLabel"
                        Layout.fillWidth: true
                        text: AerialStore.keptEntry ? AerialStore.keptEntry.label : ""
                    }
                    Label {
                        Layout.fillWidth: true
                        visible: !AerialStore.keptReady
                        text: column.s.t("settings.keptDownloading")
                        color: Tone.muted
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.Wrap
                        elide: Text.ElideNone
                    }
                }

                Divider {}

                SectionHeading { text: column.s.t("settings.onScreen") }
                SwitchRow {
                    text: column.s.t("settings.clock")
                    switchName: "clockToggle"
                    checked: AerialStore.clockOn
                    onToggled: AerialStore.setClockOn(!AerialStore.clockOn)
                }
                SwitchRow {
                    text: column.s.t("settings.captions")
                    switchName: "captionsToggle"
                    checked: AerialStore.captions
                    onToggled: AerialStore.setCaptions(!AerialStore.captions)
                }

                // Only with a lock screen and design that can actually play it.
                ColumnLayout {
                    objectName: "lockSection"
                    Layout.fillWidth: true
                    visible: AerialStore.lockAvailable
                    spacing: Style.space(8)

                    Divider {}
                    SectionHeading { text: column.s.t("settings.lockScreen") }
                    SwitchRow {
                        text: column.s.t("settings.lockVideo")
                        switchName: "lockVideoToggle"
                        checked: AerialStore.lockVideoOn
                        onToggled: AerialStore.setLockVideo(!AerialStore.lockVideoOn)
                    }
                }
            }
        }

        Label {
            objectName: "libraryUsage"
            Layout.fillWidth: true
            text: column.s.tn("library.clips", AerialStore.downloadedCount)
                .arg(Commons.I18n.formatNumber(AerialStore.downloadedCount))
                .arg(AerialStore.formatBytes(AerialStore.usedBytes))
        }
        Label {
            Layout.fillWidth: true
            text: column.s.t("library.free").arg(AerialStore.formatBytes(AerialStore.freeBytes))
            color: Tone.muted
            font.pixelSize: Style.font.bodySmall
        }
        Label {
            objectName: "downloadCount"
            Layout.fillWidth: true
            visible: AerialStore.activeDownloads > 0
            text: column.s.tn("library.downloading", AerialStore.activeDownloads).arg(Commons.I18n.formatNumber(AerialStore.activeDownloads))
            color: Commons.Color.accent
            font.pixelSize: Style.font.bodySmall
        }
        ActionButton {
            objectName: "startScreensaver"
            Layout.fillWidth: true
            Layout.topMargin: Style.space(6)
            focusPolicy: Qt.NoFocus
            accented: true
            text: column.s.t("action.start")
            onClicked: AerialStore.start()
        }
    }
}
