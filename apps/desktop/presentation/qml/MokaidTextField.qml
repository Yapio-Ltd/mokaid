import QtQuick
import QtQuick.Controls.Basic as Basic

Basic.TextField {
    // Explicit native design-system control.
    id: control
    implicitHeight: 44
    leftPadding: 14; rightPadding: 14; topPadding: 11; bottomPadding: 11
    font.family: Theme.fontFamily; font.pixelSize: 13
    selectByMouse: true; hoverEnabled: true
    color: Theme.text; placeholderTextColor: Theme.muted
    selectionColor: Theme.selection; selectedTextColor: Theme.text
    opacity: enabled ? 1 : .6
    background: Rectangle {
        radius: Theme.radiusControl; color: control.enabled ? "#0e101a" : Theme.surface
        border.color: control.activeFocus ? Theme.focusBorder : control.hovered ? Theme.selectedBorder : Theme.border
        border.width: 1
        Rectangle { anchors.fill: parent; anchors.margins: -3; radius: parent.radius + 3; color: "transparent"; border.color: Theme.focusHalo; visible: control.activeFocus }
    }
}
