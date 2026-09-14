pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    signal actionRequested(var action)
    ColumnLayout {
        anchors.fill: parent; anchors.margins: 28; spacing: 20
        RowLayout {
            ColumnLayout {
                Layout.fillWidth: true
                MokaidLabel { text: features.title; font.pixelSize: 28; font.bold: true; color: Theme.text }
                MokaidLabel { text: features.offline ? "Saved data · offline · changes require a connection" : "Your workspace, in sync"; color: Theme.secondary }
            }
            MokaidButton { text: "Refresh"; enabled: !features.busy; onClicked: features.refresh() }
            MokaidButton { text: "Overview"; enabled: !features.busy; onClicked: features.showOverview() }
            MokaidTextField { placeholderText: "Filter this view…"; Layout.preferredWidth: 180; onTextEdited: features.search(text); Accessible.name: "Filter this view" }
            Repeater {
                model: features.actions
                MokaidButton {
                    required property var modelData
                    visible: !modelData.selection && (modelData.id === "create" || modelData.id === "invite" || modelData.id === "upload" || modelData.id === "edit")
                    text: modelData.title; highlighted: true; enabled: modelData.enabled
                    onClicked: root.actionRequested(modelData)
                }
            }
            ToolButton { text: "⋯"; Accessible.name: "View actions"; onClicked: viewActions.popup() }
        }
        DriveNavigation { Layout.fillWidth: true; visible: features.currentPage === "drive"; controller: features }
        MokaidLabel { Layout.fillWidth: true; visible: features.error.length > 0; text: features.error; wrapMode: Text.Wrap; color: Theme.warning }
        SplitView {
            Layout.fillWidth: true; Layout.fillHeight: true; orientation: Qt.Horizontal
            Rectangle {
                SplitView.fillWidth: true; SplitView.minimumWidth: 300
                color: Theme.surface; radius: 12; border.color: Theme.border
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 1; spacing: 0
                    RowLayout {
                        Layout.fillWidth: true; Layout.preferredHeight: 42; Layout.leftMargin: 18; Layout.rightMargin: 18
                        MokaidLabel { text: "NAME"; color: Theme.muted; font.pixelSize: 10; font.bold: true; Layout.fillWidth: true }
                        MokaidLabel { text: "STATUS"; color: Theme.muted; font.pixelSize: 10; font.bold: true; Layout.preferredWidth: 100 }
                    }
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.border }
                    ListView {
                        id: records; Layout.fillWidth: true; Layout.fillHeight: true; model: features.records; clip: true
                        reuseItems: true
                        delegate: ItemDelegate {
                            required property string rowId
                            required property string title
                            required property string subtitle
                            required property string status
                            required property var record
                            width: records.width; height: 68
                            highlighted: features.selectedId === rowId
                            background: Rectangle { color: parent.highlighted ? "#252037" : parent.hovered ? Theme.hover : "transparent" }
                            contentItem: RowLayout {
                                spacing: 16
                                Rectangle { Layout.preferredWidth: 34; Layout.preferredHeight: 34; radius: 9; color: "#29243b"; MokaidLabel { anchors.centerIn: parent; text: title.slice(0, 1).toUpperCase(); color: "#b3a0ff"; font.bold: true } }
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 4
                                    MokaidLabel { text: title; color: Theme.text; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                                    MokaidLabel { text: subtitle; color: Theme.secondary; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
                                }
                                MokaidLabel { text: status; color: status === "active" || status === "completed" ? Theme.success : Theme.secondary; Layout.preferredWidth: 100; elide: Text.ElideRight; font.pixelSize: 11 }
                            }
                            onClicked: features.select(rowId)
                            onDoubleClicked: {
                                features.select(rowId)
                                if (features.currentPage === "agents") { office.selectAgent(rowId); features.navigate("office") }
                                else if (features.currentPage === "drive" && !features.driveTrash) {
                                    if (record.kind === "folder") features.openDriveFolder(rowId)
                                    else preview.openFile(record)
                                }
                            }
                            Keys.onReturnPressed: {
                                features.select(rowId)
                                if (features.currentPage === "drive" && record.kind === "folder") features.openDriveFolder(rowId)
                            }
                        }
                        MokaidLabel { anchors.centerIn: parent; visible: records.count === 0 && !features.busy; text: features.offline ? "No saved data for this view." : "Nothing here yet."; color: Theme.secondary }
                        footer: MokaidButton { visible: features.hasMore; text: features.busy ? "Loading…" : "Load more"; enabled: !features.busy; width: records.width; onClicked: features.loadMore() }
                        ScrollBar.vertical: ScrollBar {}
                    }
                }
            }
            Rectangle {
                visible: features.detailView.available
                SplitView.preferredWidth: 460; SplitView.minimumWidth: 320
                color: Theme.surface; radius: 12; border.color: Theme.border
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 18; spacing: 12
                    RowLayout {
                        ToolButton { text: "←"; visible: features.detailView.canGoBack; Accessible.name: "Back in details"; onClicked: features.detailView.goBack() }
                        MokaidLabel { text: features.detailView.heading; font.bold: true; color: Theme.text; elide: Text.ElideRight; Layout.fillWidth: true }
                        MokaidButton { text: "Record"; visible: features.selectedId.length > 0; onClicked: features.showRecordDetails() }
                        ToolButton { text: "×"; Accessible.name: "Close details"; onClicked: features.clearSelection() }
                    }
                    Flow {
                        Layout.fillWidth: true; spacing: 4
                        Repeater {
                            model: features.detailView.breadcrumbs
                            ToolButton {
                                id: breadcrumbButton
                                required property var modelData
                                text: modelData.label
                                contentItem: MokaidLabel { text: breadcrumbButton.text; color: Theme.secondary; elide: Text.ElideRight }
                                implicitWidth: Math.min(160, contentItem.implicitWidth + 16)
                                Accessible.name: "Open detail section " + modelData.label
                                onClicked: features.detailView.goTo(modelData.depth)
                            }
                        }
                    }
                    ListView {
                        id: detailRows
                        Layout.fillWidth: true; Layout.fillHeight: true
                        model: features.detailView.rows; clip: true; reuseItems: true; spacing: 8
                        delegate: Rectangle {
                            required property string rowId
                            required property string title
                            required property var record
                            width: detailRows.width; height: detailContent.implicitHeight + 24
                            color: record.container ? Theme.hover : "transparent"; radius: 8
                            ColumnLayout {
                                id: detailContent
                                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                                anchors.margins: 12; spacing: 8
                                MokaidLabel { Layout.fillWidth: true; text: title; wrapMode: Text.Wrap; color: Theme.muted; font.pixelSize: 11; font.bold: true }
                                TextEdit {
                                    Layout.fillWidth: true
                                    text: record.text || ""; readOnly: true; selectByMouse: true
                                    wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText; color: Theme.text
                                    Accessible.name: title
                                }
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    visible: record.expandable || record.fileAvailable || (record.referencePage || "").length > 0
                                    MokaidButton { text: record.container ? "Explore" : "Read full text"; visible: record.expandable; onClicked: features.detailView.enter(rowId) }
                                    MokaidButton { text: "Open record"; visible: (record.referencePage || "").length > 0; onClicked: features.detailView.openReference(rowId) }
                                    MokaidButton { text: "Open deliverable"; visible: record.fileAvailable; onClicked: features.detailView.openFile(rowId) }
                                }
                            }
                        }
                        MokaidLabel { anchors.centerIn: parent; width: parent.width - 24; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; visible: detailRows.count === 0; text: "No visible fields or items in this section."; color: Theme.secondary }
                        ScrollBar.vertical: ScrollBar {}
                    }
                    Flow {
                        Layout.fillWidth: true; spacing: 6
                        Repeater {
                            model: features.actions
                            MokaidButton { required property var modelData; visible: modelData.selection; text: modelData.title; enabled: modelData.enabled; onClicked: root.actionRequested(modelData) }
                        }
                    }
                }
            }
        }
        BusyIndicator { running: features.busy; visible: running; Layout.preferredHeight: 24; Layout.preferredWidth: 24; Layout.alignment: Qt.AlignHCenter }
    }
    Menu {
        id: viewActions
        Repeater {
            model: features.actions
            MenuItem { required property var modelData; visible: !modelData.selection; text: modelData.title; enabled: modelData.enabled; onTriggered: root.actionRequested(modelData) }
        }
    }
}
