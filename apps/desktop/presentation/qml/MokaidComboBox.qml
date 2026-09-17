import QtQuick
import QtQuick.Controls.Basic as Basic

Basic.ComboBox {
    // Explicit native design-system control.
    id: control
    implicitHeight: 44; leftPadding: 14; rightPadding: 38
    opacity: enabled ? 1 : .6
    font.family: Theme.fontFamily; font.pixelSize: 13
    hoverEnabled: true
    palette.text: Theme.text; palette.buttonText: Theme.text
    palette.base: Theme.raised; palette.highlight: Theme.selection
    contentItem: Text { textFormat: Text.PlainText; text: control.displayText; color: control.enabled ? Theme.text : Theme.muted; font: control.font; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
    indicator: MokaidIcon { name: "chevron-down"; size: 16; color: control.enabled ? Theme.secondary : Theme.muted; x: control.width - width - 14; y: (control.height - height) / 2 }
    background: Rectangle {
        radius: Theme.radiusControl; color: control.hovered ? Theme.controlHover : Theme.control
        border.color: control.visualFocus ? Theme.focusBorder : control.popup.visible ? Theme.selectedBorder : Theme.border; border.width: 1
        Rectangle { anchors.fill: parent; anchors.margins: -3; radius: parent.radius + 3; color: "transparent"; border.color: Theme.focusHalo; visible: control.visualFocus }
    }
    delegate: Basic.ItemDelegate {
        id: option
        required property int index
        width: control.width - 12; height: 44
        text: control.textAt(index)
        highlighted: control.highlightedIndex === index
        contentItem: MokaidLabel { text: option.text; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
        background: Rectangle { radius: 8; color: option.highlighted || option.hovered ? Theme.selected : "transparent"; border.color: option.visualFocus ? Theme.focusBorder : "transparent" }
    }
    popup: Basic.Popup {
        y: control.height + 6; width: control.width
        implicitHeight: Math.min(contentItem.implicitHeight + 12, 320); padding: 6
        contentItem: ListView {
            clip: true; implicitHeight: contentHeight
            model: control.popup.visible ? control.delegateModel : null
            currentIndex: control.highlightedIndex
            Basic.ScrollIndicator.vertical: Basic.ScrollIndicator {}
        }
        background: Rectangle { radius: Theme.radiusControl; color: "#171927"; border.color: "#4b4264" }
    }
}
