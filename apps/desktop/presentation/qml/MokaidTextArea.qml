import QtQuick
import QtQuick.Controls.Basic as Basic

Basic.TextArea {
    // Explicit native design-system control.
    id: control
    padding: 14; selectByMouse: true
    font.family: Theme.fontFamily; font.pixelSize: 13
    color: Theme.text; placeholderTextColor: Theme.muted
    selectionColor: Theme.selection; selectedTextColor: Theme.text
    opacity: enabled ? 1 : .6
    background: Rectangle {
        radius: Theme.radiusControl; color: control.enabled ? "#0e101a" : Theme.surface
        border.color: control.activeFocus ? Theme.focusBorder : Theme.border; border.width: 1
        Rectangle { anchors.fill: parent; anchors.margins: -3; radius: parent.radius + 3; color: "transparent"; border.color: Theme.focusHalo; visible: control.activeFocus }
    }
}
