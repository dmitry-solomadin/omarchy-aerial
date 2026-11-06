import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import "."

Item {
    id: card
    required property var modelData
    required property int index
    signal selectRequested()

    readonly property string name: modelData.name
    objectName: "clip_" + name
    function activate() { selectRequested() }

    readonly property var s: AerialStore.strings
    readonly property bool downloaded: AerialStore.isDownloaded(name)
    readonly property var transfer: AerialStore.transfer(name)
    readonly property bool queued: !!transfer && transfer.state === "queued"
    readonly property bool downloading: !!transfer && transfer.state === "downloading"
    readonly property real progress: transfer ? transfer.progress : 0
    readonly property bool kept: AerialStore.mode === "one" && AerialStore.keptClip === name
    readonly property bool current: GridView.isCurrentItem
    // Whether a button is hovered counts on its own account, because the pointer
    // moving onto a button must never hide the buttons: that would put the pointer
    // back on the card, show them again, and flicker. For the same reason the row
    // only ever fades, and never leaves the layout under the pointer.
    readonly property bool revealed: hover.hovered || current || transfer !== null
        || downloadButton.hovered || cancelButton.hovered || previewButton.hovered || keepButton.hovered || deleteButton.hovered

    // Readable over any picture, in the theme's own colors.
    component OverlayButton: ActionButton {
        backdrop: true
        focusPolicy: Qt.NoFocus
        font.pixelSize: Style.font.bodySmall
    }

    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler {
        onTapped: card.selectRequested()
        onDoubleTapped: {
            if (card.downloaded) AerialStore.keep(card.name)
            else AerialStore.download(card.name)
        }
    }

    Item {
        id: frame
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(6)
        height: width * 9 / 16

        // Clips that aren't here yet are dimmer, so what's on disk stands out.
        ClipImage {
            anchors.fill: parent
            source: AerialStore.thumbnail(card.name)
            imageOpacity: card.downloaded ? 1 : .45
        }
        Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: "transparent"
            border.width: card.current || card.kept ? 2 : 0
            border.color: Commons.Color.accent
        }

        Rectangle {
            visible: card.kept
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: Style.space(8)
            width: keptText.implicitWidth + Style.space(14)
            height: keptText.implicitHeight + Style.space(6)
            radius: Style.cornerRadius
            color: Commons.Color.accent
            Label {
                id: keptText
                anchors.centerIn: parent
                text: card.s.t("clip.kept")
                color: Commons.Color.background
                font.pixelSize: Style.font.bodySmall
                font.bold: true
            }
        }
        Rectangle {
            visible: card.downloaded
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(8)
            width: Style.space(22)
            height: width
            radius: Style.cornerRadius > 0 ? width / 2 : 0
            color: Util.alpha(Commons.Color.background, .75)
            Label {
                anchors.centerIn: parent
                text: "✓"
                font.pixelSize: Style.font.bodySmall
            }
        }

        Label {
            objectName: "progress_" + card.name
            visible: card.transfer !== null
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -Style.space(14)
            text: card.queued ? card.s.t("clip.waiting")
                : card.s.t("clip.percent").arg(Commons.I18n.formatNumber(Math.round(card.progress * 100)))
            font.pixelSize: card.queued ? Style.font.body : Style.font.heading * 1.25
            style: Text.Outline
            styleColor: Util.alpha(Commons.Color.background, .6)
        }

        Row {
            objectName: "actions_" + card.name
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(10)
            spacing: Style.space(4)
            opacity: card.revealed ? 1 : 0

            OverlayButton {
                id: downloadButton
                objectName: "download_" + card.name
                visible: !card.downloaded && card.transfer === null
                ink: Commons.Color.accent
                text: card.s.t("action.download")
                onClicked: { card.selectRequested(); AerialStore.download(card.name) }
            }
            OverlayButton {
                id: cancelButton
                objectName: "cancel_" + card.name
                visible: card.transfer !== null
                text: card.s.t("action.cancel")
                onClicked: AerialStore.cancel(card.name)
            }
            OverlayButton {
                id: previewButton
                objectName: "preview_" + card.name
                visible: card.downloaded
                text: card.s.t("action.preview")
                onClicked: { card.selectRequested(); AerialStore.preview(card.name) }
            }
            OverlayButton {
                id: keepButton
                objectName: "keep_" + card.name
                visible: card.downloaded && !card.kept
                ink: Commons.Color.accent
                text: card.s.t("action.keep")
                onClicked: { card.selectRequested(); AerialStore.keep(card.name) }
            }
            OverlayButton {
                id: deleteButton
                objectName: "delete_" + card.name
                visible: card.downloaded
                text: card.s.t("action.delete")
                onClicked: AerialStore.remove(card.name)
            }
        }

        Rectangle {
            visible: card.downloading
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            height: Style.space(3)
            width: parent.width * card.progress
            color: Commons.Color.accent
        }
    }

    RowLayout {
        anchors.left: frame.left
        anchors.right: frame.right
        anchors.top: frame.bottom
        anchors.topMargin: Style.space(6)
        spacing: Style.space(8)
        Label {
            Layout.fillWidth: true
            text: card.modelData.label
            color: card.downloaded ? Commons.Color.foreground : Tone.muted
        }
        Label {
            text: AerialStore.formatBytes(card.modelData.bytes)
            color: Tone.muted
            font.pixelSize: Style.font.bodySmall
        }
    }
}
