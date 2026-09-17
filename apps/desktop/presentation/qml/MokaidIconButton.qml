import QtQuick
import QtQuick.Controls

AbstractButton {
    id: root
    property string iconName: "more"
    property string hint: ""
    property bool subtle: false
    implicitWidth: 44; implicitHeight: 44
    hoverEnabled: true
    Accessible.name: hint
    opacity: enabled ? 1 : .45
    background: Rectangle {
        radius: Theme.radiusControl
        color: root.subtle && !root.hovered ? "transparent" : root.hovered ? Theme.hover : Theme.surface
        border.color: root.visualFocus ? Theme.focusBorder : root.subtle && !root.hovered ? "transparent" : root.hovered ? Theme.selectedBorder : Theme.border
        Rectangle { anchors.fill: parent; anchors.margins: -3; radius: parent.radius + 3; color: "transparent"; border.color: Theme.focusHalo; visible: root.visualFocus }
        Behavior on color { ColorAnimation { duration: system.reducedMotion ? 0 : 130 } }
    }
    contentItem: MokaidIcon { name: root.iconName; size: 19; color: root.hovered ? Theme.text : Theme.secondary }
    ToolTip.visible: hovered && hint.length > 0
    ToolTip.delay: 650
    ToolTip.text: hint
}
