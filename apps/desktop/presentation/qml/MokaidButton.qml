import QtQuick
import QtQuick.Controls.Basic as Basic
import QtQuick.Layouts

Basic.Button {
    // An explicit type name avoids shadowing QtQuick.Controls.Button.
    id: control
    property string iconName: ""
    property bool quiet: false
    implicitHeight: 44
    implicitWidth: text.length ? Math.max(88, contentItem.implicitWidth + leftPadding + rightPadding) : 42
    leftPadding: text.length ? 16 : 11; rightPadding: leftPadding
    spacing: 8
    font.family: Theme.fontFamily; font.pixelSize: 13; font.weight: Font.DemiBold
    hoverEnabled: true
    contentItem: RowLayout {
        spacing: control.text.length && control.iconName.length ? 8 : 0
        MokaidIcon { visible: control.iconName.length > 0; name: control.iconName; size: 17; color: control.enabled ? Theme.text : Theme.muted; Layout.alignment: Qt.AlignVCenter }
        Text {
            visible: control.text.length > 0
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: control.text; font: control.font
            color: control.enabled ? Theme.text : Theme.muted
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }
    background: Rectangle {
        radius: Theme.radiusControl
        opacity: control.enabled ? 1 : .55
        gradient: Gradient {
            GradientStop { position: 0; color: control.highlighted ? (control.down ? "#6141b5" : control.hovered ? "#794bdd" : "#7548db") : control.down || control.hovered ? Theme.controlHover : control.quiet ? "transparent" : Theme.control }
            GradientStop { position: 1; color: control.highlighted ? (control.down ? "#4d2ba8" : control.hovered ? "#744bdd" : Theme.primaryBottom) : control.down || control.hovered ? Theme.control : control.quiet ? "transparent" : "#0f111d" }
        }
        border.color: control.visualFocus ? Theme.focusBorder : control.highlighted ? "#ac86ff" : control.quiet && !control.hovered ? "transparent" : control.hovered ? "#494360" : Theme.border
        border.width: 1
        Rectangle { anchors.fill: parent; anchors.margins: -3; radius: parent.radius + 3; color: "transparent"; border.color: Theme.focusHalo; visible: control.visualFocus }
    }
}
