import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    color: Theme.surface; border.color: Theme.border
    ColumnLayout {
        anchors.fill: parent; anchors.margins: 16; spacing: 12
        RowLayout {
            ColumnLayout {
                Layout.fillWidth: true; spacing: 2
                MokaidLabel { text: office.selectedAgent.display_name || "Conversation"; color: Theme.text; font.bold: true; font.pixelSize: 17 }
                MokaidLabel { text: office.selectedAgent.role_title || ""; color: Theme.secondary; font.pixelSize: 11 }
            }
            ToolButton { text: "×"; Accessible.name: "Close conversation"; onClicked: office.closeChat() }
        }
        RowLayout {
            MokaidComboBox { Layout.fillWidth: true; model: office.conversations; textRole: "title"; valueRole: "id"; displayText: office.conversationId ? currentText : "Current conversation"; onActivated: office.selectConversation(currentValue) }
            MokaidButton { visible: !!office.conversationId; text: "Current"; onClicked: office.selectConversation("") }
            ToolButton { text: "+"; enabled: session.online; Accessible.name: "New conversation"; onClicked: office.newConversation() }
        }
        ListView {
            id: messages; Layout.fillWidth: true; Layout.fillHeight: true; model: office.messages; spacing: 12; clip: true
            onCountChanged: positionViewAtEnd()
            delegate: Rectangle {
                required property var modelData
                width: messages.width; height: messageContent.implicitHeight + 24; radius: 10
                color: modelData.author_kind === "member" ? "#252037" : Theme.raised
                ColumnLayout {
                    id: messageContent; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 12; spacing: 8
                    MokaidLabel { text: modelData.author_kind === "agent" ? office.selectedAgent.display_name : (modelData.author_name || "You"); color: Theme.secondary; font.pixelSize: 10; font.bold: true }
                    TextEdit {
                        Layout.fillWidth: true; text: modelData.body || ""; color: Theme.text; textFormat: TextEdit.PlainText
                        readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; font.pixelSize: 13
                        Accessible.name: "Message"
                    }
                    Repeater {
                        model: modelData.attachments || []
                        MokaidButton {
                            required property var modelData
                            Layout.fillWidth: true; text: "↗ " + modelData.name
                            onClicked: preview.openFile({id: modelData.drive_item_id, name: modelData.name, mime_type: modelData.mime_type})
                        }
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
            Layout.fillWidth: true; Layout.preferredHeight: 94
            MokaidTextArea {
                id: composer; text: office.draft; readOnly: !!office.conversationId; placeholderText: office.conversationId ? "History is read only. Return to the current conversation." : session.online ? "Message your agent…" : "Draft a message while offline…"
                wrapMode: TextEdit.Wrap; selectByMouse: true; onTextChanged: if (office.draft !== text) office.draft = text
                Accessible.name: "Message draft"
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Return && (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier))) { office.send([]); event.accepted = true }
                }
            }
        }
        RowLayout {
            MokaidLabel { text: "⌘ / Ctrl + Enter to send"; color: Theme.muted; font.pixelSize: 10; Layout.fillWidth: true }
            MokaidButton { text: office.sending ? "Sending…" : "Send"; highlighted: true; enabled: session.online && !office.conversationId && !office.sending && office.draft.trim().length > 0; onClicked: office.send([]) }
        }
    }
}
