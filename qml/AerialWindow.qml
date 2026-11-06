import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "."

FloatingWindow {
    id: window
    title: "Aerial"
    visible: false
    implicitWidth: Style.space(1180)
    implicitHeight: Style.space(780)
    minimumSize: Qt.size(Style.space(640), Style.space(400))
    color: Commons.Color.background
    // A compositor close must also clear FloatingWindow's requested visibility.
    onClosed: visible = false
    onMinimizedChanged: AerialStore.windowMinimized = minimized
    onVisibleChanged: {
        if (visible) AerialStore.windowShown()
        else {
            AerialStore.windowOpen = false
            AerialStore.selected = ""
        }
    }

    // Built only while open, so the shell holds no decoded thumbnails when closed.
    Loader {
        id: content
        anchors.fill: parent
        active: window.visible
        sourceComponent: WindowContent { onCloseRequested: window.visible = false }
    }
}
