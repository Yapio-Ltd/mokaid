import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: chatPanel
    property bool compact: false
    property bool embedded: false
    signal closed()
    signal overviewRequested()
    radius: Theme.radiusPanel; border.color: Theme.border
    gradient: Gradient { GradientStop { position: 0; color: Theme.panelTop } GradientStop { position: 1; color: Theme.panelBottom } }
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: function(wheel) { wheel.accepted = true } }
    ColumnLayout {
        anchors.fill: parent; anchors.margins: chatPanel.compact ? 16 : 20; spacing: chatPanel.compact ? 10 : 16
        RowLayout {
            visible: !chatPanel.embedded
            Layout.fillWidth: true; spacing: 12
            ColumnLayout {
                Layout.fillWidth: true; spacing: 5
                MokaidLabel { Layout.fillWidth: true; text: office.selectedAgent.display_name || "Conversation"; font.weight: Font.DemiBold; font.pixelSize: 19; elide: Text.ElideRight }
                MokaidLabel { Layout.fillWidth: true; text: office.selectedAgent.role_title || ""; color: Theme.secondary; font.pixelSize: 12; elide: Text.ElideRight }
            }
            MokaidButton { objectName: "officeChatClose"; iconName: "close"; quiet: true; Accessible.name: "Close conversation"; onClicked: { office.closeChat(); chatPanel.closed() } }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: !chatPanel.compact && !chatPanel.embedded && office.selectedAgent.kind === "ai"
            MokaidButton {
                objectName: "rentOutAgent"
                Layout.fillWidth: true
                implicitHeight: 40
                iconName: "marketplace"
                text: "Rent out"
                enabled: session.online
                onClicked: features.openMarketplaceOffer(office.selectedAgent.id, "rent")
            }
            MokaidButton {
                objectName: "sellAgent"
                Layout.fillWidth: true
                implicitHeight: 40
                iconName: "billing"
                text: "Sell"
                enabled: session.online
                onClicked: features.openMarketplaceOffer(office.selectedAgent.id, "sale")
            }
        }
        MokaidButton {
            objectName: "agentPerformance"
            visible: !chatPanel.compact && !chatPanel.embedded
            Layout.fillWidth: true
            implicitHeight: 40
            iconName: "analytics"
            text: "View performance"
            onClicked: features.openRecord("agent-performance", office.selectedAgent.id)
        }
        Rectangle { visible: !chatPanel.embedded; Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.divider }
        MokaidButton { visible: !chatPanel.compact && !chatPanel.embedded; Layout.fillWidth: true; iconName: "plus"; text: "Assign a mission with files"; enabled: !!office.selectedAgent.id; onClicked: missions.beginForAgent(office.selectedAgent.id, office.draft) }
        MokaidLabel {
            visible: chatPanel.compact && !chatPanel.embedded
            Layout.fillWidth: true; wrapMode: Text.Wrap; color: Theme.secondary; font.pixelSize: 12
            text: office.selectedAgent.current_task_id ? "Working on a mission. Ask for an update."
                : "Ask a question or tell your agent what you need."
        }
        RowLayout {
            Layout.fillWidth: true; spacing: 8
            MokaidComboBox { Layout.fillWidth: true; model: office.conversations; textRole: "title"; valueRole: "id"; displayText: office.conversationId ? currentText : "Current conversation"; onActivated: office.selectConversation(currentValue) }
            MokaidButton { visible: !!office.conversationId; text: "Current"; onClicked: office.selectConversation("") }
            MokaidButton { iconName: "plus"; enabled: session.online; Accessible.name: "New conversation"; onClicked: office.newConversation() }
        }
        ListView {
            id: messages; Layout.fillWidth: true; Layout.fillHeight: true; model: office.messages; spacing: 12; clip: true
            onCountChanged: positionViewAtEnd()
            MokaidLabel {
                anchors.centerIn: parent; width: parent.width - 20
                visible: messages.count === 0 && !office.loading && !office.stream && !office.error
                text: "Start a conversation with " + (office.selectedAgent.display_name || "your agent") + "."
                wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter; color: Theme.secondary
            }
            delegate: Rectangle {
                required property var modelData
                width: messages.width; height: messageContent.implicitHeight + 28; radius: Theme.radiusControl
                color: modelData.author_kind === "member" ? Theme.selected : Theme.control
                border.color: modelData.author_kind === "member" ? Theme.selectedBorder : Theme.divider
                ColumnLayout {
                    id: messageContent; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 14; spacing: 8
                    MokaidLabel { Layout.fillWidth: true; text: modelData.author_kind === "agent" ? office.selectedAgent.display_name : (modelData.author_name || "You"); color: Theme.secondary; font.pixelSize: 11; font.weight: Font.DemiBold; elide: Text.ElideRight }
                    TextEdit {
                        Layout.fillWidth: true; text: modelData.body || ""; color: Theme.text; textFormat: TextEdit.PlainText
                        readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; font.pixelSize: 13; font.family: Theme.fontFamily
                        selectionColor: Theme.selection; selectedTextColor: Theme.text
                        Accessible.name: "Message"
                    }
                    DeliveryGallery {
                        Layout.fillWidth: true
                        files: modelData.attachments || []
                        showHeading: false
                    }
                    MokaidButton { visible: !!modelData.task_id; text: "View task"; onClicked: features.openRecord("tasks", modelData.task_id) }
                }
            }
            footer: MokaidLabel { width: messages.width; text: office.stream; visible: text.length > 0; wrapMode: Text.Wrap; padding: 12; color: Theme.secondary }
            ScrollBar.vertical: ScrollBar {}
        }
        BusyIndicator { running: office.loading; visible: running; Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: 30; Layout.preferredHeight: 30 }
        MokaidLabel { text: office.error; visible: text.length > 0; wrapMode: Text.Wrap; color: Theme.warning; Layout.fillWidth: true }
        ScrollView {
            Layout.fillWidth: true; Layout.preferredHeight: chatPanel.compact ? 72 : 108
            MokaidTextArea {
                objectName: "officeChatComposer"
                id: composer; text: office.draft; readOnly: !!office.conversationId; placeholderText: office.conversationId ? "History is read only. Return to the current conversation." : session.online ? "Message your agent…" : "Draft a message while offline…"
                wrapMode: TextEdit.Wrap; selectByMouse: true; onTextChanged: if (office.draft !== text) office.draft = text
                Accessible.name: "Message draft"
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape && chatPanel.compact) { chatPanel.overviewRequested(); event.accepted = true; return }
                    if (event.key === Qt.Key_Return && (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier))) { office.send([]); event.accepted = true }
                }
            }
        }
        RowLayout {
            MokaidLabel { text: "⌘ / Ctrl + Enter"; color: Theme.muted; font.pixelSize: 11; Layout.fillWidth: true; Accessible.name: "Command or Control and Enter to send" }
            MokaidButton { objectName: "officeChatSend"; iconName: "send"; text: office.sending ? "Sending…" : "Send"; highlighted: true; enabled: session.online && !office.conversationId && !office.sending && office.draft.trim().length > 0; onClicked: office.send([]) }
        }
    }
}
