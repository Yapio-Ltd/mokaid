import QtQuick
import QtQuick.Controls.Basic as Basic

Basic.Dialog {
    id: control
    // Qt retains standard button roles, closing policy, focus and result signals.
    padding: 24
    font.family: Theme.fontFamily
    font.pixelSize: 13
    palette.window: Theme.surface
    palette.windowText: Theme.text
    palette.text: Theme.text
    palette.buttonText: Theme.text
    palette.base: Theme.deep
    palette.button: Theme.control
    palette.highlight: Theme.selection
    palette.highlightedText: Theme.text
    palette.light: Theme.selected
    palette.midlight: Theme.hover
    palette.dark: Theme.border
    palette.disabled.windowText: Theme.muted
    palette.disabled.text: Theme.muted
    palette.disabled.buttonText: Theme.muted

    background: Rectangle {
        radius: Theme.radiusDialog
        border.color: "#514368"
        gradient: Gradient {
            GradientStop { position: 0; color: "#19192a" }
            GradientStop { position: 1; color: "#10121d" }
        }
    }
    header: MokaidLabel {
        text: control.title
        visible: text.length > 0
        font.pixelSize: 21
        font.weight: Font.DemiBold
        padding: 24
        bottomPadding: 8
        wrapMode: Text.Wrap
    }
    footer: Basic.DialogButtonBox {
        visible: count > 0
        standardButtons: control.standardButtons
        padding: 24
        topPadding: 12
        spacing: 10
        delegate: MokaidButton {
            highlighted: Basic.DialogButtonBox.buttonRole === Basic.DialogButtonBox.AcceptRole
                         || Basic.DialogButtonBox.buttonRole === Basic.DialogButtonBox.YesRole
        }
        background: Item {}
    }
}
