import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "."

Item {
    id: content
    objectName: "windowContent"
    signal closeRequested()

    readonly property var filterOptions: [
        {value: "all", label: AerialStore.strings.t("filter.all")},
        {value: "downloaded", label: AerialStore.strings.t("filter.downloaded")},
        {value: "Landscapes", label: AerialStore.strings.t("category.landscapes")},
        {value: "Cities", label: AerialStore.strings.t("category.cities")},
        {value: "Underwater", label: AerialStore.strings.t("category.underwater")},
        {value: "Space", label: AerialStore.strings.t("category.space")}
    ]

    Rectangle {
        anchors.fill: parent
        color: Commons.Color.background
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        SettingsColumn {
            Layout.fillHeight: true
            Layout.preferredWidth: Style.space(330)
        }

        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            color: Tone.divider
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            RowLayout {
                objectName: "messageBanner"
                visible: AerialStore.message !== ""
                Layout.fillWidth: true
                Layout.margins: Style.space(12)
                spacing: Style.space(10)
                Label {
                    Layout.fillWidth: true
                    objectName: "messageText"
                    text: AerialStore.message
                    color: AerialStore.messageIsError ? Commons.Color.urgent : Commons.Color.foreground
                    wrapMode: Text.Wrap
                    elide: Text.ElideNone
                }
                ActionButton {
                    objectName: "retryCatalog"
                    visible: AerialStore.clips.length === 0
                    text: AerialStore.strings.t("action.retry")
                    onClicked: { AerialStore.message = ""; AerialStore.refreshCatalog() }
                }
                ActionButton {
                    objectName: "dismissMessage"
                    text: AerialStore.strings.t("action.dismiss")
                    onClicked: AerialStore.message = ""
                }
            }

            Flow {
                id: filterTabs
                objectName: "filterTabs"
                Layout.fillWidth: true
                Layout.margins: Style.space(12)
                spacing: Style.space(4)
                Repeater {
                    model: content.filterOptions
                    ActionButton {
                        required property var modelData
                        objectName: "filter_" + modelData.value
                        focusPolicy: Qt.NoFocus
                        text: modelData.label
                        font.pixelSize: Style.font.bodySmall
                        selected: AerialStore.filter === modelData.value
                        onClicked: AerialStore.filter = modelData.value
                    }
                }
            }

            GridView {
                id: grid
                objectName: "clipGrid"
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                leftMargin: Style.space(10)
                rightMargin: Style.space(10)
                bottomMargin: Style.space(10)
                boundsBehavior: Flickable.StopAtBounds
                model: ScriptModel { values: AerialStore.visibleClips }
                // Cards fill the width, however many fit at about this size.
                readonly property int columns: Math.max(1, Math.floor((width - leftMargin - rightMargin) / Style.space(270)))
                cellWidth: Math.floor((width - leftMargin - rightMargin) / columns)
                cellHeight: Math.round((cellWidth - Style.space(12)) * 9 / 16) + Style.space(44)
                keyNavigationEnabled: false
                // Nothing is selected until a card is clicked.
                currentIndex: -1
                highlightFollowsCurrentItem: false
                Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
                FastWheel { flickable: grid }

                onCurrentItemChanged: if (currentItem) AerialStore.selected = currentItem.name
                // Keep the selection on the same clip as the list changes around it.
                function keepSelection() {
                    currentIndex = AerialStore.visibleClips.findIndex(clip => clip.name === AerialStore.selected)
                }
                Connections {
                    target: AerialStore
                    function onVisibleClipsChanged() { Qt.callLater(grid.keepSelection) }
                }

                delegate: ClipCard {
                    width: grid.cellWidth
                    height: grid.cellHeight
                    onSelectRequested: grid.currentIndex = index
                }

                Label {
                    objectName: "emptyState"
                    anchors.centerIn: parent
                    visible: grid.count === 0
                    color: Tone.muted
                    text: AerialStore.catalogLoading ? AerialStore.strings.t("empty.loading")
                        : AerialStore.clips.length === 0 ? AerialStore.strings.t("empty.noCatalog")
                        : AerialStore.strings.t("empty.noClips")
                }
            }
        }
    }
}
