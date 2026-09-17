import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

MokaidDialog {
    id: root; title: "Run a project locally"; modal: false
    width: Math.min(parent.width - 48, 700); height: Math.min(parent.height - 48, 640)
    anchors.centerIn: parent
    standardButtons: Dialog.Close
    ColumnLayout {
        anchors.fill: parent; spacing: 14
        MokaidLabel { Layout.fillWidth: true; text: "Download and extract your agent’s project, then choose its folder. The preview opens after the server responds on port 3000."; wrapMode: Text.Wrap; color: Theme.secondary }
        RowLayout {
            Layout.fillWidth: true
            MokaidButton { text: "Choose project folder…"; iconName: "folder"; enabled: !projectRuntime.busy; onClicked: folderPicker.open() }
            MokaidLabel { Layout.fillWidth: true; text: projectRuntime.name || "Next.js or Vite"; elide: Text.ElideRight; color: Theme.secondary }
        }
        MokaidLabel { visible: !!projectRuntime.folder; Layout.fillWidth: true; text: projectRuntime.folder; elide: Text.ElideMiddle; color: Theme.muted; font.pixelSize: 11 }
        CheckBox { id: install; text: "Install dependencies before starting"; checked: true; enabled: !projectRuntime.busy }
        MokaidLabel { Layout.fillWidth: true; text: "Starting executes this project and its dependency scripts on your computer. Only run code you trust. Mokaid stops the server when you stop it, sign out, switch workspaces, or quit."; color: Theme.secondary; wrapMode: Text.Wrap; font.pixelSize: 12 }
        RowLayout {
            Layout.fillWidth: true; spacing: 12
            MokaidButton { text: projectRuntime.state === "installing" ? "Installing…" : projectRuntime.state === "starting" ? "Starting…" : "Start project"; highlighted: true; enabled: !!projectRuntime.folder && !projectRuntime.busy; onClicked: projectRuntime.start(install.checked) }
            MokaidButton { text: "Stop"; enabled: projectRuntime.busy && projectRuntime.state !== "stopping"; onClicked: projectRuntime.stop() }
            Item { Layout.fillWidth: true }
            MokaidButton { text: "Open preview"; iconName: "external-link"; enabled: projectRuntime.state === "running"; onClicked: projectRuntime.openBrowser() }
        }
        MokaidLabel { visible: projectRuntime.state === "running"; text: "Ready at http://127.0.0.1:3000"; color: Theme.success; Accessible.role: Accessible.AlertMessage }
        MokaidLabel { Layout.fillWidth: true; visible: !!projectRuntime.error; text: projectRuntime.error; color: Theme.warning; wrapMode: Text.Wrap }
        ScrollView {
            Layout.fillWidth: true; Layout.fillHeight: true; clip: true
            MokaidTextArea { text: projectRuntime.output || "Server output will appear here."; readOnly: true; wrapMode: TextEdit.Wrap; Accessible.name: "Local development server output"; font.pixelSize: 11 }
        }
    }
    FolderDialog { id: folderPicker; title: "Choose the extracted project folder"; onAccepted: projectRuntime.inspect(selectedFolder) }
}
