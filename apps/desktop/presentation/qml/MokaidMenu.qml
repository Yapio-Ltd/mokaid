import QtQuick
import QtQuick.Controls.Basic as Basic

Basic.Menu {
    id: control
    // Qt's default ListView does not supply an implicit width. Custom menu
    // backgrounds must therefore retain a real width, including long actions.
    implicitWidth: {
        let result = 224
        for (let index = 0; index < count; ++index) {
            const entry = itemAt(index)
            if (entry && entry.visible) result = Math.max(result, entry.implicitWidth + leftPadding + rightPadding)
        }
        return Math.min(420, result)
    }
    padding: 6
    margins: 8
    popupType: Basic.Popup.Item
    function openFor(anchor) {
        // Mouse activation does not focus buttons on every platform. Establish
        // the opener before popup focus is captured so Escape returns to it.
        anchor.forceActiveFocus(Qt.PopupFocusReason)
        // A record selection can rebuild its ListView delegates immediately
        // after this click. Keep the popup on the persistent window content,
        // using the button only to calculate its opening position.
        const host = anchor.Window.window.contentItem
        const point = anchor.mapToItem(host, Math.max(0, anchor.width - width), anchor.height + 6)
        popup(host, point.x, point.y)
    }
    font.family: Theme.fontFamily
    font.pixelSize: 13
    palette.window: Theme.surface
    palette.windowText: Theme.text
    palette.text: Theme.text
    palette.buttonText: Theme.text
    palette.light: Theme.selected
    palette.midlight: Theme.hover
    palette.dark: Theme.border
    palette.highlight: Theme.selection
    palette.highlightedText: Theme.text
    palette.disabled.windowText: Theme.muted
    palette.disabled.text: Theme.muted
    palette.disabled.buttonText: Theme.muted

    // Explicit entries can use MokaidMenu.Entry; Action-generated items use this
    // delegate. Both keep Qt's check marks, submenus, shortcuts and activation.
    component Entry: Basic.MenuItem {
        id: entry
        property bool destructive: false
        implicitHeight: 38
        leftPadding: 12
        rightPadding: 12
        spacing: 8
        font.family: Theme.fontFamily
        font.pixelSize: 13
        palette.windowText: !enabled ? Theme.muted : destructive ? Theme.danger : Theme.text
        icon.width: 18
        icon.height: 18
        background: Rectangle {
            implicitWidth: 200
            radius: 8
            color: entry.down ? Theme.hover : entry.highlighted ? Theme.selected : "transparent"
            border.color: entry.visualFocus ? Theme.focusBorder : "transparent"
        }
    }
    component Separator: Basic.MenuSeparator {
        topPadding: 5
        bottomPadding: 5
        contentItem: Rectangle { implicitWidth: 200; implicitHeight: 1; color: Theme.divider }
    }
    delegate: Entry {}
    background: Rectangle {
        implicitWidth: 220
        radius: Theme.radiusControl
        border.color: "#4b4264"
        gradient: Gradient {
            GradientStop { position: 0; color: "#191a2b" }
            GradientStop { position: 1; color: "#10121e" }
        }
    }
}
