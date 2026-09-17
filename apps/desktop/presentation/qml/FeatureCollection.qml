pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "FeatureLogic.js" as Logic

Item {
    id: root
    required property string page
    required property string viewMode
    required property var rows
    required property string selectedId
    property bool busy: false
    property bool offline: false
    property bool filtered: false
    property bool hasMore: false
    property bool driveTrash: false
    signal selected(string recordId)
    signal activated(var record)
    signal loadMore()
    readonly property var pageMeta: Logic.meta(page)
    function colorFor(value) { return Theme[Logic.tone(value)]; }

    component TaskCard: ItemDelegate {
        id: taskCard
        required property var dataRecord
        property bool tile: false
        readonly property string rowId: Logic.id(dataRecord)
        readonly property string name: Logic.title(dataRecord,"tasks")
        readonly property var percent: Logic.progress(dataRecord)
        readonly property var subtasks: Logic.taskSubtasks(dataRecord)
        objectName: (tile ? "taskCard_" : "taskRow_")+rowId
        highlighted: root.selectedId===rowId
        hoverEnabled: true; padding: 12
        implicitHeight: taskContent.implicitHeight+24
        Accessible.name: name+". "+Logic.status(dataRecord,"tasks")+". "+Logic.subtitle(dataRecord,"tasks")
        background: Rectangle {
            radius: 12; color: taskCard.highlighted ? Theme.selected : taskCard.hovered ? Theme.hover : Theme.surface
            border.color: taskCard.visualFocus ? Theme.focusBorder : taskCard.highlighted ? Theme.selectedBorder : Theme.border
        }
        contentItem: ColumnLayout {
            id: taskContent
            spacing: 8
            RowLayout {
                Layout.fillWidth: true; spacing: 8
                MokaidLabel {
                    Layout.fillWidth: true; text: taskCard.name; font.pixelSize: 13; font.weight: Font.DemiBold
                    maximumLineCount: taskCard.tile ? 2 : 1; wrapMode: Text.Wrap; elide: Text.ElideRight
                }
                MokaidIcon { visible: taskCard.highlighted; name: "chevron-right"; size: 14; color: Theme.primary }
            }
            MokaidLabel {
                visible: taskCard.tile && !!taskCard.dataRecord.project_name
                Layout.fillWidth: true; text: taskCard.dataRecord.project_name || ""; color: Theme.muted; font.pixelSize: 10; elide: Text.ElideRight
            }
            RowLayout {
                Layout.fillWidth: true; spacing: 6
                MokaidIcon { name: "agents"; size: 14; color: Theme.secondary }
                MokaidLabel {
                    Layout.fillWidth: true; text: taskCard.dataRecord.assigned_agent_name || "Unassigned"; color: Theme.secondary; font.pixelSize: 11; elide: Text.ElideRight
                }
                MokaidLabel {
                    visible: taskCard.subtasks.total>0; text: taskCard.subtasks.completed+"/"+taskCard.subtasks.total; color: Theme.secondary; font.pixelSize: 10
                    Accessible.name: taskCard.subtasks.completed+" of "+taskCard.subtasks.total+" subtasks complete"
                }
                MokaidLabel {
                    visible: taskCard.percent!==null && taskCard.percent>0; text: taskCard.percent+"%"; color: Theme.primary; font.pixelSize: 10
                    Accessible.name: "Progress "+taskCard.percent+" percent"
                }
            }
            RowLayout {
                Layout.fillWidth: true; spacing: 6
                Rectangle {
                    implicitWidth: taskStatus.implicitWidth+12; implicitHeight: 21; radius: 6
                    color: Logic.alpha(root.colorFor(taskCard.dataRecord.status),0.10)
                    MokaidLabel { id: taskStatus; anchors.centerIn: parent; text: Logic.status(taskCard.dataRecord,"tasks"); font.pixelSize: 10; color: root.colorFor(taskCard.dataRecord.status) }
                }
                MokaidLabel {
                    visible: !!taskCard.dataRecord.priority; text: Logic.human(taskCard.dataRecord.priority); color: root.colorFor(taskCard.dataRecord.priority); font.pixelSize: 10
                }
                Item { Layout.fillWidth: true }
                MokaidLabel {
                    visible: text.length>0
                    text: Logic.shortDate(taskCard.dataRecord.due_at); font.pixelSize: 10; color: taskCard.dataRecord.status==="overdue" ? Theme.danger : Theme.secondary
                    Accessible.name: "Due "+Logic.date(taskCard.dataRecord.due_at,false)
                }
            }
        }
        onClicked: root.selected(rowId)
        onDoubleClicked: root.activated(dataRecord)
        Keys.onReturnPressed: root.activated(dataRecord)
        Keys.onEnterPressed: root.activated(dataRecord)
    }

    component RecordCard: ItemDelegate {
        id: card
        required property var dataRecord
        readonly property string rowId: Logic.id(dataRecord)
        property bool tile: false
        property bool board: false
        readonly property string name: Logic.title(dataRecord, root.page)
        readonly property string stateText: Logic.status(dataRecord, root.page)
        readonly property var percent: Logic.progress(dataRecord)
        readonly property bool isFile: root.page === "drive" && dataRecord.kind !== "folder" && !root.driveTrash
        readonly property var format: isFile ? preview.describe(dataRecord) : ({kind:""})
        highlighted: root.selectedId === Logic.id(dataRecord)
        hoverEnabled: true
        padding: tile ? 14 : 12
        implicitHeight: tile ? (root.page === "drive" ? 180 : root.page === "projects" ? 184 : 162) : root.page === "mail" ? 88 : 72
        Accessible.name: name + ". " + stateText + ". " + Logic.subtitle(dataRecord,root.page)
        background: Rectangle {
            color: card.highlighted ? Theme.selected : card.hovered ? Theme.hover : card.tile ? Theme.surface : "transparent"
            radius: card.tile ? 14 : 10
            border.width: card.tile || card.highlighted || card.visualFocus ? 1 : 0
            border.color: card.visualFocus ? Theme.focusBorder : card.highlighted ? Theme.selectedBorder : Theme.border
        }
        contentItem: ColumnLayout {
            spacing: card.tile && root.page!=="projects" ? 8 : 6
            RowLayout {
                Layout.fillWidth: true; spacing: 12
                Rectangle {
                    visible: !card.board
                    Layout.preferredWidth: card.tile ? 32 : 34; Layout.preferredHeight: card.tile ? 32 : 34
                    radius: 9; color: Theme.raised
                    Image {
                        id: thumbnail
                        anchors.fill: parent; anchors.margins: 2
                        source: { if (!card.isFile || card.format.kind !== "image") return ""; preview.thumbnailRevision; return preview.thumbnailUrl(card.dataRecord); }
                        asynchronous: true; sourceSize.width: 120; sourceSize.height: 100; fillMode: Image.PreserveAspectFit
                    }
                    MokaidIcon {
                        anchors.centerIn: parent; size: 18; color: Theme.primary
                        visible: thumbnail.status !== Image.Ready && root.page !== "members" && root.page !== "admin-users" && root.page !== "mail"
                        name: root.page === "drive" ? (card.dataRecord.kind === "folder" ? "folder" : "file") : root.pageMeta.icon
                    }
                    MokaidLabel {
                        anchors.centerIn: parent; visible: root.page === "members" || root.page === "admin-users" || root.page === "mail"
                        text: root.page === "mail" ? Logic.first(card.dataRecord,["from_name","from_email"],"M").slice(0,1).toUpperCase() : Logic.initials(card.dataRecord,root.page)
                        color: Theme.primary; font.pixelSize: 13; font.weight: Font.DemiBold
                    }
                }
                ColumnLayout {
                    visible: !card.tile; Layout.fillWidth: true; spacing: 5
                    MokaidLabel { Layout.fillWidth: true; text: root.page === "mail" ? Logic.subtitle(card.dataRecord,root.page) : card.name; font.weight: Font.DemiBold; elide: Text.ElideRight }
                    MokaidLabel { Layout.fillWidth: true; text: root.page === "mail" ? card.name : Logic.subtitle(card.dataRecord,root.page); color: root.page === "mail" ? Theme.text : Theme.secondary; font.pixelSize: 12; elide: Text.ElideRight }
                }
                Item { visible: card.tile; Layout.fillWidth: true }
                Rectangle {
                    visible: card.stateText.length > 0 && (!card.board || root.page === "tasks")
                    implicitWidth: statusLabel.implicitWidth+16; implicitHeight: 25; radius: 7
                    color: Logic.alpha(root.colorFor(card.dataRecord.status || card.stateText),0.10)
                    MokaidLabel { id: statusLabel; anchors.centerIn: parent; text: card.stateText; color: root.colorFor(card.dataRecord.status || card.stateText); font.pixelSize: 11; font.weight: Font.Medium }
                }
                MokaidLabel { visible: !card.tile && root.page === "mail"; text: Logic.shortDate(card.dataRecord.received_at); color: Theme.muted; font.pixelSize: 11 }
            }
            MokaidLabel { visible: card.tile; Layout.fillWidth: true; text: card.name; font.pixelSize: 14; font.weight: Font.DemiBold; maximumLineCount: 2; wrapMode: Text.Wrap; elide: Text.ElideRight }
            MokaidLabel {
                visible: card.tile || root.page === "mail"; Layout.fillWidth: true
                text: root.page === "mail" ? Logic.first(card.dataRecord,["ai_summary","snippet"]) : Logic.subtitle(card.dataRecord,root.page)
                color: Theme.secondary; font.pixelSize: 12; maximumLineCount: card.tile && root.page!=="projects" ? 2 : 1; wrapMode: Text.Wrap; elide: Text.ElideRight
            }
            Item { visible: card.tile && root.page!=="projects"; Layout.fillHeight: true }
            ColumnLayout {
                visible: root.page === "projects" && card.tile && card.percent !== null
                Layout.fillWidth: true; spacing: 6
                RowLayout {
                    MokaidLabel { text: card.dataRecord.task_count !== undefined ? (card.dataRecord.completed_task_count || 0) + "/" + card.dataRecord.task_count + " tasks" : "Progress"; color: Theme.secondary; font.pixelSize: 11; Layout.fillWidth: true }
                    MokaidLabel { text: (card.percent === null ? 0 : card.percent) + "%"; color: Theme.text; font.pixelSize: 11 }
                }
                Rectangle { Layout.fillWidth: true; height: 4; radius: 2; color: Theme.raised; Rectangle { width: parent.width*(card.percent || 0)/100; height: parent.height; radius: 2; color: card.percent === 100 ? Theme.success : Theme.primary } }
            }
            RowLayout {
                visible: root.page === "tasks" || (card.tile && (root.page === "projects" || root.page === "drive")); Layout.fillWidth: true
                MokaidLabel { text: root.page === "drive" ? Logic.shortDate(card.dataRecord.updated_at || card.dataRecord.inserted_at) : Logic.human(card.dataRecord.priority); color: root.page === "drive" ? Theme.muted : root.colorFor(card.dataRecord.priority); font.pixelSize: 11 }
                Item { Layout.fillWidth: true }
                MokaidLabel { text: card.dataRecord.due_at ? "Due " + Logic.shortDate(card.dataRecord.due_at) : root.page === "projects" && card.dataRecord.members ? card.dataRecord.members.length+" members" : ""; color: Theme.secondary; font.pixelSize: 11 }
            }
        }
        onClicked: root.selected(Logic.id(dataRecord))
        onDoubleClicked: root.activated(dataRecord)
        Keys.onReturnPressed: root.activated(dataRecord)
        Keys.onEnterPressed: root.activated(dataRecord)
    }

    Loader {
        anchors.fill: parent
        active: root.rows.length > 0 && root.page !== "calendar" && root.pageMeta.view !== "summary"
        sourceComponent: root.page==="tasks" ? (root.viewMode==="list" ? taskListView : boardView) : root.viewMode === "grid" ? gridView : listView
    }
    Component {
        id: taskListView
        ListView {
            id: taskList
            clip: true; spacing: 6; model: root.rows; reuseItems: true
            delegate: TaskCard { required property var modelData; width: taskList.width-10; dataRecord: modelData }
            footer: MokaidButton { width: taskList.width; visible: root.hasMore; height: visible ? implicitHeight : 0; text: root.busy ? "Loading…" : "Load more tasks"; enabled: !root.busy; onClicked: root.loadMore() }
            ScrollBar.vertical: ScrollBar {}
        }
    }
    Component {
        id: listView
        ListView {
            id: list
            clip: true; spacing: 4; model: root.rows; reuseItems: true
            delegate: RecordCard { required property var modelData; width: list.width; dataRecord: modelData }
            footer: MokaidButton { width: list.width; visible: root.hasMore; text: root.busy ? "Loading…" : "Load more"; enabled: !root.busy; onClicked: root.loadMore() }
            ScrollBar.vertical: ScrollBar {}
        }
    }
    Component {
        id: gridView
        GridView {
            id: grid
            clip: true; model: root.rows
            cellWidth: width / Math.max(1, Math.floor(width/245)); cellHeight: root.page === "projects" ? 196 : root.page === "drive" ? 192 : 174
            delegate: RecordCard { required property var modelData; width: grid.cellWidth-12; height: grid.cellHeight-12; tile: true; dataRecord: modelData }
            footer: MokaidButton { width: grid.width; visible: root.hasMore; text: root.busy ? "Loading…" : "Load more"; enabled: !root.busy; onClicked: root.loadMore() }
            ScrollBar.vertical: ScrollBar {}
        }
    }
    Component {
        id: boardView
        ColumnLayout {
            spacing: 8
            ListView {
                id: board
                objectName: "task-board"
                Layout.fillWidth: true; Layout.fillHeight: true
                function revealSelection() {
                    const selected=root.rows.find(function(r){return Logic.id(r)===root.selectedId;});
                    if(selected) positionViewAtIndex(["todo","doing","review","done"].indexOf(Logic.boardGroup(selected)),ListView.Contain);
                }
                Component.onCompleted: Qt.callLater(revealSelection)
                onWidthChanged: Qt.callLater(revealSelection)
                Connections { target: root; function onSelectedIdChanged() { Qt.callLater(board.revealSelection); } }
                orientation: ListView.Horizontal; clip: true; spacing: 10; boundsBehavior: Flickable.StopAtBounds
                model: [{key:"todo",title:"To do",color:Theme.secondary},{key:"doing",title:"In progress",color:Theme.primary},{key:"review",title:"Needs attention",color:Theme.warning},{key:"done",title:"Finished",color:Theme.success}]
                delegate: ColumnLayout {
                    id: lane
                    required property var modelData
                    readonly property var cards: Logic.boardRows(root.rows,modelData.key)
                    objectName: "taskLane_"+modelData.key
                    width: Math.max(232, (board.width-30)/4); height: board.height-(board.contentWidth>board.width ? 16 : 0); spacing: 10
                    RowLayout {
                        Layout.fillWidth: true; Layout.preferredHeight: 32; spacing: 7
                        Rectangle { width: 6; height: 6; radius: 3; color: lane.modelData.color }
                        MokaidLabel { text: lane.modelData.title; font.pixelSize: 12; font.weight: Font.DemiBold; Layout.fillWidth: true }
                        Rectangle {
                            implicitWidth: Math.max(22,laneCount.implicitWidth+12); implicitHeight: 22; radius: 6; color: Theme.raised
                            MokaidLabel { id: laneCount; anchors.centerIn: parent; text: lane.cards.length; color: Theme.secondary; font.pixelSize: 10 }
                        }
                        Item { Layout.preferredWidth: 8 }
                    }
                    Rectangle { Layout.fillWidth: true; height: 1; color: Theme.divider }
                    ListView {
                        id: laneList
                        objectName: "taskLaneList_"+lane.modelData.key
                        Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 8; model: lane.cards; reuseItems: true; boundsBehavior: Flickable.StopAtBounds
                        function revealSelection() {
                            const index=lane.cards.findIndex(function(r){return Logic.id(r)===root.selectedId;});
                            if(index>=0) positionViewAtIndex(index,ListView.Contain);
                        }
                        Component.onCompleted: Qt.callLater(revealSelection)
                        onModelChanged: Qt.callLater(revealSelection)
                        Connections { target: root; function onSelectedIdChanged() { Qt.callLater(laneList.revealSelection); } }
                        delegate: TaskCard { required property var modelData; width: laneList.width-8; dataRecord: modelData; tile: true }
                        MokaidLabel { anchors.horizontalCenter: parent.horizontalCenter; anchors.top: parent.top; anchors.topMargin: 20; visible: lane.cards.length===0; text: "No tasks here"; color: Theme.muted; font.pixelSize: 11 }
                        ScrollBar.vertical: ScrollBar {}
                    }
                }
                ScrollBar.horizontal: ScrollBar {
                    id: boardScroll
                    policy: board.contentWidth>board.width ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                    padding: 2; implicitHeight: 10
                    background: Rectangle { color: Theme.raised; radius: 5 }
                    contentItem: Rectangle { implicitHeight: 6; radius: 3; color: boardScroll.pressed ? Theme.primary : boardScroll.hovered ? Theme.secondary : Theme.muted }
                }
            }
            MokaidButton {
                objectName: "task-board-load-more"
                visible: root.hasMore; Layout.alignment: Qt.AlignHCenter
                text: root.busy ? "Loading…" : "Load more tasks"; enabled: !root.busy; onClicked: root.loadMore()
            }
        }
    }
    ColumnLayout {
        anchors.centerIn: parent; width: Math.min(380,parent.width-48); spacing: 14
        visible: root.rows.length === 0 && !root.busy
        Rectangle { Layout.alignment: Qt.AlignHCenter; width: 66; height: 66; radius: 20; color: Theme.raised; MokaidIcon { anchors.centerIn: parent; name: root.filtered ? "search" : root.pageMeta.icon; size: 30; color: Theme.primary } }
        MokaidLabel { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: root.filtered ? "No matches found" : root.driveTrash ? "Trash is empty" : root.offline ? "No saved data for this view" : root.pageMeta.empty || "Nothing here yet"; font.pixelSize: 20; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
        MokaidLabel { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: root.filtered ? "Try a different search to find what you need." : root.driveTrash ? "Items you move to trash appear here until restored." : root.offline ? "Reconnect to synchronize this workspace." : root.pageMeta.hint || "Refresh this view to retrieve the latest data."; font.pixelSize: 13; wrapMode: Text.Wrap; color: Theme.secondary }
    }
}
