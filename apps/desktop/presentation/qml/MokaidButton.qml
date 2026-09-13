import QtQuick
import QtQuick.Controls.Basic as Basic

Basic.Button {
    // An explicit type name avoids shadowing QtQuick.Controls.Button.
    id: control
    implicitHeight: 36
    implicitWidth: Math.max(88, contentItem.implicitWidth + leftPadding + rightPadding)
    leftPadding: 14; rightPadding: 14
    hoverEnabled: true
    contentItem: Text {
        textFormat: Text.PlainText
        text: control.text; font: control.font
        color: control.enabled ? Theme.text : Theme.muted
        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
    background: Rectangle {
        radius: 8
        color: !control.enabled ? Theme.raised : control.highlighted ? (control.down ? "#6347d9" : control.hovered ? "#8c70ff" : Theme.primary) : control.down ? Theme.hover : control.hovered ? Theme.hover : Theme.raised
        border.color: control.visualFocus ? Theme.primary : control.highlighted ? "transparent" : Theme.border
        border.width: control.visualFocus ? 2 : 1
    }
}
