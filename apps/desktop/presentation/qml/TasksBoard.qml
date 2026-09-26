pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "FeatureLogic.js" as Logic

Item {
    id:root
    objectName:"task-board"
    required property var controller
    property var rows:[]
    property alias dragLayer:dragLayer
    property string draggingId:""
    property point pointer:Qt.point(0,0)
    readonly property var lanes:[
        {key:"todo", title:"Todo", status:"to_do", accent:"#eef0fc",icon:""},
        {key:"doing",title:"In progress",status:"in_progress",accent:"#4982ff",icon:"plus"},
        {key:"review",title:"Needs attention",status:"in_review",accent:"#ffc15d",icon:"alert"},
        {key:"done",title:"Completed",status:"completed",accent:"#48dda4",icon:"check"}
    ]
    function focusTask(id) {
        for (let index=0; index<laneRepeater.count; ++index) {
            const lane=laneRepeater.itemAt(index)
            if (!lane) continue
            const taskIndex=lane.cards.findIndex(function(row) { return String(row.id)===id })
            if (taskIndex<0) continue
            lane.list.positionViewAtIndex(taskIndex,ListView.Contain)
            const card=lane.list.itemAtIndex(taskIndex)
            if (card) { card.forceActiveFocus(Qt.OtherFocusReason); return }
        }
        root.forceActiveFocus()
    }
    Flickable {
        id:boardScroll
        anchors.fill:parent
        contentWidth:Math.max(width,4*248+3*18)
        contentHeight:height
        flickableDirection:Flickable.HorizontalFlick
        boundsBehavior:Flickable.StopAtBounds
        interactive:!root.draggingId
        clip:true
        Row {
            id:columns; spacing:18; width:boardScroll.contentWidth; height:boardScroll.height-(boardScroll.contentWidth>boardScroll.width?16:0)
            Repeater {
                id:laneRepeater
                model:root.lanes
                Rectangle {
                    id:lane
                    required property var modelData
                    property alias list:laneList
                    readonly property var cards:Logic.boardRows(root.rows,modelData.key)
                    objectName:"taskLane_"+modelData.key
                    width:(columns.width-54)/4
                    height:Math.min(columns.height,Math.max(160,54+laneList.contentHeight+47))
                    radius:12; color:drop.containsDrag?"#1b152b":"#0e111c"
                    border.color:drop.containsDrag?"#b280f5":"#2b2c43"
                    border.width:drop.containsDrag?1.5:1
                    ColumnLayout {
                        anchors.fill:parent; anchors.margins:4; spacing:4
                        RowLayout {
                            Layout.fillWidth:true; Layout.preferredHeight:39; Layout.leftMargin:9; Layout.rightMargin:5; spacing:10
                            Rectangle {
                                implicitWidth:lane.modelData.key==="todo"?13:19; implicitHeight:width; radius:width/2; color:lane.modelData.accent
                                MokaidIcon { anchors.centerIn:parent; visible:!!lane.modelData.icon; name:lane.modelData.icon; color:lane.modelData.key==="doing"?"white":"#263130"; size:12 }
                            }
                            MokaidLabel { text:lane.modelData.title; font.pixelSize:15; font.weight:Font.DemiBold }
                            MokaidLabel { text:lane.cards.length; color:Theme.secondary; font.pixelSize:11; leftPadding:4; rightPadding:4; background:Rectangle { radius:4; color:"#171a2a" } }
                            Item { Layout.fillWidth:true }
                            MokaidButton { objectName:"taskLaneAdd_"+lane.modelData.key; iconName:"plus"; implicitWidth:28; implicitHeight:29; leftPadding:6; rightPadding:6; Accessible.name:"Add task to "+lane.modelData.title; enabled:root.controller.createAction.enabled; onClicked:root.controller.newTask(lane.modelData.status) }
                        }
                        ListView {
                            id:laneList; objectName:"taskLaneList_"+lane.modelData.key
                            Layout.fillWidth:true; Layout.fillHeight:true; Layout.minimumHeight:55
                            model:lane.cards; clip:true; spacing:5; boundsBehavior:Flickable.StopAtBounds
                            interactive:!root.draggingId; cacheBuffer:1000
                            delegate:TaskBoardCard { required property var modelData; width:laneList.width; dataRecord:modelData; controller:root.controller; board:root }
                            MokaidLabel { visible:lane.cards.length===0; anchors.centerIn:parent; text:root.draggingId?"Drop task here":"No tasks here yet"; color:Theme.muted; font.pixelSize:11 }
                            ScrollBar.vertical:ScrollBar { policy:ScrollBar.AsNeeded }
                            Timer {
                                interval:24; repeat:true; running:!!root.draggingId && drop.containsDrag
                                onTriggered: {
                                    const point=laneList.mapFromItem(root,root.pointer.x,root.pointer.y)
                                    if (point.y<36) laneList.contentY=Math.max(0,laneList.contentY-10)
                                    else if (point.y>laneList.height-36) laneList.contentY=Math.max(0,Math.min(laneList.contentHeight-laneList.height,laneList.contentY+10))
                                }
                            }
                        }
                        MokaidButton {
                            objectName:"taskLaneFooter_"+lane.modelData.key
                            Layout.fillWidth:true; implicitHeight:39; text:"Add a task"; iconName:"plus"; quiet:true; font.pixelSize:13
                            contentItem: Item {
                                implicitWidth:addTaskContent.implicitWidth
                                implicitHeight:addTaskContent.implicitHeight
                                Row {
                                    id:addTaskContent; anchors.centerIn:parent; spacing:8
                                    MokaidIcon { name:"plus"; size:16; color:Theme.secondary; anchors.verticalCenter:parent.verticalCenter }
                                    MokaidLabel { text:"Add a task"; font.pixelSize:13; color:Theme.secondary }
                                }
                            }
                            background:Rectangle {
                                color:parent.hovered?"#191a29":"#0e111c"; radius:8
                                border.color:parent.visualFocus?Theme.focusBorder:"transparent"
                                Rectangle { anchors.top:parent.top; width:parent.width; height:1; color:"#292a3f" }
                            }
                            enabled:root.controller.createAction.enabled
                            onClicked:root.controller.newTask(lane.modelData.status)
                        }
                    }
                    DropArea {
                        id:drop; objectName:"taskDrop_"+lane.modelData.key
                        anchors.fill:parent; keys:["mokaid/task"]
                        onEntered:function(drag) { drag.accepted=features.canMoveTasks && !!drag.source && !!drag.source.taskId }
                        onDropped:function(drop) {
                            if (!features.canMoveTasks || !drop.source || !drop.source.taskId) return
                            if (Logic.boardGroup(drop.source.dataRecord)!==lane.modelData.key) root.controller.moveTask(drop.source.taskId,lane.modelData.status)
                            drop.acceptProposedAction()
                        }
                    }
                }
            }
        }
        ScrollBar.horizontal:ScrollBar {
            id:horizontalBar; policy:boardScroll.contentWidth>boardScroll.width?ScrollBar.AlwaysOn:ScrollBar.AlwaysOff
            contentItem:Rectangle { implicitHeight:6; radius:3; color:horizontalBar.pressed?Theme.primary:"#56506c" }
            background:Rectangle { color:"#151624"; radius:3 }
        }
    }
    Item { id:dragLayer; anchors.fill:parent; z:100 }
    Timer {
        interval:24; repeat:true; running:!!root.draggingId
        onTriggered: {
            if (root.pointer.x<44) boardScroll.contentX=Math.max(0,boardScroll.contentX-14)
            else if (root.pointer.x>root.width-44) boardScroll.contentX=Math.min(boardScroll.contentWidth-boardScroll.width,boardScroll.contentX+14)
        }
    }
}
