import QtQuick
import QtQuick.Controls.Basic as Basic

Basic.ComboBox {
    // Explicit native design-system control.
    id: control
    implicitHeight: 38; leftPadding: 12; rightPadding: 30
    palette.text: Theme.text; palette.buttonText: Theme.text
    palette.base: Theme.raised; palette.highlight: Theme.primary
    contentItem: Text { textFormat: Text.PlainText; text: control.displayText; color: control.enabled ? Theme.text : Theme.muted; font: control.font; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
    background: Rectangle { radius: 8; color: Theme.raised; border.color: control.visualFocus ? Theme.primary : Theme.border; border.width: control.visualFocus ? 2 : 1 }
}
