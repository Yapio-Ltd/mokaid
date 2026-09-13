import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root; color: Theme.background
    property int replacementIndex: -1
    property var activeView: preview.activeIndex === 0 ? first.item : second.item
    function loader(index) { return index === 0 ? first : second }
    function syncViews() {
        first.active = preview.documents[0] !== null
        second.active = preview.documents[1] !== null
    }
    function replace() {
        const target = loader(replacementIndex)
        target.active = false
        Qt.callLater(function() { preview.commitOpen(); syncViews() })
        replacementIndex = -1
    }
    Connections {
        target: preview
        function onChanged() { root.syncViews() }
        function onReplacementRequested(index) {
            root.replacementIndex = index
            const view = root.loader(index).item
            if (!view) { root.replace(); return }
            view.inspectActivity(function(protectedWork) {
                if (protectedWork) replaceDialog.open()
                else root.replace()
            })
        }
        function onClearViewsRequested() {
            first.active = false; second.active = false
            Qt.callLater(function() { preview.commitClear() })
        }
    }
    ColumnLayout {
        anchors.fill: parent; spacing: 0
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 56; color: Theme.surface
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16; spacing: 10
                ToolButton { text: "←"; enabled: root.activeView && root.activeView.canGoBack; Accessible.name: "Back in deliverable"; onClicked: root.activeView.goBack() }
                MokaidLabel { text: root.activeView ? root.activeView.document.title : "Deliverable"; color: Theme.text; font.bold: true; Layout.fillWidth: true; elide: Text.ElideRight }
                MokaidLabel { text: root.activeView ? root.activeView.document.version : ""; color: Theme.muted }
                ToolButton { text: "↻"; enabled: !!root.activeView; Accessible.name: "Reload deliverable"; onClicked: reloadDialog.open() }
                MokaidButton { text: "Open Files in browser"; onClicked: preview.openInBrowser() }
                ToolButton { text: "×"; Accessible.name: "Return to workspace, keeping this deliverable"; onClicked: preview.visible = false }
            }
        }
        TabBar {
            Layout.fillWidth: true; currentIndex: preview.activeIndex
            TabButton { text: preview.documents[0] ? preview.documents[0].title : "Deliverable"; enabled: !!preview.documents[0]; onClicked: preview.activate(0) }
            TabButton { text: preview.documents[1] ? preview.documents[1].title : ""; visible: !!preview.documents[1]; onClicked: preview.activate(1) }
        }
        MokaidLabel { Layout.fillWidth: true; visible: preview.error.length > 0; text: preview.error; color: Theme.warning; wrapMode: Text.Wrap; padding: 12 }
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true
            Loader {
                id: first; anchors.fill: parent; active: false; visible: preview.activeIndex === 0
                sourceComponent: DeliveryView { document: preview.documents[0]; active: root.visible && preview.activeIndex === 0 }
            }
            Loader {
                id: second; anchors.fill: parent; active: false; visible: preview.activeIndex === 1
                sourceComponent: DeliveryView { document: preview.documents[1]; active: root.visible && preview.activeIndex === 1 }
            }
            BusyIndicator { anchors.centerIn: parent; running: preview.loading; visible: running }
        }
    }
    Dialog {
        id: replaceDialog; anchors.centerIn: parent; modal: true; title: "Replace the retained deliverable?"
        width: 470; standardButtons: Dialog.Discard | Dialog.Cancel
        MokaidLabel { width: parent.width; text: "This deliverable has form entries or activity in progress. Replacing it will discard that local state. You can cancel and return to it."; wrapMode: Text.Wrap; color: Theme.secondary }
        onDiscarded: root.replace()
        onRejected: { root.replacementIndex = -1; preview.cancelOpen() }
    }
    Dialog {
        id: reloadDialog; anchors.centerIn: parent; modal: true; title: "Reload this deliverable?"; standardButtons: Dialog.Ok | Dialog.Cancel
        MokaidLabel { text: "Unsaved form entries in this deliverable will be lost."; color: Theme.secondary }
        onAccepted: if (root.activeView) root.activeView.reload()
    }
}
