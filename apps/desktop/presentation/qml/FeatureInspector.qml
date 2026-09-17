pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQml.Models
import "FeatureLogic.js" as Logic

Rectangle {
    id: root
    required property string page
    property bool browserMode: false
    property bool taskMetadataExpanded: false
    signal closeRequested()
    signal actionRequested(var action)
    signal returnToRecord()
    readonly property var currentRecord: features.selectedRecord
    readonly property bool inspecting: browserMode || features.detailView.canGoBack || (!features.showingRecordDetails && features.selectedId.length>0)
    readonly property var fields: Logic.details(page,currentRecord)
    readonly property var selectionActions: features.actions.filter(function(a){return a.selection;})
    readonly property string taskRunState: page==="tasks" ? Logic.taskRunState(currentRecord) : ""
    readonly property var taskQuickActions: page!=="tasks" ? [] : selectionActions.filter(function(action){
        if(action.id==="comment" || action.id==="runs") return true;
        if(action.id==="stop") return root.taskRunState==="running";
        if(action.id==="run") return root.taskRunState!=="running" && root.taskRunState!=="approval" && !!root.currentRecord.assigned_agent_id && root.currentRecord.assigned_agent_kind!=="human_linked" && ["completed","canceled"].indexOf(root.currentRecord.status)<0;
        return false;
    })
    onCurrentRecordChanged: taskMetadataExpanded=false
    readonly property var primarySelectedAction: {
        const preferred = page==="drive" ? (currentRecord.kind==="folder" ? "children" : "open") : page==="integrations" ? (currentRecord.installation_id ? "uninstall" : "install") : "edit";
        return selectionActions.find(function(a){return a.id===preferred;}) || selectionActions[0] || ({enabled:false,title:""});
    }
    readonly property bool hasDeliverables: features.detailView.deliverables.length>0 && !features.detailView.canGoBack && !(page==="drive" && features.driveTrash)
    color: Theme.surface; border.color: Theme.border; radius: 16
    ColumnLayout {
        anchors.fill: parent; anchors.margins: root.page==="tasks" ? 16 : 20; spacing: root.page==="tasks" ? 14 : 18
        RowLayout {
            Layout.fillWidth: true; spacing: 8
            MokaidButton { iconName: "chevron-left"; quiet: true; visible: features.detailView.canGoBack; Accessible.name: "Back in details"; onClicked: features.detailView.goBack() }
            MokaidLabel { text: root.inspecting ? features.detailView.heading : root.page==="mail" ? "Message" : root.page==="agent-new" ? "Specialization" : "Details"; font.weight: Font.DemiBold; font.pixelSize: 15; elide: Text.ElideRight; Layout.fillWidth: true; color: Theme.secondary }
            MokaidButton { text: "Record"; quiet: true; visible: root.inspecting && features.selectedId.length>0; onClicked: root.returnToRecord() }
            MokaidButton { objectName: root.page==="tasks" ? "taskInspectorClose" : "featureInspectorClose"; iconName: "close"; quiet: true; Accessible.name: "Close details"; onClicked: root.closeRequested() }
        }
        Flow {
            Layout.fillWidth: true; spacing: 3; visible: features.detailView.canGoBack
            Repeater {
                model: features.detailView.breadcrumbs
                MokaidButton { required property var modelData; text: modelData.label; quiet: true; width: Math.min(140,implicitWidth); Accessible.name: "Open detail section "+modelData.label; onClicked: features.detailView.goTo(modelData.depth) }
            }
        }
        ScrollView {
            id: primaryScroll
            visible: !root.inspecting
            Layout.fillWidth: true; Layout.fillHeight: true; contentWidth: availableWidth; clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                width: primaryScroll.availableWidth; spacing: root.page==="tasks" ? 16 : 20
                MokaidLabel { Layout.fillWidth: true; text: Logic.title(root.currentRecord,root.page); font.pixelSize: root.page==="tasks" ? 20 : 23; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
                Flow {
                    Layout.fillWidth: true; spacing: 6
                    Repeater {
                        model: [Logic.status(root.currentRecord,root.page),Logic.human(root.currentRecord.priority)].filter(Boolean)
                        Rectangle { id: statusChip; required property string modelData; width: chip.implicitWidth+18; height: 27; radius: 7; color: Logic.alpha(Theme[Logic.tone(modelData)],0.11); MokaidLabel { id: chip; anchors.centerIn: parent; text: statusChip.modelData; color: Theme[Logic.tone(statusChip.modelData)]; font.pixelSize: 11; font.weight: Font.Medium } }
                    }
                }
                ColumnLayout {
                    visible: root.page==="tasks"; Layout.fillWidth: true; spacing: 10
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        MokaidIcon { name: "agents"; size: 17; color: Theme.secondary }
                        MokaidLabel { Layout.fillWidth: true; text: root.currentRecord.assigned_agent_name || "Unassigned"; color: Theme.secondary; font.pixelSize: 12; wrapMode: Text.Wrap }
                    }
                    RowLayout {
                        visible: !!root.currentRecord.due_at; Layout.fillWidth: true; spacing: 8
                        MokaidIcon { name: "calendar"; size: 17; color: Theme.secondary }
                        MokaidLabel { Layout.fillWidth: true; text: "Due "+Logic.date(root.currentRecord.due_at,true); color: Theme.secondary; font.pixelSize: 12; wrapMode: Text.Wrap }
                    }
                    RowLayout {
                        visible: !!root.currentRecord.project_name; Layout.fillWidth: true; spacing: 8
                        MokaidIcon { name: "projects"; size: 17; color: Theme.secondary }
                        MokaidLabel { Layout.fillWidth: true; text: root.currentRecord.project_name || ""; color: Theme.secondary; font.pixelSize: 12; wrapMode: Text.Wrap }
                    }
                    ColumnLayout {
                        visible: Logic.progress(root.currentRecord)!==null
                        Layout.fillWidth: true; spacing: 7
                        RowLayout {
                            Layout.fillWidth: true
                            MokaidLabel { text: "Progress"; Layout.fillWidth: true; color: Theme.secondary; font.pixelSize: 11 }
                            MokaidLabel { text: Logic.progress(root.currentRecord)+"%"; color: Theme.text; font.pixelSize: 11 }
                        }
                        Rectangle {
                            Layout.fillWidth: true; height: 4; radius: 2; color: Theme.raised
                            Rectangle { width: parent.width*(Logic.progress(root.currentRecord) || 0)/100; height: parent.height; radius: 2; color: root.currentRecord.status==="completed" ? Theme.success : Theme.primary }
                        }
                    }
                    MokaidLabel { Layout.fillWidth: true; text: Logic.taskHint(root.currentRecord); color: root.taskRunState==="failed" ? Theme.danger : root.taskRunState==="approval" ? Theme.warning : Theme.secondary; font.pixelSize: 12; wrapMode: Text.Wrap }
                    Flow {
                        Layout.fillWidth: true; spacing: 6
                        Repeater {
                            model: root.taskQuickActions
                            MokaidButton {
                                required property var modelData
                                objectName: "taskQuick_"+modelData.id
                                text: modelData.id==="run" ? "Start agent" : modelData.id==="runs" ? "Activity" : modelData.id==="comment" ? "Comment" : modelData.title
                                iconName: modelData.id==="run" ? "play" : modelData.id==="runs" ? "pulse" : ""
                                enabled: modelData.enabled; onClicked: root.actionRequested(modelData)
                            }
                        }
                    }
                }
                ColumnLayout {
                    visible: root.page==="tasks" && Logic.body(root.page,root.currentRecord).length>0
                    Layout.fillWidth: true; spacing: 8
                    MokaidLabel { text: "The brief"; font.pixelSize: 13; font.weight: Font.DemiBold }
                    TextEdit { objectName: "taskBrief"; Layout.fillWidth: true; text: root.page==="tasks" ? Logic.body(root.page,root.currentRecord) : ""; readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: 13; selectionColor: Theme.selection; selectedTextColor: Theme.text; Accessible.name: "Task brief" }
                }
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: summary.implicitHeight+28
                    visible: root.page==="mail" && !!root.currentRecord.ai_summary
                    radius: 10; color: Theme.raised
                    ColumnLayout {
                        id: summary
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 14; spacing: 7
                        MokaidLabel { text: "Message summary"; font.pixelSize: 12; font.weight: Font.DemiBold; color: Theme.primary }
                        MokaidLabel { Layout.fillWidth: true; text: root.currentRecord.ai_summary || ""; font.pixelSize: 13; wrapMode: Text.Wrap }
                    }
                }
                DeliveryGallery { Layout.fillWidth: true; visible: root.hasDeliverables; files: root.hasDeliverables && !root.inspecting ? features.detailView.deliverables : [] }
                MokaidButton {
                    visible: root.page==="tasks"; text: root.taskMetadataExpanded ? "Hide task information" : "Task information"
                    quiet: true; iconName: root.taskMetadataExpanded ? "chevron-up" : "chevron-down"; onClicked: root.taskMetadataExpanded=!root.taskMetadataExpanded
                }
                ColumnLayout {
                    visible: root.page!=="tasks" || root.taskMetadataExpanded
                    Layout.fillWidth: true; spacing: 12
                    Repeater {
                        model: root.fields
                        RowLayout {
                            id: propertyRow
                            required property var modelData
                            Layout.fillWidth: true; spacing: 12
                            MokaidLabel { text: propertyRow.modelData.label; Layout.preferredWidth: 94; Layout.alignment: Qt.AlignTop; color: Theme.muted; font.pixelSize: 12; wrapMode: Text.Wrap }
                            MokaidLabel { text: propertyRow.modelData.value; Layout.fillWidth: true; color: Theme.text; font.pixelSize: 12; wrapMode: Text.Wrap }
                        }
                    }
                }
                Rectangle { visible: root.page!=="tasks"; Layout.fillWidth: true; height: 1; color: Theme.divider }
                ColumnLayout {
                    visible: root.page!=="tasks" && Logic.body(root.page,root.currentRecord).length>0; Layout.fillWidth: true; spacing: 10
                    MokaidLabel { visible: root.page!=="mail"; text: "About this "+(root.page==="tasks"?"task":root.page==="projects"?"project":root.page==="agent-new"?"specialization":"record"); font.pixelSize: 13; font.weight: Font.DemiBold }
                    TextEdit { Layout.fillWidth: true; text: Logic.body(root.page,root.currentRecord); readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: 13; selectionColor: Theme.selection; selectedTextColor: Theme.text; Accessible.name: root.page==="mail" ? "Message body" : "Description" }
                }
                ColumnLayout {
                    visible: root.page==="tasks" && (root.currentRecord.subtasks || []).length>0; Layout.fillWidth: true; spacing: 12
                    MokaidLabel { text: "Subtasks · "+Logic.taskSubtasks(root.currentRecord).completed+"/"+Logic.taskSubtasks(root.currentRecord).total; font.pixelSize: 13; font.weight: Font.DemiBold }
                    Repeater {
                        model: root.currentRecord.subtasks || []
                        RowLayout {
                            id: subtask
                            required property var modelData
                            Layout.fillWidth: true; spacing: 10
                            MokaidIcon { name: Logic.subtaskDone(subtask.modelData) ? "tasks" : "minus"; size: 17; color: Logic.subtaskDone(subtask.modelData) ? Theme.success : Theme.muted }
                            MokaidLabel { Layout.fillWidth: true; text: subtask.modelData.title || subtask.modelData.name || "Subtask"; wrapMode: Text.Wrap; font.pixelSize: 12; color: Logic.subtaskDone(subtask.modelData) ? Theme.secondary : Theme.text }
                        }
                    }
                }
                ColumnLayout {
                    visible: root.page==="tasks" && (root.currentRecord.comments || []).length>0; Layout.fillWidth: true; spacing: 16
                    MokaidLabel { text: "Conversation"; font.pixelSize: 14; font.weight: Font.DemiBold }
                    Repeater {
                        model: root.currentRecord.comments || []
                        ColumnLayout {
                            id: comment
                            required property var modelData
                            Layout.fillWidth: true; spacing: 6
                            MokaidLabel { text: Logic.first(comment.modelData,["author_name","member_name","agent_name"],"Workspace member"); font.weight: Font.Medium; font.pixelSize: 12; color: Theme.secondary }
                            MokaidLabel { Layout.fillWidth: true; text: comment.modelData.body || ""; font.pixelSize: 13; wrapMode: Text.Wrap }
                        }
                    }
                }
                MokaidButton { text: "Details & activity"; quiet: true; iconName: "chevron-right"; onClicked: root.browserMode=true }
                Item { Layout.preferredHeight: 4 }
            }
        }
        ListView {
            id: detailRows
            visible: root.inspecting
            Layout.fillWidth: true; Layout.fillHeight: true
            model: features.detailView.rows; clip: true; reuseItems: true; spacing: 8
            header: DeliveryGallery { width: detailRows.width; visible: root.hasDeliverables && root.inspecting; files: root.hasDeliverables && root.inspecting ? features.detailView.deliverables : [] }
            delegate: Rectangle {
                id: detailDelegate
                required property string rowId
                required property string title
                required property var record
                width: detailRows.width; height: detailContent.implicitHeight+24
                color: record.container ? Theme.control : "transparent"; radius: Theme.radiusControl
                border.color: record.container ? Theme.divider : "transparent"
                ColumnLayout {
                    id: detailContent
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 12; spacing: 8
                    MokaidLabel { Layout.fillWidth: true; text: detailDelegate.title; wrapMode: Text.Wrap; color: Theme.secondary; font.pixelSize: 12; font.weight: Font.Medium }
                    TextEdit { Layout.fillWidth: true; text: detailDelegate.record.text || ""; readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: 13; selectionColor: Theme.selection; selectedTextColor: Theme.text; Accessible.name: detailDelegate.title }
                    Flow {
                        Layout.fillWidth: true; spacing: 6
                        visible: detailDelegate.record.expandable || detailDelegate.record.fileAvailable || (detailDelegate.record.referencePage || "").length>0
                        MokaidButton { text: detailDelegate.record.container ? "Explore" : "Read full text"; visible: detailDelegate.record.expandable; onClicked: features.detailView.enter(detailDelegate.rowId) }
                        MokaidButton { text: "Open record"; visible: (detailDelegate.record.referencePage || "").length>0; onClicked: features.detailView.openReference(detailDelegate.rowId) }
                        MokaidButton { text: "Open deliverable"; visible: detailDelegate.record.fileAvailable; onClicked: features.detailView.openFile(detailDelegate.rowId) }
                    }
                }
            }
            MokaidLabel { anchors.centerIn: parent; width: parent.width-24; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; visible: detailRows.count===0 && !root.hasDeliverables; text: features.busy ? "Loading details…" : "No details are available in this section."; color: Theme.secondary }
            ScrollBar.vertical: ScrollBar {}
        }
        Rectangle { visible: features.selectedId.length>0; Layout.fillWidth: true; height: 1; color: Theme.divider }
        RowLayout {
            visible: features.selectedId.length>0 && root.selectionActions.length>0
            Layout.fillWidth: true; spacing: 8
            MokaidButton {
                text: root.primarySelectedAction.title; enabled: root.primarySelectedAction.enabled
                highlighted: !root.primarySelectedAction.destructive
                Layout.fillWidth: true; Layout.minimumWidth: 0
                onClicked: root.actionRequested(root.primarySelectedAction)
            }
            MokaidButton { objectName: "selectionActionsButton"; text: "More actions"; iconName: "more"; onClicked: selectionMenu.openFor(this) }
        }
    }
    MokaidMenu {
        id: selectionMenu
        objectName: "selectionActionsMenu"
        Instantiator {
            model: root.selectionActions
            delegate: MokaidMenu.Entry {
                required property var modelData
                objectName: "selectionAction_" + modelData.id
                text: modelData.title; enabled: modelData.enabled; destructive: Boolean(modelData.destructive)
                onTriggered: root.actionRequested(modelData)
            }
            onObjectAdded: function(index, object) { selectionMenu.insertItem(index, object); }
            onObjectRemoved: function(index, object) { selectionMenu.removeItem(object); }
        }
    }
}
