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
        padding: 24
        background: Rectangle { radius: Theme.radiusDialog; border.color: Theme.selectedBorder; gradient: Gradient { GradientStop { position: 0; color: Theme.panelTop } GradientStop { position: 1; color: Theme.panelBottom } } }
        ColumnLayout {
            anchors.fill: parent; spacing: 18
            RowLayout {
                Layout.fillWidth: true
                MokaidLabel { Layout.fillWidth: true; text: "Search your workspace"; font.weight: Font.DemiBold; font.pixelSize: 21 }
                MokaidButton { iconName: "close"; quiet: true; Accessible.name: "Close workspace search"; onClicked: searchPopup.close() }
            }
            MokaidTextField { id: queryField; Layout.fillWidth: true; text: activity.query; placeholderText: "Tasks, projects, agents…"; onTextEdited: activity.query = text; Accessible.name: "Global workspace search" }
            MokaidLabel { text: activity.error; visible: text.length > 0; color: Theme.warning; wrapMode: Text.Wrap; Layout.fillWidth: true }
            ListView {
                id: results; Layout.fillWidth: true; Layout.fillHeight: true; clip: true; model: activity.searchResults; spacing: 4
                delegate: ItemDelegate {
                    id: resultDelegate
                    required property var modelData; width: results.width; height: 68; padding: 12
                    contentItem: ColumnLayout {
                        MokaidLabel { text: modelData.title || modelData.name || modelData.display_name || "Result"; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                        MokaidLabel { text: modelData.section; color: Theme.secondary; font.pixelSize: 12 }
                    }
                    background: Rectangle { color: resultDelegate.hovered || resultDelegate.visualFocus ? Theme.hover : "transparent"; radius: Theme.radiusControl; border.color: resultDelegate.visualFocus ? Theme.focusBorder : "transparent" }
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
        padding: 24
        background: Rectangle { radius: Theme.radiusDialog; border.color: Theme.selectedBorder; gradient: Gradient { GradientStop { position: 0; color: Theme.panelTop } GradientStop { position: 1; color: Theme.panelBottom } } }
        ColumnLayout {
            anchors.fill: parent; spacing: 18
            RowLayout {
                MokaidLabel { text: "Notifications"; font.weight: Font.DemiBold; font.pixelSize: 21; Layout.fillWidth: true }
                MokaidLabel { text: activity.unreadCount + " unread"; color: Theme.secondary; font.pixelSize: 12 }
                MokaidButton { iconName: "refresh"; quiet: true; onClicked: activity.refreshNotifications(); Accessible.name: "Refresh notifications" }
                MokaidButton { iconName: "close"; quiet: true; onClicked: notificationsPopup.close(); Accessible.name: "Close notifications" }
            }
            MokaidLabel { Layout.fillWidth: true; text: activity.error; visible: text.length > 0; color: Theme.warning; wrapMode: Text.Wrap }
            ListView {
                id: notifications; model: activity.notifications; Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 6
                delegate: ItemDelegate {
                    id: notificationDelegate
                    required property var modelData; width: notifications.width; height: notificationContent.implicitHeight + 28; padding: 14
                    background: Rectangle { radius: Theme.radiusControl; color: notificationDelegate.hovered ? Theme.hover : modelData.read_at ? "transparent" : Theme.selected; border.color: notificationDelegate.visualFocus ? Theme.focusBorder : modelData.read_at ? "transparent" : Theme.divider }
                    contentItem: ColumnLayout {
                        id: notificationContent; spacing: 5
                        MokaidLabel { text: modelData.title || "Notification"; font.bold: !modelData.read_at; color: Theme.text; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        MokaidLabel { text: modelData.body || ""; color: Theme.secondary; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        MokaidLabel { text: modelData.inserted_at ? new Date(modelData.inserted_at).toLocaleString() : ""; color: Theme.muted; font.pixelSize: 11 }
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
        padding: 24
        background: Rectangle { radius: Theme.radiusDialog; border.color: Theme.selectedBorder; gradient: Gradient { GradientStop { position: 0; color: Theme.panelTop } GradientStop { position: 1; color: Theme.panelBottom } } }
        header: MokaidLabel { text: workspaceDialog.title; font.pixelSize: 21; font.weight: Font.DemiBold; padding: 24; bottomPadding: 8 }
        ColumnLayout {
            width: parent.width; spacing: 14
            MokaidLabel { text: "Workspace name"; color: Theme.secondary }
            MokaidTextField { id: workspaceName; Layout.fillWidth: true; placeholderText: "Your company or team" }
            MokaidLabel { text: "Industry (optional)"; color: Theme.secondary }
            MokaidTextField { id: industry; Layout.fillWidth: true; placeholderText: "e.g. Software" }
            MokaidLabel { text: activity.error; color: Theme.warning; visible: text.length > 0; Layout.fillWidth: true; wrapMode: Text.Wrap }
        }
        footer: DialogButtonBox {
            padding: 24; topPadding: 12; spacing: 10; background: Item {}
            MokaidButton { text: "Cancel"; enabled: !activity.busy; onClicked: workspaceDialog.close() }
            MokaidButton { text: activity.busy ? "Creating…" : "Create workspace"; highlighted: true; enabled: !activity.busy && workspaceName.text.trim().length > 0; onClicked: activity.createWorkspace(workspaceName.text, industry.text) }
        }
    }
}
