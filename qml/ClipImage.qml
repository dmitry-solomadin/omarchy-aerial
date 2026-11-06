import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

// A clip's picture with the theme's corners. A plain image can't clip itself to
// a radius without a shader, so the corners are painted over it in the window
// color. Sharp themes skip that.
Item {
    id: root
    property url source: ""
    property real imageOpacity: 1

    Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: Util.alpha(Commons.Color.foreground, .06)
    }
    Ui.SizedImage {
        anchors.fill: parent
        url: root.source
        crop: true
        opacity: root.imageOpacity
    }
    Rectangle {
        visible: Style.cornerRadius > 0
        anchors.fill: parent
        anchors.margins: -Style.cornerRadius
        radius: Style.cornerRadius * 2
        color: "transparent"
        border.width: Style.cornerRadius
        border.color: Commons.Color.background
    }
}
