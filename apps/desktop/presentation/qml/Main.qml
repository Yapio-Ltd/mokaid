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
    font.family: Theme.fontFamily
    palette.window: Theme.background; palette.windowText: Theme.text
    palette.base: Theme.surface; palette.alternateBase: Theme.raised
    palette.text: Theme.text; palette.button: Theme.raised; palette.buttonText: Theme.text
    palette.highlight: Theme.primary; palette.highlightedText: "white"
    palette.placeholderText: Theme.muted; palette.mid: Theme.border
    property bool quitting: false
    property bool adminMode: features.currentPage.indexOf("admin-") === 0
    property bool previewsRetained: preview.documents[0] !== null || preview.documents[1] !== null
    property bool workProtected: office.hasDrafts || office.sending || missions.hasDraft || missions.busy || actionDialog.opened || activityPanels.protectedWork || previewsRetained
        || features.driveDownload.busy || features.driveDownload.pendingTransaction.length > 0 || projectRuntime.busy
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
    Shortcut { sequence: "Ctrl+N"; enabled: session.authenticated && !!session.workspaceId; onActivated: missions.begin() }
    Shortcut { sequence: "Meta+N"; enabled: session.authenticated && !!session.workspaceId; onActivated: missions.begin() }
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
        function onCleared() { completionToast.visible = false; projects.close() }
        function onWorkspaceChanged() { completionToast.visible = false; projects.close() }
    }
    Connections {
        target: missions
        function onOpenTask(taskId) { preview.visible = false; features.openRecord("tasks", taskId) }
        function onCompleted(notification) {
            completionToast.notification = notification
            completionToast.visible = true
            completionTimer.restart()
            system.notifyMission()
        }
    }
    FontLoader { source: "qrc:/ui/fonts/Manrope.ttf" }
    DesktopShell {
        id: desktopShell
        anchors.fill: parent
        visible: session.authenticated
        adminMode: window.adminMode
        protectedWork: window.workProtected
        minimized: window.visibility === Window.Minimized
        onActionRequested: function(action) {
            const createsAgent = action.id === "create" && (action.fields || []).some(function(field) { return field.key === "archetype_key"; });
            if (createsAgent && features.currentPage !== "agent-new") features.navigate("agent-new");
            else actionDialog.showAction(action);
        }
        onSearchRequested: activityPanels.openSearch()
        onNotificationsRequested: activityPanels.openNotifications()
        onPreferencesRequested: preferences.open()
        onAccountMenuRequested: function(anchor) { accountMenu.openFor(anchor) }
        onCreateWorkspaceRequested: activityPanels.openWorkspace()
        onProjectRequested: projects.open()
    }
    Rectangle {
        visible: !session.authenticated
        anchors.centerIn: parent
        width: 484; height: signInContent.implicitHeight + 72
        radius: 28; border.color: Theme.selectedBorder
        gradient: Gradient { GradientStop { position: 0; color: "#18172d" } GradientStop { position: 1; color: "#0d101c" } }
    }
    ColumnLayout {
        id: signInContent
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
    MokaidMenu {
        id: accountMenu
        objectName: "accountActionsMenu"
        MokaidMenu.Entry { text: "Your profile"; onTriggered: features.navigate("profile") }
        MokaidMenu.Entry { text: "Members"; onTriggered: features.navigate("members") }
        MokaidMenu.Entry { text: "Integrations"; onTriggered: features.navigate("integrations") }
        MokaidMenu.Entry { text: "Billing"; onTriggered: features.navigate("billing") }
        MokaidMenu.Separator {}
        MokaidMenu.Entry { text: "Desktop preferences…"; onTriggered: preferences.open() }
        MokaidMenu.Entry { text: "Run a project locally…"; onTriggered: projects.open() }
        MokaidMenu.Entry { text: "Check for updates…"; onTriggered: updates.checkForUpdates() }
        MokaidMenu.Entry { text: "Export diagnostics…"; onTriggered: diagnosticsFile.open() }
        MokaidMenu.Entry { text: "Local profiler…"; onTriggered: profilerDialog.open() }
        MokaidMenu.Entry { text: "Create workspace…"; enabled: session.online; onTriggered: activityPanels.openWorkspace() }
        MokaidMenu.Entry { text: "Close all deliverables…"; enabled: window.previewsRetained; onTriggered: discardPreviews.open() }
        MokaidMenu.Separator {}
        MokaidMenu.Entry { text: "Sign out"; onTriggered: signOutDialog.open() }
    }
    ActionDialog { id: actionDialog }
    ActivityPanels { id: activityPanels; anchors.fill: parent }
    ProjectPanel { id: projects }
    Rectangle {
        id: completionToast; property var notification: ({})
        visible: false; z: 30; width: Math.min(460, window.width - 40); height: toastBody.implicitHeight + 32
        anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 24
        radius: 16; color: Theme.surface; border.color: Theme.selectedBorder
        ColumnLayout {
            id: toastBody; anchors.fill: parent; anchors.margins: 16; spacing: 10
            RowLayout {
                Layout.fillWidth: true
                MokaidIcon { name: "bell"; color: Theme.primary }
                MokaidLabel { Layout.fillWidth: true; text: completionToast.notification.title || "Mission update"; font.weight: Font.DemiBold; wrapMode: Text.Wrap; Accessible.role: Accessible.AlertMessage }
                MokaidIconButton { iconName: "close"; hint: "Dismiss notification"; onClicked: completionToast.visible = false }
            }
            MokaidLabel { Layout.fillWidth: true; text: completionToast.notification.body || "Your agent has an update for you."; color: Theme.secondary; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight }
            MokaidButton { text: completionToast.notification.kind === "ai_run_completed" ? "View result" : "View mission"; iconName: "arrow-right"; Layout.alignment: Qt.AlignRight; onClicked: { missions.close(); preview.visible = false; activity.openNotification(completionToast.notification.id); completionToast.visible = false; window.showNormal(); window.requestActivate() } }
        }
    }
    Timer { id: completionTimer; interval: 14000; onTriggered: completionToast.visible = false }
    MokaidDialog {
        id: signOutDialog; anchors.centerIn: parent; modal: true; title: "Sign out of Mokaid?"
        standardButtons: Dialog.Ok | Dialog.Cancel
        MokaidLabel { text: "Local drafts and open deliverables will be closed.\nYour desktop session will be revoked."; color: Theme.secondary }
        onAccepted: session.signOut()
    }
    MokaidDialog {
        id: quitDialog; anchors.centerIn: parent; modal: true; title: "Close Mokaid?"
        standardButtons: Dialog.Discard | Dialog.Cancel
        MokaidLabel { text: "There are drafts, forms, downloads, or deliverables still open.\nDiscard this local work, cancel downloads, and quit?"; color: Theme.secondary }
        onDiscarded: { window.quitting = true; window.close() }
    }
    MokaidDialog {
        id: discardPreviews; anchors.centerIn: parent; modal: true; title: "Close all deliverables?"
        standardButtons: Dialog.Discard | Dialog.Cancel
        MokaidLabel { text: "Unsaved form entries inside deliverables will be lost."; color: Theme.secondary }
        onDiscarded: preview.clear()
    }
    MokaidDialog {
        id: notice; property string text: ""; anchors.centerIn: parent; modal: true; title: "Mokaid"; width: 460
        standardButtons: Dialog.Ok
        MokaidLabel { width: parent.width; text: notice.text; wrapMode: Text.Wrap; color: Theme.secondary }
    }
    MokaidDialog {
        id: preferences; anchors.centerIn: parent; modal: true; title: "Desktop preferences"; width: 500; standardButtons: Dialog.Close
        ColumnLayout {
            width: parent.width; spacing: 16
            MokaidLabel { text: "3D quality"; color: Theme.secondary }
            MokaidComboBox { model: ["auto", "high", "medium", "low"]; currentIndex: model.indexOf(system.quality); onActivated: system.quality = currentText; Layout.fillWidth: true }
            CheckBox { text: "Reduce interface animations"; checked: system.reducedMotion; onToggled: system.reducedMotion = checked }
            CheckBox { text: "Play a sound when a mission finishes"; checked: system.missionSound; onToggled: system.missionSound = checked }
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
        onAccepted: { if (!system.exportDiagnostics(selectedFile, desktopShell.diagnostics, profiler.metrics)) { notice.text = system.error; notice.open() } }
    }
    MokaidDialog {
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
