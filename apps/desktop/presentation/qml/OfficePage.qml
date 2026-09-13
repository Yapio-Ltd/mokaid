import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Mokaid.Native 1.0

Item {
    id: root
    property bool active: true
    readonly property var diagnostics: viewport.diagnostics
    RowLayout {
        anchors.fill: parent; spacing: 0
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true
            NativeViewport {
                id: viewport; anchors.fill: parent
                assetRoot: system.assetRoot; agents: office.agents; quality: system.quality
                paused: !root.active
                onAgentSelected: function(id) { office.selectAgent(id) }
                Accessible.role: Accessible.Pane
                Accessible.name: "Interactive office. Select an agent from the list for keyboard access."
            }
            ColumnLayout {
                anchors.left: parent.left; anchors.top: parent.top; anchors.margins: 28; spacing: 6
                MokaidLabel { text: "Your office"; color: Theme.text; font.pixelSize: 26; font.bold: true }
                MokaidLabel { text: office.agents.length + " team members · 9 desks"; color: Theme.secondary }
            }
            BusyIndicator { anchors.centerIn: parent; running: viewport.loading; visible: running }
            Rectangle {
                visible: viewport.error.length > 0; anchors.centerIn: parent; width: Math.min(parent.width - 60, 520); height: recovery.implicitHeight + 40
                radius: 12; color: Theme.surface; border.color: Theme.border
                ColumnLayout {
                    id: recovery; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 20; spacing: 16
                    MokaidLabel { Layout.fillWidth: true; text: "The office renderer could not start.\n\n" + viewport.error; wrapMode: Text.Wrap; color: Theme.warning }
                    MokaidButton { text: "Retry renderer"; onClicked: viewport.retryRenderer() }
                }
            }
            Rectangle {
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 20
                height: 82; radius: 14; color: "#e612121a"; border.color: Theme.border
                ListView {
                    id: agentDock; anchors.fill: parent; anchors.margins: 10; orientation: ListView.Horizontal
                    model: office.agents; spacing: 8; clip: true
                    delegate: ItemDelegate {
                        required property var modelData; width: 160; height: 62
                        highlighted: office.selectedAgent.id === modelData.id
                        background: Rectangle { radius: 8; color: parent.highlighted ? "#28203e" : parent.hovered ? Theme.hover : Theme.raised }
                        contentItem: ColumnLayout {
                            spacing: 3
                            MokaidLabel { text: modelData.display_name; color: Theme.text; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                            MokaidLabel { text: modelData.role_title || modelData.status; color: Theme.secondary; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
                        }
                        onClicked: office.selectAgent(modelData.id)
                    }
                    MokaidLabel { anchors.centerIn: parent; visible: office.agents.length === 0; text: "Your agents will appear here. Hire your first agent from Agents."; color: Theme.secondary }
                    ScrollBar.horizontal: ScrollBar {}
                }
            }
        }
        ChatPanel { Layout.preferredWidth: 410; Layout.fillHeight: true; visible: !!office.selectedAgent.id }
    }
}
