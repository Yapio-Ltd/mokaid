pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "FeatureLogic.js" as Logic

Item {
    id:root
    required property var dataRecord
    required property var controller
    property var board: null
    property bool compact: false
    property bool draggable: true
    readonly property string taskId:String(dataRecord.id || "")
    readonly property bool done:dataRecord.status==="completed"
    readonly property bool canceled:dataRecord.status==="canceled"
    readonly property bool moving:features.pendingTaskId===taskId
    readonly property bool showProgress:Logic.boardGroup(dataRecord)==="doing" && Logic.progress(dataRecord)!==null
    readonly property string category:controller.taskCategory(dataRecord)
    readonly property color categoryColor:controller.categoryColor(category)
    readonly property color priorityColor:dataRecord.priority==="urgent"||dataRecord.priority==="high"?"#fc8199":dataRecord.priority==="low"?"#92c9ba":"#bea1ff"
    readonly property bool dragging:gesture.drag.active && !gesture.canceledDrag
    objectName:"taskCard_"+taskId
    implicitHeight:Math.max(compact?92:102,cardContent.implicitHeight+24)
    activeFocusOnTab:true
    Accessible.role:Accessible.Button
    Accessible.name:String(dataRecord.title || "Untitled task")+". "+Logic.human(dataRecord.status)+". "+(dataRecord.assigned_agent_name || "Unassigned")
    Accessible.onPressAction:controller.selectRecord(taskId)
    Keys.onReturnPressed:controller.selectRecord(taskId)
    Keys.onEnterPressed:controller.selectRecord(taskId)
    Keys.onSpacePressed:controller.selectRecord(taskId)
    Keys.onMenuPressed:controller.openTaskMenu(taskId,root)
    Keys.onEscapePressed:if (root.board && root.dragging) { gesture.didDrag=true; gesture.canceledDrag=true; surface.Drag.cancel(); root.board.draggingId="" }

    Rectangle { anchors.fill:parent; visible:root.dragging; radius:10; color:"#1a152c"; border.color:"#8660c5"; opacity:.5 }
    Rectangle {
        id:surface
        width:root.width; height:root.height
        radius:10
        color:root.done||root.canceled?"#12141f":gesture.containsMouse?"#1a1c2c":"#151724"
        border.color:root.activeFocus?Theme.focusBorder:root.dragging?"#b98aff":root.controller.selectedId===root.taskId?"#9770d6":root.moving?"#7d55c9":"#232538"
        border.width:root.dragging?1.5:1
        opacity:root.moving?.62:1
        z:root.dragging?40:0
        Drag.active:root.dragging
        Drag.source:root
        Drag.keys:["mokaid/task"]
        Drag.supportedActions:Qt.MoveAction
        Drag.proposedAction:Qt.MoveAction
        Drag.hotSpot.x:gesture.pressX
        Drag.hotSpot.y:gesture.pressY
        states:State {
            name:"dragging"; when:root.dragging && !!root.board
            ParentChange { target:surface; parent:root.board?root.board.dragLayer:null }
        }
        MouseArea {
            id:gesture
            anchors.fill:parent; hoverEnabled:true
            property real pressX:0
            property real pressY:0
            property bool didDrag:false
            property bool canceledDrag:false
            drag.target:root.draggable && root.board && features.canMoveTasks && !canceledDrag?surface:null
            drag.threshold:8
            preventStealing:true
            cursorShape:root.dragging?Qt.ClosedHandCursor:root.draggable&&features.canMoveTasks?Qt.OpenHandCursor:Qt.PointingHandCursor
            onPressed:function(mouse) { pressX=mouse.x; pressY=mouse.y; didDrag=false; canceledDrag=false; root.forceActiveFocus(Qt.MouseFocusReason) }
            onPositionChanged:function(mouse) {
                if (root.dragging && root.board) {
                    didDrag=true
                    root.board.draggingId=root.taskId
                    root.board.pointer=surface.mapToItem(root.board,mouse.x,mouse.y)
                }
            }
            onReleased: {
                if (root.dragging) surface.Drag.drop()
                if (root.board) root.board.draggingId=""
            }
            onCanceled:if (root.board) root.board.draggingId=""
            onClicked:if (!didDrag) root.controller.selectRecord(root.taskId)
        }
        RowLayout {
            anchors.fill:parent; anchors.margins:12; spacing:12
            AbstractButton {
                id:complete; objectName:"taskComplete_"+root.taskId
                Layout.preferredWidth:24; Layout.preferredHeight:30; Layout.alignment:Qt.AlignTop; Layout.topMargin:5
                hoverEnabled:true; enabled:features.canMoveTasks
                Accessible.name:root.done?"Reopen task":"Complete task"
                onClicked:root.controller.moveTask(root.taskId,root.done?"to_do":"completed")
                background:Rectangle {
                    anchors.centerIn:parent; width:20; height:20; radius:10
                    color:root.done?"#66dfac":complete.hovered?"#2c2145":"transparent"
                    border.width:root.done?0:1.5; border.color:complete.visualFocus?Theme.focusBorder:root.showProgress?"#a278f1":"#a1acc8"
                    MokaidIcon { anchors.centerIn:parent; name:root.canceled?"close":"check"; size:14; color:root.done?"#194d3c":Theme.muted; visible:root.done||root.canceled }
                }
            }
            ColumnLayout {
                id:cardContent; Layout.fillWidth:true; Layout.minimumWidth:0; spacing:7
                RowLayout {
                    Layout.fillWidth:true; spacing:5
                    MokaidLabel {
                        Layout.fillWidth:true; Layout.minimumWidth:0
                        text:root.dataRecord.title || "Untitled task"
                        font.pixelSize:14; font.weight:Font.Medium; font.strikeout:root.done
                        color:root.done||root.canceled?"#9ca5bc":Theme.text
                        wrapMode:Text.Wrap; maximumLineCount:2; elide:Text.ElideRight
                    }
                    MokaidButton { objectName:"taskCardMenu_"+root.taskId; Layout.alignment:Qt.AlignTop; implicitWidth:16; implicitHeight:22; leftPadding:0; rightPadding:0; iconName:"more"; quiet:true; Accessible.name:"Actions for "+root.dataRecord.title; onClicked:root.controller.openTaskMenu(root.taskId,this) }
                }
                Flow {
                    Layout.fillWidth:true; spacing:5
                    Rectangle {
                        visible:!!root.category; width:Math.min(categoryText.implicitWidth+12,cardContent.width*.66); height:22; radius:6; color:Logic.alpha(root.categoryColor,root.done?.07:.13)
                        MokaidLabel { id:categoryText; anchors.fill:parent; anchors.leftMargin:6; anchors.rightMargin:6; text:root.category; font.pixelSize:12; verticalAlignment:Text.AlignVCenter; color:root.done?"#8f9aac":root.categoryColor; elide:Text.ElideRight }
                    }
                    Rectangle {
                        visible:!!root.dataRecord.priority; width:priorityText.implicitWidth+12; height:22; radius:6; color:Logic.alpha(root.priorityColor,root.done?.05:.13)
                        MokaidLabel { id:priorityText; anchors.centerIn:parent; text:Logic.human(root.dataRecord.priority); font.pixelSize:12; color:root.done?"#8f9aac":root.priorityColor }
                    }
                    MokaidLabel { visible:root.canceled; text:"Canceled"; font.pixelSize:10; color:Theme.muted; topPadding:3 }
                }
                RowLayout {
                    Layout.fillWidth:true; spacing:6
                    WorkforcePortrait { size:22; agent:root.controller.portraitFor(root.dataRecord); opacity:root.done?.6:1 }
                    MokaidLabel { text:root.dataRecord.assigned_agent_name || "Unassigned"; color:root.done?"#939db6":Theme.secondary; font.pixelSize:12; elide:Text.ElideRight; Layout.fillWidth:true; Layout.minimumWidth:0 }
                    MokaidIcon { visible:!root.showProgress&&!!root.dataRecord.due_at; name:"calendar"; size:13; color:root.controller.dateColor(root.dataRecord) }
                    MokaidLabel { visible:!root.showProgress&&!!root.dataRecord.due_at; text:root.controller.dateLabel(root.dataRecord.due_at); color:root.controller.dateColor(root.dataRecord); font.pixelSize:12 }
                    MokaidLabel { visible:root.showProgress; text:Logic.progress(root.dataRecord)+"%"; color:Theme.secondary; font.pixelSize:10 }
                }
                Rectangle {
                    visible:root.showProgress; Layout.fillWidth:true; implicitHeight:5; radius:3; color:"#2b2b40"
                    Rectangle { width:parent.width*(Logic.progress(root.dataRecord)||0)/100; height:parent.height; radius:3; gradient:Gradient { orientation:Gradient.Horizontal; GradientStop { position:0; color:"#b279ef" } GradientStop { position:1; color:"#9065df" } } }
                }
            }
        }
    }
}
