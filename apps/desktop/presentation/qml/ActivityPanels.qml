import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    readonly property bool protectedWork: workspaceDialog.opened
    function openSearch() { if (!session.workspaceId) return; searchPopup.open(); queryField.forceActiveFocus() }
    function openNotifications() { activity.refreshNotifications(); notificationsPopup.open() }
    function openWorkspace() { workspaceDialog.open(); workspaceName.forceActiveFocus() }
    Connections {
        target: activity
        function onWorkspaceCreated(id) { workspaceDialog.close(); features.navigate("office") }
        function onNavigateRequested(page, id) { searchPopup.close(); notificationsPopup.close() }
    }
    Connections {
        target: session
        function onCleared() { searchPopup.close(); notificationsPopup.close(); workspaceDialog.close(); workspaceName.clear(); industry.clear() }
    }
    Popup {
        id: searchPopup; anchors.centerIn: parent; modal: true; width: Math.min(parent.width - 80, 640); height: Math.min(parent.height - 120, 580)
        padding: 20
        background: Rectangle { color: Theme.surface; radius: 16; border.color: Theme.border }
        ColumnLayout {
            anchors.fill: parent; spacing: 14
            MokaidLabel { text: "Search your workspace"; color: Theme.text; font.bold: true; font.pixelSize: 18 }
            MokaidTextField { id: queryField; Layout.fillWidth: true; text: activity.query; placeholderText: "Tasks, projects, agents, knowledge…"; onTextEdited: activity.query = text; Accessible.name: "Global workspace search" }
            MokaidLabel { text: activity.error; visible: text.length > 0; color: Theme.warning; wrapMode: Text.Wrap; Layout.fillWidth: true }
            ListView {
                id: results; Layout.fillWidth: true; Layout.fillHeight: true; clip: true; model: activity.searchResults
                delegate: ItemDelegate {
                    required property var modelData; width: results.width; height: 62
                    contentItem: ColumnLayout {
                        MokaidLabel { text: modelData.title || modelData.name || modelData.display_name || "Result"; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                        MokaidLabel { text: modelData.section; color: Theme.muted; font.pixelSize: 11 }
                    }
                    background: Rectangle { color: parent.hovered || parent.visualFocus ? Theme.hover : "transparent"; radius: 8 }
                    onClicked: activity.openSearchResult(modelData.page, modelData.id)
                }
                MokaidLabel { anchors.centerIn: parent; visible: results.count === 0 && !activity.busy; text: activity.query.length < 2 ? "Type at least two characters." : "No matching results."; color: Theme.muted }
                ScrollBar.vertical: ScrollBar {}
            }
            BusyIndicator { Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: 24; Layout.preferredHeight: 24; visible: activity.busy; running: visible }
        }
    }
    Popup {
        id: notificationsPopup; anchors.centerIn: parent; modal: true; width: Math.min(parent.width - 80, 560); height: Math.min(parent.height - 120, 600)
        padding: 20
        background: Rectangle { color: Theme.surface; radius: 16; border.color: Theme.border }
        ColumnLayout {
            anchors.fill: parent; spacing: 14
            RowLayout {
                MokaidLabel { text: "Notifications"; color: Theme.text; font.bold: true; font.pixelSize: 20; Layout.fillWidth: true }
                MokaidLabel { text: activity.unreadCount + " unread"; color: Theme.secondary }
                ToolButton { text: "↻"; onClicked: activity.refreshNotifications(); Accessible.name: "Refresh notifications" }
            }
            MokaidLabel { Layout.fillWidth: true; text: activity.error; visible: text.length > 0; color: Theme.warning; wrapMode: Text.Wrap }
            ListView {
                id: notifications; model: activity.notifications; Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 6
                delegate: ItemDelegate {
                    required property var modelData; width: notifications.width; height: notificationContent.implicitHeight + 24
                    background: Rectangle { radius: 8; color: parent.hovered ? Theme.hover : modelData.read_at ? "transparent" : "#221d32" }
                    contentItem: ColumnLayout {
                        id: notificationContent; spacing: 5
                        MokaidLabel { text: modelData.title || "Notification"; font.bold: !modelData.read_at; color: Theme.text; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        MokaidLabel { text: modelData.body || ""; color: Theme.secondary; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        MokaidLabel { text: modelData.inserted_at ? new Date(modelData.inserted_at).toLocaleString() : ""; color: Theme.muted; font.pixelSize: 10 }
                    }
                    onClicked: activity.openNotification(modelData.id)
                }
                MokaidLabel { anchors.centerIn: parent; visible: notifications.count === 0 && !activity.busy; text: "You're all caught up."; color: Theme.muted }
                ScrollBar.vertical: ScrollBar {}
            }
        }
    }
    Dialog {
        id: workspaceDialog; anchors.centerIn: parent; modal: true; title: "Create workspace"; width: 480; closePolicy: Popup.NoAutoClose
        ColumnLayout {
            width: parent.width; spacing: 14
            MokaidLabel { text: "Workspace name"; color: Theme.secondary }
            MokaidTextField { id: workspaceName; Layout.fillWidth: true; placeholderText: "Your company or team" }
            MokaidLabel { text: "Industry (optional)"; color: Theme.secondary }
            MokaidTextField { id: industry; Layout.fillWidth: true; placeholderText: "e.g. Software" }
            MokaidLabel { text: activity.error; color: Theme.warning; visible: text.length > 0; Layout.fillWidth: true; wrapMode: Text.Wrap }
        }
        footer: DialogButtonBox {
            MokaidButton { text: "Cancel"; enabled: !activity.busy; onClicked: workspaceDialog.close() }
            MokaidButton { text: activity.busy ? "Creating…" : "Create workspace"; highlighted: true; enabled: !activity.busy && workspaceName.text.trim().length > 0; onClicked: activity.createWorkspace(workspaceName.text, industry.text) }
        }
    }
}
