pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

ColumnLayout {
    id: root
    required property var controller
    spacing: 10
    RowLayout {
        Layout.fillWidth: true; spacing: 8
        MokaidButton {
            objectName: "driveBack"
            text: "Back"; iconName: "chevron-left"; enabled: root.controller.driveCanGoBack
            Accessible.name: "Back to the previous folder"
            onClicked: root.controller.driveBack()
        }
        ListView {
            id: breadcrumbs
            Layout.fillWidth: true; Layout.preferredHeight: 44
            model: root.controller.driveBreadcrumbs
            orientation: ListView.Horizontal; clip: true; reuseItems: true; spacing: 4
            onCountChanged: positionViewAtEnd()
            delegate: MokaidButton {
                required property var modelData
                required property int index
                objectName: "driveBreadcrumb" + index
                text: modelData.name; width: Math.min(200, implicitWidth); quiet: !highlighted
                Accessible.name: "Open folder " + modelData.name
                highlighted: !root.controller.driveTrash && index === breadcrumbs.count - 1
                onClicked: root.controller.navigateDriveBreadcrumb(index)
            }
            ScrollBar.horizontal: ScrollBar {}
        }
        MokaidButton {
            objectName: "driveTrash"
            text: root.controller.driveTrash ? "Return to files" : "Trash"
            highlighted: root.controller.driveTrash
            onClicked: root.controller.setDriveTrash(!root.controller.driveTrash)
        }
        MokaidButton {
            objectName: "driveDownload"
            text: "Save file…"; iconName: "file"
            enabled: root.controller.driveCanDownload && !root.controller.driveDownload.busy
            Accessible.description: "Save the selected file locally. Maximum size: 32 MiB."
            onClicked: root.controller.requestDriveDownload()
        }
    }
    RowLayout {
        Layout.fillWidth: true
        MokaidLabel {
            Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12
            text: root.controller.driveDownload.error || root.controller.driveDownload.status
                  || (root.controller.driveTrash ? "Trash · select an item to restore it." : "Open a folder to browse it. Native downloads: up to 32 MiB.")
            color: root.controller.driveDownload.error ? Theme.warning : Theme.secondary
        }
        MokaidButton {
            text: "Cancel download"; visible: root.controller.driveDownload.busy
            onClicked: root.controller.driveDownload.cancel()
        }
    }
    FileDialog {
        id: saveDialog
        objectName: "driveSaveDialog"
        property string transaction: ""
        title: "Save file"
        fileMode: FileDialog.SaveFile
        // Keep Qt's overwrite confirmation enabled (DontConfirmOverwrite is NOT set).
        onAccepted: root.controller.driveDownload.save(transaction, selectedFile)
        onRejected: root.controller.driveDownload.cancel(transaction)
    }
    Connections {
        target: root.controller.driveDownload
        function onSaveRequested(transaction, suggestedFile) {
            saveDialog.transaction = transaction
            saveDialog.selectedFile = suggestedFile
            saveDialog.open()
        }
        function onChanged() {
            if (saveDialog.visible && saveDialog.transaction !== root.controller.driveDownload.pendingTransaction)
                saveDialog.close()
        }
    }
}
