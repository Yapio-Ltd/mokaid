pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQml.Models
import "FeatureLogic.js" as Logic

Item {
    id: root
    signal actionRequested(var action)
    readonly property string page: features.currentPage
    readonly property var pageMeta: Logic.meta(page)
    readonly property var records: features.visibleRecords
    readonly property var statistics: Logic.stats(page,features.allRecords)
    readonly property var primaryAction: features.actions.find(function(a){return a.id===root.pageMeta.primary;}) || ({enabled:false})
    readonly property bool hasSelection: features.selectedId.length>0
    readonly property bool showInspector: hasSelection || inspectOverview || (features.detailView.available && features.detailView.heading!=="Overview" && features.detailView.heading!=="Record details")
    readonly property bool compact: width<900 && page!=="drive"
    property bool inspectOverview: false
    property string viewMode: pageMeta.view
    property string query: ""
    property string selectedRecord: ""
    // Compatibility for native delivery-gallery consumers: metadata stays collapsed.
    readonly property bool metadataExpanded: inspector.browserMode
    function request(action) {
        if(Logic.reportAction(page,action.id)) { inspectOverview=true; inspector.browserMode=true; }
        root.actionRequested(action);
    }
    function selectRecord(id) { inspectOverview=false; inspector.browserMode=false; features.select(id); }
    function activate(record) {
        selectRecord(Logic.id(record));
        if(page==="drive" && !features.driveTrash) {
            if(record.kind==="folder") features.openDriveFolder(Logic.id(record));
            else openDriveFile(record);
        }
    }
    function openDriveFile(file) {
        const files=features.records.previewFiles();
        const index=files.findIndex(function(candidate){return candidate.id===file.id;});
        if(index>=0) preview.openCollection(files,index); else preview.openFile(file);
    }
    // Derive the default from the new route itself: pageMeta can still describe
    // the previous route while this signal is delivered.
    onPageChanged: { inspectOverview=false; query=""; viewMode=Logic.meta(page).view; if(inspector) inspector.browserMode=false; }
    Connections {
        target: features
        function onChanged() {
            if(root.selectedRecord!==features.selectedId) { root.selectedRecord=features.selectedId; inspector.browserMode=false; root.inspectOverview=false; }
        }
    }
    ColumnLayout {
        visible: root.page!=="agent-new"
        anchors.fill: parent; anchors.topMargin: 4; anchors.bottomMargin: 8; spacing: 14
        RowLayout {
            Layout.fillWidth: true; spacing: 16
            ColumnLayout {
                Layout.fillWidth: true; spacing: 4
                MokaidLabel { Layout.fillWidth: true; text: root.page==="agent-new" ? "Choose a specialization" : features.title; font.pixelSize: 26; font.weight: Font.DemiBold; elide: Text.ElideRight }
                MokaidLabel { Layout.fillWidth: true; text: features.offline ? "Saved workspace data · Offline" : root.pageMeta.subtitle; font.pixelSize: 13; color: Theme.secondary; wrapMode: Text.Wrap }
            }
            MokaidButton { iconName: "refresh"; quiet: true; enabled: !features.busy; Accessible.name: "Refresh "+features.title; onClicked: features.refresh() }
            MokaidButton { text: root.pageMeta.action || ""; visible: !!root.pageMeta.primary; iconName: ["create","invite","upload"].indexOf(root.pageMeta.primary)>=0 ? "plus" : ""; highlighted: true; enabled: root.primaryAction.enabled && (root.page!=="agent-new" || root.hasSelection); onClicked: root.request(root.primaryAction) }
        }
        Rectangle {
            visible: root.statistics.length>0 && !root.showInspector
            objectName: "pageStatistics"
            Layout.fillWidth: true; Layout.preferredHeight: 58; color: Theme.surface; radius: 12; border.color: Theme.border
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16; anchors.topMargin: 8; anchors.bottomMargin: 8; spacing: 20
                Repeater {
                    model: root.statistics
                    ColumnLayout {
                        id: statistic
                        required property var modelData
                        Layout.fillWidth: true; spacing: 2
                        MokaidLabel { text: statistic.modelData.value; font.pixelSize: 18; font.weight: Font.DemiBold }
                        MokaidLabel { text: statistic.modelData.label; Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: 11; color: Theme.secondary }
                    }
                }
            }
        }
        RowLayout {
            visible: root.pageMeta.view!=="summary" && !(root.compact && root.showInspector)
            Layout.fillWidth: true; spacing: 10
            MokaidTextField { objectName: "featureSearch"; Layout.preferredWidth: Math.min(280,Math.max(160,(root.width-64)*0.4)); Layout.minimumWidth: 0; placeholderText: "Search "+features.title.toLowerCase()+"…"; text: root.query; onTextEdited: { root.query=text; features.search(text); } Accessible.name: "Search "+features.title.toLowerCase() }
            Item { Layout.fillWidth: true }
            MokaidButton { objectName: "taskBoardMode"; visible: root.page==="tasks"; text: "Board"; quiet: true; highlighted: root.viewMode==="board"; onClicked: root.viewMode="board" }
            MokaidButton { visible: ["projects","drive","integrations","admin-workspaces","admin-plans","agent-new"].indexOf(root.page)>=0; text: "Grid"; quiet: true; highlighted: root.viewMode==="grid"; onClicked: root.viewMode="grid" }
            MokaidButton { objectName: "featureListMode"; visible: ["tasks","projects","drive","integrations","admin-workspaces","admin-plans","agent-new"].indexOf(root.page)>=0; text: "List"; quiet: true; highlighted: root.viewMode==="list"; onClicked: root.viewMode="list" }
            MokaidButton { objectName: "pageActionsButton"; text: "More"; iconName: "more"; quiet: true; onClicked: viewActions.openFor(this); Accessible.name: "More "+features.title.toLowerCase()+" actions" }
        }
        DriveNavigation { Layout.fillWidth: true; visible: root.page==="drive" && !(root.compact && root.showInspector); controller: features }
        Rectangle {
            visible: features.error.length>0; Layout.fillWidth: true; Layout.preferredHeight: errorRow.implicitHeight+20; radius: 10; color: Logic.alpha(Theme.warning,0.08)
            RowLayout {
                id: errorRow
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 10
                MokaidLabel { Layout.fillWidth: true; text: features.error; font.pixelSize: 12; wrapMode: Text.Wrap; color: Theme.warning }
                MokaidButton { text: "Retry"; quiet: true; enabled: !features.busy; onClicked: features.refresh() }
            }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 14
            Item {
                Layout.fillWidth: true; Layout.fillHeight: true
                visible: !root.compact || !root.showInspector
                FeatureCollection {
                    objectName: "featureCollection"
                    anchors.fill: parent; visible: root.pageMeta.view!=="summary" && root.page!=="calendar"
                    page: root.page; viewMode: root.viewMode; rows: root.records; selectedId: features.selectedId; busy: features.busy; offline: features.offline; filtered: root.query.length>0; hasMore: features.hasMore; driveTrash: features.driveTrash
                    onSelected: function(recordId){root.selectRecord(recordId);}
                    onActivated: function(record){root.activate(record);}
                    onLoadMore: features.loadMore()
                }
                FeatureCalendar { anchors.fill: parent; visible: root.page==="calendar"; searching: root.query.length>0; rows: root.page==="calendar" ? root.records : []; onSelected: function(recordId){root.selectRecord(recordId);} }
                FeatureSummary {
                    anchors.fill: parent; visible: root.pageMeta.view==="summary"; page: root.page; overview: features.overview; actions: features.actions
                    onActionRequested: function(action){root.request(action);}
                    onInspectRequested: {features.showOverview(); root.inspectOverview=true; inspector.browserMode=true;}
                }
            }
            FeatureInspector {
                id: inspector
                objectName: "featureInspector"
                visible: root.showInspector
                Layout.fillHeight: true; Layout.fillWidth: root.compact; Layout.preferredWidth: root.compact ? -1 : Math.max(300,Math.min(420,root.width*0.39))
                page: root.page
                onActionRequested: function(action){root.request(action);}
                onCloseRequested: {root.inspectOverview=false; browserMode=false; features.clearSelection();}
                onReturnToRecord: {root.inspectOverview=false; browserMode=false; features.showRecordDetails();}
            }
        }
        RowLayout {
            visible: features.busy; Layout.alignment: Qt.AlignHCenter; spacing: 8; Layout.preferredHeight: 22
            BusyIndicator { running: features.busy; Layout.preferredHeight: 22; Layout.preferredWidth: 22 }
            MokaidLabel { text: "Synchronizing…"; font.pixelSize: 11; color: Theme.muted }
        }
    }
    AgentCreationPage {
        anchors.fill: parent
        visible: root.page==="agent-new"
        onActionRequested: function(action) { root.actionRequested(action); }
    }
    MokaidMenu {
        id: viewActions
        objectName: "pageActionsMenu"
        Instantiator {
            model: features.actions.filter(function(action) { return !action.selection; })
            delegate: MokaidMenu.Entry {
                required property var modelData
                objectName: "pageAction_" + modelData.id
                text: modelData.title; enabled: modelData.enabled; destructive: Boolean(modelData.destructive)
                onTriggered: root.request(modelData)
            }
            onObjectAdded: function(index, object) { viewActions.insertItem(index, object); }
            onObjectRemoved: function(index, object) { viewActions.removeItem(object); }
        }
        MokaidMenu.Entry { objectName: "pageOverviewAction"; text: "Explore page details"; onTriggered: {features.showOverview(); root.inspectOverview=true; inspector.browserMode=true;} }
    }
}
