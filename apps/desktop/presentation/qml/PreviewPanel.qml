import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    color: Theme.background
    signal filesRequested()
    property int replacementIndex: -1
    property double replacementRevision: -1
    property double reloadRevision: -1
    property var reloadTarget: null
    property var activeView: preview.activeIndex === 0 ? first.item : second.item
    readonly property var currentDocument: preview.documents[preview.activeIndex]
    readonly property var currentFile: currentDocument ? currentDocument.file : preview.failedFile
    readonly property bool failedFileCanDownload: !!preview.failedFile.id && (preview.failedFile.size_bytes || 0) <= 32 * 1024 * 1024
    readonly property bool collection: preview.collectionCount > 1
    readonly property var downloadManager: typeof features !== "undefined" ? features.driveDownload : null
    function loader(index) { return index === 0 ? first : second }
    function syncViews() {
        first.active = preview.documents[0] !== null
        second.active = preview.documents[1] !== null
    }
    function replace() {
        const revision = replacementRevision
        const index = replacementIndex
        if (index < 0 || revision !== preview.openRevision) return
        const target = loader(index)
        target.active = false
        Qt.callLater(function() {
            if (revision === preview.openRevision) preview.commitOpen()
            syncViews()
        })
        replacementIndex = -1
    }
    function reloadCurrent() {
        if (!activeView) return
        const view = activeView
        const revision = preview.openRevision
        view.inspectActivity(function(protectedWork) {
            if (revision !== preview.openRevision || view !== root.activeView) return
            if (protectedWork) {
                root.reloadTarget = view; root.reloadRevision = revision
                reloadDialog.open()
            } else view.reload()
        })
    }
    Shortcut { sequence: "Escape"; enabled: root.visible && !replaceDialog.visible && !reloadDialog.visible; onActivated: preview.visible = false }
    Shortcut { sequence: "Alt+Left"; enabled: root.visible && root.collection && !preview.loading; onActivated: preview.previous() }
    Shortcut { sequence: "Alt+Right"; enabled: root.visible && root.collection && !preview.loading; onActivated: preview.next() }
    Connections {
        target: preview
        function onChanged() {
            if (root.replacementIndex >= 0 && root.replacementRevision !== preview.openRevision) {
                root.replacementIndex = -1
                replaceDialog.close()
            }
            if (reloadDialog.visible && root.reloadRevision !== preview.openRevision) reloadDialog.close()
            root.syncViews()
        }
        function onReplacementRequested(index) {
            root.replacementIndex = index
            const revision = preview.openRevision
            root.replacementRevision = revision
            const view = root.loader(index).item
            if (!view) { root.replace(); return }
            view.inspectActivity(function(protectedWork) {
                if (revision !== preview.openRevision || root.replacementIndex !== index || root.loader(index).item !== view) return
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
            Layout.fillWidth: true; Layout.preferredHeight: 76
            color: Theme.surface
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.divider }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16; spacing: 10
                MokaidButton { iconName: "chevron-left"; quiet: true; Accessible.name: "Return to workspace"; onClicked: preview.visible = false; ToolTip.visible: hovered; ToolTip.text: "Back · Esc"; ToolTip.delay: 500 }
                ColumnLayout {
                    Layout.fillWidth: true; Layout.minimumWidth: 60; spacing: 4
                    MokaidLabel { Layout.fillWidth: true; text: root.currentFile.name || "Deliverable"; font.weight: Font.DemiBold; font.pixelSize: 15; elide: Text.ElideMiddle }
                    MokaidLabel { Layout.fillWidth: true; text: root.currentFile.id ? [preview.describe(root.currentFile).label, preview.describe(root.currentFile).sizeLabel].filter(function(value) { return !!value }).join(" · ") : "Opening preview…"; color: Theme.secondary; font.pixelSize: 11; elide: Text.ElideRight }
                }
                RowLayout {
                    visible: root.collection; spacing: 2
                    MokaidButton { objectName: "previousDeliverable"; iconName: "chevron-left"; quiet: true; enabled: preview.collectionIndex > 0 && !preview.loading; Accessible.name: "Previous deliverable"; onClicked: preview.previous() }
                    MokaidLabel { text: (preview.collectionIndex + 1) + " / " + preview.collectionCount; color: Theme.secondary; font.pixelSize: 12 }
                    MokaidButton { objectName: "nextDeliverable"; iconName: "chevron-right"; quiet: true; enabled: preview.collectionIndex < preview.collectionCount - 1 && !preview.loading; Accessible.name: "Next deliverable"; onClicked: preview.next() }
                }
                MokaidButton { objectName: "downloadDeliverable"; iconName: "download"; text: root.width > 620 ? "Download" : ""; enabled: (!!root.currentDocument || root.failedFileCanDownload) && !preview.loading && !(root.downloadManager && root.downloadManager.busy); Accessible.name: "Download original file"; onClicked: root.currentDocument ? preview.downloadCurrent() : preview.downloadFailed() }
                MokaidButton { objectName: "showNativeFiles"; iconName: "folder"; text: root.width > 850 ? "Show Files" : ""; quiet: true; Accessible.name: "Show Files"; onClicked: root.filesRequested(); ToolTip.visible: hovered; ToolTip.text: "Show Files"; ToolTip.delay: 500 }
                MokaidButton { objectName: "previewActionsButton"; iconName: "more"; quiet: true; Accessible.name: "More preview actions"; onClicked: previewMenu.openFor(this) }
            }
        }
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: recentRow.implicitHeight + 12
            visible: !root.collection && !!preview.documents[1]
            color: Theme.background
            RowLayout {
                id: recentRow; anchors.left: parent.left; anchors.right: parent.right; anchors.margins: 16; anchors.verticalCenter: parent.verticalCenter; spacing: 6
                MokaidLabel { text: "Open"; color: Theme.muted; font.pixelSize: 11; Layout.rightMargin: 6 }
                Repeater {
                    model: 2
                    MokaidButton {
                        required property int index
                        readonly property var retainedDocument: preview.documents[index]
                        Layout.maximumWidth: Math.max(100, (root.width - 100) / 2)
                        text: retainedDocument ? retainedDocument.title : ""
                        visible: !!retainedDocument; highlighted: index === preview.activeIndex; quiet: !highlighted
                        implicitHeight: 34
                        onClicked: preview.activate(index)
                    }
                }
                Item { Layout.fillWidth: true }
            }
        }
        MokaidLabel {
            Layout.fillWidth: true; visible: !!root.downloadManager && !!(root.downloadManager.error || root.downloadManager.status)
            text: root.downloadManager ? root.downloadManager.error || root.downloadManager.status : ""
            color: root.downloadManager && root.downloadManager.error ? Theme.warning : Theme.secondary; wrapMode: Text.Wrap; padding: 12; font.pixelSize: 12
        }
        RowLayout {
            Layout.fillWidth: true; Layout.margins: 12; visible: preview.error.length > 0 && !!root.currentDocument
            MokaidLabel { Layout.fillWidth: true; text: (preview.failedFile.name ? preview.failedFile.name + " · " : "") + preview.error; color: Theme.warning; wrapMode: Text.Wrap; font.pixelSize: 12 }
            MokaidButton { text: "Try again"; visible: !!preview.failedFile.id; enabled: !preview.loading; onClicked: preview.retryFailed() }
            MokaidButton { iconName: "download"; visible: root.failedFileCanDownload; enabled: !preview.loading; Accessible.name: "Download " + (preview.failedFile.name || "file"); onClicked: preview.downloadFailed() }
        }
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true; clip: true
            Loader {
                id: first; anchors.fill: parent; active: false; visible: preview.activeIndex === 0 && !preview.loading
                sourceComponent: DeliveryView { document: preview.documents[0]; active: root.visible && preview.activeIndex === 0 && !preview.loading }
            }
            Loader {
                id: second; anchors.fill: parent; active: false; visible: preview.activeIndex === 1 && !preview.loading
                sourceComponent: DeliveryView { document: preview.documents[1]; active: root.visible && preview.activeIndex === 1 && !preview.loading }
            }
            ColumnLayout {
                anchors.centerIn: parent; spacing: 14; visible: preview.loading
                BusyIndicator { Layout.alignment: Qt.AlignHCenter; running: preview.loading }
                MokaidLabel { text: "Opening preview…"; color: Theme.secondary; font.pixelSize: 13 }
            }
            ColumnLayout {
                anchors.centerIn: parent; width: Math.min(parent.width - 48, 420); spacing: 16
                visible: !root.currentDocument && !preview.loading && preview.error.length > 0
                MokaidIcon { name: "file"; size: 34; Layout.alignment: Qt.AlignHCenter }
                MokaidLabel { Layout.fillWidth: true; text: "Preview unavailable"; font.pixelSize: 21; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter }
                MokaidLabel { Layout.fillWidth: true; text: preview.error; color: Theme.secondary; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter }
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter; spacing: 10
                    MokaidButton { text: "Try again"; highlighted: true; visible: !!preview.failedFile.id; onClicked: preview.retryFailed() }
                    MokaidButton { text: "Download"; iconName: "download"; visible: root.failedFileCanDownload; onClicked: preview.downloadFailed() }
                }
            }
        }
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 88; visible: root.collection; color: Theme.surface
            Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.divider }
            ListView {
                id: filmstrip
                anchors.fill: parent; anchors.margins: 12
                orientation: ListView.Horizontal; spacing: 8; clip: true
                model: preview.collectionFiles
                currentIndex: preview.collectionIndex
                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                delegate: AbstractButton {
                    id: filmItem
                    required property var modelData
                    required property int index
                    readonly property var description: preview.describe(modelData)
                    readonly property bool selected: index === preview.collectionIndex
                    width: 72; height: 62; hoverEnabled: true
                    enabled: !preview.loading
                    Accessible.name: "Open " + modelData.name
                    Accessible.role: Accessible.Button
                    Accessible.description: selected ? "Current deliverable" : "Deliverable " + (index + 1)
                    background: Rectangle { color: filmItem.hovered ? Theme.hover : Theme.control; radius: 9; border.width: filmItem.selected || filmItem.visualFocus ? 2 : 1; border.color: filmItem.visualFocus ? Theme.focusBorder : filmItem.selected ? Theme.primary : Theme.divider }
                    contentItem: Item {
                        Image { anchors.fill: parent; anchors.margins: 5; fillMode: Image.PreserveAspectFit; asynchronous: true; visible: filmItem.description.kind === "image"; source: { const revision = preview.thumbnailRevision; return visible ? preview.thumbnailUrl(filmItem.modelData) : "" } }
                        Column {
                            anchors.centerIn: parent; spacing: 3; visible: filmItem.description.kind !== "image"
                            MokaidIcon { anchors.horizontalCenter: parent.horizontalCenter; name: filmItem.description.kind === "video" ? "play" : filmItem.description.kind === "audio" ? "headphones" : "file"; size: 20 }
                            MokaidLabel { anchors.horizontalCenter: parent.horizontalCenter; text: filmItem.description.extension; font.pixelSize: 9; color: Theme.secondary }
                        }
                    }
                    onClicked: preview.openCollection(preview.collectionFiles, index)
                    ToolTip.visible: hovered; ToolTip.delay: 500; ToolTip.text: modelData.name
                }
                ScrollBar.horizontal: ScrollBar { height: 3 }
            }
        }
    }
    MokaidMenu {
        id: previewMenu
        objectName: "previewActionsMenu"
        Action { text: "Reload preview"; enabled: !!root.activeView && root.currentDocument.kind !== "image" && root.currentDocument.kind !== "unsupported"; onTriggered: root.reloadCurrent() }
        Action { text: "Back in document"; enabled: !!root.activeView && root.activeView.canGoBack; onTriggered: root.activeView.goBack() }
        Action { text: "Quick Look"; enabled: !!root.currentDocument && preview.nativePreviewAvailable; onTriggered: preview.openNativePreview() }
        Action { text: "Close preview"; onTriggered: preview.visible = false }
    }
    Dialog {
        id: replaceDialog; objectName: "replacePreviewDialog"; anchors.centerIn: parent; modal: true; title: "Replace the retained deliverable?"
        implicitWidth: 500
        width: Math.max(320, Math.min(root.width - 80, implicitWidth)); standardButtons: Dialog.Discard | Dialog.Cancel; padding: 24
        background: Rectangle { radius: Theme.radiusDialog; border.color: Theme.selectedBorder; gradient: Gradient { GradientStop { position: 0; color: Theme.panelTop } GradientStop { position: 1; color: Theme.panelBottom } } }
        // Measure wrapped title and body together. A separately wrapped popup
        // header feeds its allocated geometry back into Qt's implicit height.
        header: null
        footer: DialogButtonBox { standardButtons: replaceDialog.standardButtons; padding: 24; topPadding: 12; spacing: 10; delegate: MokaidButton {} background: Item {} }
        contentItem: Column {
            width: replaceDialog.width - replaceDialog.leftPadding - replaceDialog.rightPadding; spacing: 16
            MokaidLabel { width: parent.width; text: replaceDialog.title; font.pixelSize: 21; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
            MokaidLabel { width: parent.width; text: "This deliverable has form entries or activity in progress. Replacing it will discard that local state. You can cancel and return to it."; wrapMode: Text.Wrap; color: Theme.secondary }
        }
        onDiscarded: root.replace()
        onRejected: { root.replacementIndex = -1; preview.cancelOpen() }
    }
    Dialog {
        id: reloadDialog; objectName: "reloadPreviewDialog"; anchors.centerIn: parent; modal: true; title: "Reload this deliverable?"; standardButtons: Dialog.Ok | Dialog.Cancel
        implicitWidth: 500
        width: Math.max(320, Math.min(root.width - 80, implicitWidth)); padding: 24
        background: Rectangle { radius: Theme.radiusDialog; border.color: Theme.selectedBorder; gradient: Gradient { GradientStop { position: 0; color: Theme.panelTop } GradientStop { position: 1; color: Theme.panelBottom } } }
        header: null
        footer: DialogButtonBox { standardButtons: reloadDialog.standardButtons; padding: 24; topPadding: 12; spacing: 10; delegate: MokaidButton {} background: Item {} }
        contentItem: Column {
            width: reloadDialog.width - reloadDialog.leftPadding - reloadDialog.rightPadding; spacing: 16
            MokaidLabel { width: parent.width; text: reloadDialog.title; font.pixelSize: 21; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
            MokaidLabel { width: parent.width; text: "Unsaved form entries in this deliverable will be lost."; color: Theme.secondary; wrapMode: Text.Wrap }
        }
        onAccepted: if (root.reloadTarget && root.reloadRevision === preview.openRevision && root.reloadTarget === root.activeView) root.reloadTarget.reload()
    }
}
