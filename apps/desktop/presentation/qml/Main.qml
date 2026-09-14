import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

ApplicationWindow {
    id: window
    width: 1440; height: 900; minimumWidth: 1000; minimumHeight: 680
    visible: true; title: system.productName
    color: Theme.background
    font.pixelSize: 13
    palette.window: Theme.background; palette.windowText: Theme.text
    palette.base: Theme.surface; palette.alternateBase: Theme.raised
    palette.text: Theme.text; palette.button: Theme.raised; palette.buttonText: Theme.text
    palette.highlight: Theme.primary; palette.highlightedText: "white"
    palette.placeholderText: Theme.muted; palette.mid: Theme.border
    property bool quitting: false
    property bool adminMode: features.currentPage.indexOf("admin-") === 0
    property bool previewsRetained: preview.documents[0] !== null || preview.documents[1] !== null
    property bool workProtected: office.hasDrafts || office.sending || actionDialog.opened || activityPanels.protectedWork || previewsRetained
        || features.driveDownload.busy || features.driveDownload.pendingTransaction.length > 0
    onWorkProtectedChanged: updates.setInstallationAllowed(!workProtected)
    Component.onCompleted: updates.setInstallationAllowed(!workProtected)
    onClosing: function(close) {
        if (!quitting && workProtected) { close.accepted = false; quitDialog.open() }
    }
    Shortcut { sequences: [StandardKey.Quit]; onActivated: window.close() }
    Shortcut { sequence: "Ctrl+K"; onActivated: activityPanels.openSearch() }
    Shortcut { sequence: "Meta+K"; onActivated: activityPanels.openSearch() }
    Shortcut { sequence: "Ctrl+,"; onActivated: preferences.open() }
    Shortcut { sequence: "Meta+,"; onActivated: preferences.open() }
    Connections {
        target: updates
        function onError(message) { notice.text = message; notice.open() }
        function onSaveRequired() { notice.text = "Finish sending messages and downloading files, save your forms, and close all deliverables before installing the update."; notice.open() }
    }
    Connections {
        target: session
        function onChanged() {
            if (window.adminMode && !session.administrator) features.navigate("office")
        }
    }
    RowLayout {
        anchors.fill: parent; spacing: 0
        visible: session.authenticated
        Rectangle {
            Layout.preferredWidth: 232; Layout.fillHeight: true
            color: Theme.surface
            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.border }
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 14; spacing: 16
                RowLayout {
                    Layout.topMargin: 10; spacing: 10
                    Image { source: "qrc:/branding/logo-without-bg.png"; sourceSize.width: 80; sourceSize.height: 80; Layout.preferredWidth: 36; Layout.preferredHeight: 36; fillMode: Image.PreserveAspectFit }
                    MokaidLabel { text: "mokaid"; font.pixelSize: 24; font.bold: true; color: Theme.text }
                    Item { Layout.fillWidth: true }
                }
                MokaidComboBox {
                    Layout.fillWidth: true; model: session.workspaces; textRole: "name"; valueRole: "id"
                    currentIndex: indexOfValue(session.workspaceId)
                    enabled: !window.workProtected && !session.busy
                    onActivated: session.selectWorkspace(currentValue)
                    Accessible.name: "Workspace"
                    ToolTip.visible: hovered && !enabled
                    ToolTip.text: "Save your work and close previews before changing workspace."
                }
                Rectangle {
                    visible: window.adminMode; Layout.fillWidth: true; Layout.preferredHeight: 34
                    radius: 8; color: "#382d17"
                    MokaidLabel { anchors.centerIn: parent; text: "ADMIN · OPERATOR MODE"; color: Theme.warning; font.bold: true; font.pixelSize: 10 }
                }
                ListView {
                    id: navigation
                    Layout.fillWidth: true; Layout.fillHeight: true
                    model: features.pages; clip: true; spacing: 3
                    delegate: ItemDelegate {
                        id: navigationRow
                        required property var modelData
                        width: navigation.width
                        height: !modelData.hidden && (modelData.section === "Administration") === window.adminMode ? 38 : 0
                        visible: height > 0
                        text: modelData.title
                        highlighted: features.currentPage === modelData.id
                        background: Rectangle {
                            radius: 8
                            color: navigationRow.highlighted ? "#28203e" : navigationRow.hovered ? Theme.hover : "transparent"
                        }
                        contentItem: MokaidLabel {
                            text: navigationRow.text; color: navigationRow.highlighted ? "#b3a0ff" : Theme.secondary
                            font.weight: navigationRow.highlighted ? Font.DemiBold : Font.Normal
                            verticalAlignment: Text.AlignVCenter; leftPadding: 10
                        }
                        onClicked: features.navigate(modelData.id)
                    }
                    ScrollBar.vertical: ScrollBar {}
                }
                MokaidButton {
                    visible: session.administrator; Layout.fillWidth: true
                    text: window.adminMode ? "← Back to workspace" : "Administration"
                    onClicked: features.navigate(window.adminMode ? "office" : "admin-overview")
                }
                RowLayout {
                    MokaidLabel { Layout.fillWidth: true; text: session.user.full_name || session.user.email || "Account"; elide: Text.ElideRight; color: Theme.secondary }
                    ToolButton { text: "⋯"; Accessible.name: "Application menu"; onClicked: accountMenu.popup() }
                }
            }
        }
        ColumnLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0
            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: 60; color: Theme.background
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 24; anchors.rightMargin: 20; spacing: 14
                    MokaidLabel { text: features.title || "Office"; font.bold: true; color: Theme.text }
                    Item { Layout.fillWidth: true }
                    MokaidButton { text: "Search workspace…   ⌘ / Ctrl K"; Layout.preferredWidth: 260; enabled: !!session.workspaceId; onClicked: activityPanels.openSearch() }
                    ToolButton { text: activity.unreadCount > 0 ? "● " + activity.unreadCount : "○"; Accessible.name: "Notifications"; enabled: !!session.workspaceId; onClicked: activityPanels.openNotifications() }
                    Rectangle { Layout.preferredWidth: 7; Layout.preferredHeight: 7; radius: 4; color: session.online ? Theme.success : Theme.warning }
                    MokaidLabel { text: session.online ? "Connected" : "Offline · read only"; color: Theme.secondary; font.pixelSize: 11 }
                    ToolButton { text: "↻"; Accessible.name: "Refresh connection and data"; onClicked: session.online ? features.refresh() : session.retry() }
                }
                Rectangle { anchors.bottom: parent.bottom; height: 1; width: parent.width; color: Theme.border }
            }
            MokaidLabel {
                Layout.fillWidth: true; visible: session.error.length > 0
                text: session.error; color: Theme.warning; padding: 12; wrapMode: Text.Wrap
                background: Rectangle { color: "#292416" }
            }
            Item {
                Layout.fillWidth: true; Layout.fillHeight: true
                Loader {
                    id: officeLoader; anchors.fill: parent; active: session.authenticated && !!session.workspaceId; visible: features.currentPage === "office"
                    sourceComponent: OfficePage { active: officeLoader.visible && !preview.visible && window.visibility !== Window.Minimized }
                }
                FeaturePage { anchors.fill: parent; visible: features.currentPage !== "office"; onActionRequested: function(action) { actionDialog.showAction(action) } }
                ColumnLayout {
                    anchors.centerIn: parent; width: 420; spacing: 20
                    visible: !session.workspaceId && !window.adminMode
                    MokaidLabel { text: "Welcome to Mokaid"; color: Theme.text; font.pixelSize: 28; font.bold: true }
                    MokaidLabel { text: "Create your workspace to start building your AI team, or ask a workspace owner for an invitation."; color: Theme.secondary; Layout.fillWidth: true; wrapMode: Text.Wrap }
                    MokaidButton { text: "Create a workspace"; highlighted: true; enabled: session.online; onClicked: activityPanels.openWorkspace() }
                }
                PreviewPanel {
                    anchors.fill: parent; visible: preview.visible
                    onFilesRequested: {
                        // Hide without evicting either document or its form state.
                        preview.visible = false
                        features.navigate("drive")
                    }
                }
            }
        }
    }
    ColumnLayout {
        visible: !session.authenticated
        anchors.centerIn: parent; width: 400; spacing: 22
        Image { source: "qrc:/branding/logo-without-bg.png"; Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: 86; Layout.preferredHeight: 86; fillMode: Image.PreserveAspectFit }
        MokaidLabel { text: "Your AI office.\nRight on your desktop."; font.pixelSize: 32; font.weight: Font.DemiBold; color: Theme.text; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true }
        MokaidLabel { text: "Sign in securely in your browser to connect your workspace."; color: Theme.secondary; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true }
        MokaidButton { text: session.busy ? "Waiting for browser…" : "Sign in to Mokaid"; Layout.fillWidth: true; Layout.preferredHeight: 46; enabled: !session.busy; highlighted: true; onClicked: session.signIn() }
        MokaidButton { visible: session.busy; text: "Cancel sign-in"; Layout.alignment: Qt.AlignHCenter; onClicked: session.cancelSignIn() }
        MokaidLabel { text: session.error; visible: text.length > 0; color: Theme.danger; wrapMode: Text.Wrap; Layout.fillWidth: true }
        MokaidLabel { text: system.productName + " " + system.version; color: Theme.muted; Layout.alignment: Qt.AlignHCenter }
    }
    Menu {
        id: accountMenu
        MenuItem { text: "Desktop preferences…"; onTriggered: preferences.open() }
        MenuItem { text: "Check for updates…"; onTriggered: updates.checkForUpdates() }
        MenuItem { text: "Export diagnostics…"; onTriggered: diagnosticsFile.open() }
        MenuItem { text: "Local profiler…"; onTriggered: profilerDialog.open() }
        MenuItem { text: "Create workspace…"; enabled: session.online; onTriggered: activityPanels.openWorkspace() }
        MenuItem { text: "Close all deliverables…"; enabled: window.previewsRetained; onTriggered: discardPreviews.open() }
        MenuSeparator {}
        MenuItem { text: "Sign out"; onTriggered: signOutDialog.open() }
    }
    ActionDialog { id: actionDialog }
    ActivityPanels { id: activityPanels; anchors.fill: parent }
    Dialog {
        id: signOutDialog; anchors.centerIn: parent; modal: true; title: "Sign out of Mokaid?"
        standardButtons: Dialog.Ok | Dialog.Cancel
        MokaidLabel { text: "Local drafts and open deliverables will be closed.\nYour desktop session will be revoked."; color: Theme.secondary }
        onAccepted: session.signOut()
    }
    Dialog {
        id: quitDialog; anchors.centerIn: parent; modal: true; title: "Close Mokaid?"
        standardButtons: Dialog.Discard | Dialog.Cancel
        MokaidLabel { text: "There are drafts, forms, downloads, or deliverables still open.\nDiscard this local work, cancel downloads, and quit?"; color: Theme.secondary }
        onDiscarded: { window.quitting = true; window.close() }
    }
    Dialog {
        id: discardPreviews; anchors.centerIn: parent; modal: true; title: "Close all deliverables?"
        standardButtons: Dialog.Discard | Dialog.Cancel
        MokaidLabel { text: "Unsaved form entries inside deliverables will be lost."; color: Theme.secondary }
        onDiscarded: preview.clear()
    }
    Dialog {
        id: notice; property string text: ""; anchors.centerIn: parent; modal: true; title: "Mokaid"; width: 460
        standardButtons: Dialog.Ok
        MokaidLabel { width: parent.width; text: notice.text; wrapMode: Text.Wrap; color: Theme.secondary }
    }
    Dialog {
        id: preferences; anchors.centerIn: parent; modal: true; title: "Desktop preferences"; width: 500; standardButtons: Dialog.Close
        ColumnLayout {
            width: parent.width; spacing: 16
            MokaidLabel { text: "3D quality"; color: Theme.secondary }
            MokaidComboBox { model: ["auto", "high", "medium", "low"]; currentIndex: model.indexOf(system.quality); onActivated: system.quality = currentText; Layout.fillWidth: true }
            CheckBox { text: "Reduce interface animations"; checked: system.reducedMotion; onToggled: system.reducedMotion = checked }
            CheckBox { text: "Software compatibility for HTML previews"; checked: system.softwareWeb; onToggled: system.softwareWeb = checked }
            MokaidLabel { text: "Changing HTML compatibility requires restarting Mokaid. Software mode uses more CPU and may be slower."; color: Theme.muted; wrapMode: Text.Wrap; Layout.fillWidth: true }
            MokaidLabel { text: "Diagnostics stay on this computer. Nothing is uploaded automatically."; color: Theme.secondary; wrapMode: Text.Wrap; Layout.fillWidth: true }
            MokaidButton { text: "Export diagnostics…"; onClicked: diagnosticsFile.open() }
            MokaidButton { text: "Local profiler…"; onClicked: profilerDialog.open() }
            MokaidLabel { text: "Version " + system.version; color: Theme.muted }
        }
    }
    FileDialog {
        id: diagnosticsFile; fileMode: FileDialog.SaveFile; defaultSuffix: "json"; nameFilters: ["Diagnostics (*.json)"]
        onAccepted: { if (!system.exportDiagnostics(selectedFile, officeLoader.item ? officeLoader.item.diagnostics : {}, profiler.metrics)) { notice.text = system.error; notice.open() } }
    }
    Dialog {
        id: profilerDialog; anchors.centerIn: parent; modal: false; title: "Local profiler"; width: 440; standardButtons: Dialog.Close
        ColumnLayout {
            width: parent.width; spacing: 12
            MokaidLabel { text: "Presentation intervals · last 600 frames"; color: Theme.text; font.bold: true }
            MokaidLabel { text: "Includes idle gaps and stalls. These are window presentation intervals, not GPU execution times or a 60-FPS certification."; color: Theme.muted; wrapMode: Text.Wrap; Layout.fillWidth: true }
            Repeater {
                model: [{key: "sampleCount", label: "Samples", unit: ""}, {key: "windowSeconds", label: "Window", unit: "s"}, {key: "meanMs", label: "Mean", unit: "ms"}, {key: "p50Ms", label: "p50", unit: "ms"}, {key: "p95Ms", label: "p95", unit: "ms"}, {key: "p99Ms", label: "p99", unit: "ms"}, {key: "maxMs", label: "Maximum", unit: "ms"}]
                RowLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    MokaidLabel { text: modelData.label; color: Theme.secondary; Layout.fillWidth: true }
                    MokaidLabel { text: typeof profiler.metrics[modelData.key] === "number" ? Number(profiler.metrics[modelData.key]).toFixed(modelData.unit ? 2 : 0) + " " + modelData.unit : "—"; color: Theme.text }
                }
            }
            MokaidButton { text: "Reset samples"; onClicked: profiler.reset() }
            MokaidLabel { text: "Nothing is uploaded. Exported diagnostics exclude account and workspace contents."; color: Theme.muted; wrapMode: Text.Wrap; Layout.fillWidth: true }
        }
    }
}
