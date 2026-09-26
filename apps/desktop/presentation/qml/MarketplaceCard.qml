pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    required property var controller
    required property var listing
    property bool compact: false
    implicitHeight: compact ? 104 : 228
    radius: 12; color: hover.hovered ? "#171725" : "#11131e"
    border.color: hover.hovered ? "#63507f" : "#282a3e"
    HoverHandler { id: hover }
    AbstractButton {
        id: openButton; objectName: "marketplaceCard-" + root.listing.id
        anchors.fill: parent
        Accessible.name: "View " + root.controller.agentName(root.listing)
        onClicked: root.controller.showListing(root.listing.id)
        background: Rectangle { color: "transparent"; radius: 12; border.color: openButton.visualFocus ? Theme.focusBorder : "transparent" }
    }
    GridLayout {
        anchors.fill: parent; anchors.margins: 18
        columns: root.compact ? 3 : 1; rowSpacing: 8; columnSpacing: 18
        WorkforcePortrait { agent: root.controller.faceAgent(root.listing.agent); size: root.compact ? 60 : 76; Layout.alignment: Qt.AlignLeft | Qt.AlignTop }
        ColumnLayout {
            Layout.fillWidth: true; spacing: 5
            MokaidLabel { text: root.controller.agentName(root.listing); font.pixelSize: 15; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
            MokaidLabel { text: root.controller.roleTitle(root.listing.agent) || "AI assistant"; font.pixelSize: 12; color: Theme.secondary; Layout.fillWidth: true; elide: Text.ElideRight }
            RowLayout {
                spacing: 5
                MokaidIcon { name: "star"; size: 13; color: "#ffb540" }
                MokaidLabel { text: "Level " + (root.listing.agent_level || (root.listing.agent && root.listing.agent.level) || 1); color: "#f0c88c"; font.pixelSize: 11 }
                MokaidLabel { text: "· " + (root.listing.knowledge_item_count || 0) + " knowledge"; color: Theme.muted; font.pixelSize: 10; Layout.fillWidth: true; elide: Text.ElideRight }
            }
        }
        RowLayout {
            Layout.fillWidth: true; spacing: 6
            MokaidLabel { text: root.controller.priceLabel(root.listing); font.pixelSize: 12; Layout.fillWidth: true; elide: Text.ElideRight }
            MokaidButton { text: "View"; highlighted: true; implicitWidth: 54; implicitHeight: 32; leftPadding: 10; rightPadding: 10; font.pixelSize: 11; onClicked: root.controller.showListing(root.listing.id) }
        }
    }
    MokaidButton {
        anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 10
        visible: !root.compact
        iconName: "heart"; implicitHeight: 28; implicitWidth: 28; leftPadding: 6; rightPadding: 6
        quiet: true; highlighted: root.controller.savedIds.indexOf(root.listing.id) >= 0
        Accessible.name: (highlighted ? "Unsave " : "Save ") + root.controller.agentName(root.listing)
        onClicked: root.controller.toggleSaved(root.listing.id)
    }
}
