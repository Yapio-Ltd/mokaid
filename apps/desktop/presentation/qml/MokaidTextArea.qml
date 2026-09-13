import QtQuick
import QtQuick.Controls.Basic as Basic

Basic.TextArea {
    // Explicit native design-system control.
    id: control
    padding: 12; selectByMouse: true
    color: Theme.text; placeholderTextColor: Theme.muted
    selectionColor: Theme.primary; selectedTextColor: "white"
    background: Rectangle { radius: 8; color: Theme.deep; border.color: control.activeFocus ? Theme.primary : Theme.border; border.width: control.activeFocus ? 2 : 1 }
}
