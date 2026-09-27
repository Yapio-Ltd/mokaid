pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQml.Models
import "FeatureLogic.js" as Logic

Item {
    id: root
    objectName: "tasksPage"
    signal actionRequested(var action)
    property string query: ""
    property string filterId: "all"
    property string priorityFilter: "all"
    property string viewMode: "board"
    property var commentDrafts: ({})
    property var improvementDrafts: ({})
    property string menuTaskId: ""
    property string feedback: ""
    property var now: new Date()
    readonly property bool active: features.currentPage === "tasks"
    readonly property var allRows: active ? features.allRecords : []
    readonly property string selectedId: active ? features.selectedId : ""
    readonly property bool hasDrafts: Object.keys(commentDrafts).some(function(id) { return String(root.commentDrafts[id] || "").trim().length > 0 }) || Object.keys(improvementDrafts).some(function(id) { return String(root.improvementDrafts[id] || "").trim().length > 0 })
    readonly property bool hasSelection: selectedId.length > 0
    readonly property var createAction: features.actions.find(function(a) { return a.id === "create" }) || ({enabled:false})
    readonly property var filteredRows: allRows.filter(function(row) {
        if (!root.matchesFilter(row, root.filterId)) return false
        if (root.priorityFilter !== "all" && row.priority !== root.priorityFilter) return false
        const words = root.query.trim().toLowerCase()
        const haystack = [row.title || "", row.description || "", row.assigned_agent_name || "", row.project_name || "", (row.tags || []).join(" ")].join(" ").toLowerCase()
        return !words || haystack.indexOf(words) >= 0
    })
    readonly property var summary: [
        {label:"Total tasks", value:allRows.length, icon:"tasks", accent:"#b491ff", background:"#282144"},
        {label:"Completed", value:allRows.filter(function(r) { return r.status === "completed" }).length, icon:"check", accent:"#5de1a9", background:"#14352c"},
        {label:"In progress", value:allRows.filter(function(r) { return Logic.boardGroup(r) === "doing" }).length, icon:"pulse", accent:"#f8b957", background:"#372a18"},
        {label:"Todo", value:allRows.filter(function(r) { return Logic.boardGroup(r) === "todo" }).length, icon:"tasks", accent:"#ff738e", background:"#361b2b"}
    ]
    readonly property var filters: [
        {id:"all",label:"All tasks"}, {id:"mine",label:"My tasks"}, {id:"assigned",label:"Assigned to me"}, {id:"week",label:"Due this week"}, {id:"overdue",label:"Overdue"}
    ]
    function matchesFilter(row, id) {
        if (id === "all") return true
        if (id === "mine") return !!features.currentMemberId && row.created_by_member_id === features.currentMemberId
        if (id === "assigned") return !!features.currentMemberId && row.assigned_member_id === features.currentMemberId
        const due = new Date(row.due_at || "")
        const terminal = row.status === "completed" || row.status === "canceled"
        if (id === "overdue") return !terminal && (row.status === "overdue" || isFinite(due.getTime()) && due < root.now)
        if (id === "week") {
            const start = new Date(root.now.getFullYear(), root.now.getMonth(), root.now.getDate())
            start.setDate(start.getDate() - (start.getDay() + 6) % 7)
            const end = new Date(start); end.setDate(end.getDate() + 7)
            return !terminal && isFinite(due.getTime()) && due >= start && due < end
        }
        return true
    }
    function filterCount(id) { return allRows.filter(function(row) { return root.matchesFilter(row,id) }).length }
    function selectRecord(id) { if (!id || !active) return; features.select(id); Qt.callLater(function() { if (inspector.visible) inspector.forceActiveFocus() }) }
    function closeInspector() {
        const id=selectedId
        features.clearSelection()
        Qt.callLater(function() {
            if (root.viewMode==="board") board.focusTask(id)
            else {
                const index=root.filteredRows.findIndex(function(row) { return String(row.id)===id })
                const card=index>=0?taskList.itemAtIndex(index):null
                if (card) card.forceActiveFocus(Qt.OtherFocusReason)
                else taskList.forceActiveFocus()
            }
        })
    }
    function request(action) { root.actionRequested(action) }
    function newTask(status) {
        if (!createAction.enabled) return
        root.actionRequested(Object.assign({},createAction,{initialValues:{status:status || "to_do"}}))
    }
    function moveTask(id, status) { return features.moveTask(id, status) }
    function setCommentDraft(id,text) { if (!id) return; const next=Object.assign({},commentDrafts); if (text) next[id]=text; else delete next[id]; commentDrafts=next }
    function setImprovementDraft(id,text) { if (!id) return; const next=Object.assign({},improvementDrafts); if (text) next[id]=text; else delete next[id]; improvementDrafts=next }
    function openTaskMenu(id, anchor) { menuTaskId=id; taskMenu.openFor(anchor) }
    function taskAction(id) {
        features.select(menuTaskId)
        const action=features.actions.find(function(a) { return a.id===id })
        if (action) root.request(action)
    }
    function portraitFor(row) {
        const nested = row.assigned_agent || ({})
        const path = row.assigned_agent_avatar_cdn_path || nested.avatar_cdn_path || ""
        const thumbnail = row.assigned_agent_avatar_thumbnail_url || nested.avatar_thumbnail_url || ""
        const portrait = row.assigned_agent_avatar_portrait_url || nested.avatar_portrait_url || ""
        return {display_name:row.assigned_agent_name || nested.display_name || "?", kind:path || portrait || thumbnail ? row.assigned_agent_kind || nested.kind || "ai" : "unknown", avatar_cdn_path:path, avatar_portrait_url:portrait, avatar_thumbnail_url:thumbnail, avatar_config:row.assigned_agent_avatar_config || nested.avatar_config || ({})}
    }
    function taskCategory(row) {
        const tags=row.tags && typeof row.tags.length === "number" ? row.tags : []
        const domains=row.domain_requested && typeof row.domain_requested.length === "number" ? row.domain_requested : []
        const first = tags[0] || domains[0] || row.project_name || ""
        return typeof first === "string" ? Logic.human(first) : ""
    }
    function categoryColor(label) {
        const value=label.toLowerCase()
        return /market|sale/.test(value) ? "#efb854" : /design|document/.test(value) ? "#6bcce3" : /develop|research/.test(value) ? "#88a5ff" : "#b6a0e5"
    }
    function dateLabel(value) {
        if (!value) return ""
        const date=new Date(value); if (!isFinite(date.getTime())) return ""
        const today=new Date(root.now.getFullYear(),root.now.getMonth(),root.now.getDate())
        const tomorrow=new Date(today); tomorrow.setDate(tomorrow.getDate()+1)
        if (date.toDateString()===today.toDateString()) return "Today"
        if (date.toDateString()===tomorrow.toDateString()) return "Tomorrow"
        return Qt.formatDate(date,"MMM d")
    }
    function dateColor(row) {
        if (row.status === "completed" || row.status === "canceled") return "#939db6"
        return matchesFilter(row,"overdue") ? "#ff788e" : dateLabel(row.due_at)==="Tomorrow" ? "#efb954" : "#b4c0dc"
    }
    function clearFilters() { query=""; filterId="all"; priorityFilter="all" }

    Timer { interval:60000; repeat:true; running:root.active; onTriggered:root.now=new Date() }
    Timer { id:feedbackTimer; interval:3800; onTriggered:root.feedback="" }
    Connections {
        target:features
        function onActionResult(actionId,result) {
            if (root.active && actionId==="move-task") {
                root.feedback="Task moved to " + Logic.human(result.status).toLowerCase()
                feedbackTimer.restart()
            }
        }
    }
    Connections {
        target:session
        ignoreUnknownSignals:true
        function onWorkspaceChanged() { root.commentDrafts=({}); root.improvementDrafts=({}); root.clearFilters(); root.feedback="" }
        function onCleared() { root.commentDrafts=({}); root.improvementDrafts=({}); root.clearFilters(); root.feedback="" }
    }
    onActiveChanged: if (active) { viewMode="board"; clearFilters() }

    ColumnLayout {
        enabled:!root.hasSelection
        anchors.fill:parent; anchors.topMargin:4; anchors.bottomMargin:6; spacing:20
        RowLayout {
            Layout.fillWidth:true; spacing:18
            ColumnLayout {
                Layout.fillWidth:true; spacing:5
                MokaidLabel { text:"Tasks"; font.pixelSize:28; font.weight:Font.Bold }
                MokaidLabel { text:"Turn your ideas into action, one task at a time."; font.pixelSize:13; color:Theme.secondary; Layout.fillWidth:true; wrapMode:Text.Wrap }
            }
            MokaidLabel { visible:root.width>820; text:"View"; color:Theme.secondary; font.pixelSize:12 }
            MokaidComboBox {
                id:viewSelector; objectName:"tasksViewMode"; model:["Kanban","List"]; currentIndex:root.viewMode==="board"?0:1
                Layout.preferredWidth:146; implicitHeight:42; Accessible.name:"Task view"
                contentItem:RowLayout {
                    spacing:8
                    MokaidIcon { name:root.viewMode==="board"?"grid":"list"; size:16; color:Theme.secondary }
                    MokaidLabel { text:viewSelector.displayText; Layout.fillWidth:true; font.pixelSize:13; elide:Text.ElideRight }
                }
                onActivated:root.viewMode=currentIndex===0?"board":"list"
            }
            MokaidButton { objectName:"tasksNewTask"; text:"New task"; iconName:"plus"; highlighted:true; implicitHeight:44; enabled:root.createAction.enabled && !features.busy; onClicked:root.newTask("to_do") }
        }
        RowLayout {
            objectName:"tasksStatistics"; Layout.fillWidth:true; spacing:18
            Repeater {
                model:root.summary
                Rectangle {
                    id:metric; required property var modelData
                    Layout.fillWidth:true; Layout.preferredWidth:1; Layout.minimumWidth:0; implicitHeight:76
                    radius:12; border.color:"#27293e"; color:"#10121e"
                    RowLayout {
                        anchors.fill:parent; anchors.margins:12; spacing:15
                        Rectangle { implicitWidth:44; implicitHeight:44; radius:11; color:metric.modelData.background; MokaidIcon { anchors.centerIn:parent; name:metric.modelData.icon; color:metric.modelData.accent; size:22 } }
                        ColumnLayout {
                            Layout.fillWidth:true; spacing:3
                            MokaidLabel { text:metric.modelData.value; font.pixelSize:20; font.weight:Font.DemiBold }
                            MokaidLabel { text:metric.modelData.label; font.pixelSize:13; color:Theme.secondary; Layout.fillWidth:true; elide:Text.ElideRight }
                        }
                    }
                }
            }
        }
        GridLayout {
            Layout.fillWidth:true; columns:root.width<1050?1:2; rowSpacing:12; columnSpacing:18
            Flow {
                Layout.fillWidth:true; Layout.minimumWidth:0; spacing:8
                Repeater {
                    model:root.filters
                    AbstractButton {
                        id:filter; required property var modelData
                        objectName:"tasksFilter-"+modelData.id
                        implicitWidth:filterContent.implicitWidth+30; implicitHeight:40; hoverEnabled:true; leftPadding:15; rightPadding:15
                        readonly property bool selected:root.filterId===modelData.id
                        Accessible.name:modelData.label+", "+root.filterCount(modelData.id)+" tasks"
                        Accessible.role:Accessible.PageTab
                        onClicked:root.filterId=modelData.id
                        background:Rectangle { radius:10; gradient:Gradient { GradientStop { position:0; color:filter.selected?"#8046d5":filter.hovered?"#1b1d2d":"#11131f" } GradientStop { position:1; color:filter.selected?"#5e2fb4":"#0e101a" } } border.color:filter.visualFocus?Theme.focusBorder:filter.selected?"#b077f6":"#282b40" }
                        contentItem:RowLayout {
                            id:filterContent; spacing:9
                            MokaidLabel { text:filter.modelData.label; font.pixelSize:13; font.weight:filter.selected?Font.DemiBold:Font.Normal }
                            MokaidLabel { text:root.filterCount(filter.modelData.id); font.pixelSize:11; color:filter.selected?"#eadcff":Theme.secondary; leftPadding:4; rightPadding:4; background:Rectangle { radius:4; color:filter.selected?"#8353c4":"#191b2a" } }
                        }
                    }
                }
            }
            RowLayout {
                Layout.preferredWidth:root.width<1050?-1:294; Layout.fillWidth:root.width<1050; spacing:10
                MokaidTextField {
                    objectName:"tasksSearch"; Layout.fillWidth:true; Layout.minimumWidth:0; implicitHeight:40; leftPadding:38
                    placeholderText:"Search tasks…"; text:root.query; onTextEdited:root.query=text; Accessible.name:"Search tasks"
                    MokaidIcon { anchors.left:parent.left; anchors.leftMargin:13; anchors.verticalCenter:parent.verticalCenter; name:"search"; size:16; color:Theme.secondary }
                }
                MokaidButton { objectName:"tasksFiltersButton"; iconName:"filter"; implicitHeight:40; implicitWidth:40; highlighted:root.priorityFilter!=="all"; Accessible.name:"Filter by priority"; onClicked:priorityMenu.openFor(this) }
            }
        }
        Rectangle {
            visible:!!features.error || features.offline
            Layout.fillWidth:true; implicitHeight:errorRow.implicitHeight+20; radius:10; color:"#291c26"; border.color:"#704054"
            RowLayout {
                id:errorRow; anchors.fill:parent; anchors.margins:10
                MokaidLabel { text:features.error || "You are offline. Reconnect to move or edit tasks."; color:Theme.danger; font.pixelSize:12; Layout.fillWidth:true; wrapMode:Text.Wrap }
                MokaidButton { text:"Retry"; implicitHeight:32; enabled:!features.busy; onClicked:features.refresh() }
            }
        }
        Item {
            Layout.fillWidth:true; Layout.fillHeight:true
            TasksBoard { id:board; anchors.fill:parent; visible:root.viewMode==="board" && (root.filteredRows.length>0 || features.busy); controller:root; rows:root.filteredRows }
            ListView {
                id:taskList; objectName:"tasksList"; anchors.fill:parent; visible:root.viewMode==="list"; clip:true; spacing:9; model:root.filteredRows
                delegate:TaskBoardCard { required property var modelData; width:taskList.width; dataRecord:modelData; controller:root; compact:true; draggable:false }
                ScrollBar.vertical:ScrollBar {}
            }
            ColumnLayout {
                visible:!root.filteredRows.length && !features.busy; anchors.centerIn:parent; width:Math.min(420,parent.width-32); spacing:14
                MokaidIcon { name:"tasks"; size:36; color:Theme.primary; Layout.alignment:Qt.AlignHCenter }
                MokaidLabel { text:root.allRows.length?"No tasks match your filters":"Make room for your next idea"; font.pixelSize:20; font.weight:Font.DemiBold; horizontalAlignment:Text.AlignHCenter; Layout.fillWidth:true; wrapMode:Text.Wrap }
                MokaidLabel { text:root.allRows.length?"Try a different search or clear your filters.":"Create a task, give it a clear goal, and assign it to a teammate."; font.pixelSize:12; color:Theme.secondary; horizontalAlignment:Text.AlignHCenter; Layout.fillWidth:true; wrapMode:Text.Wrap }
                MokaidButton { text:root.allRows.length?"Clear filters":"Create a task"; highlighted:true; enabled:root.allRows.length>0 || root.createAction.enabled; Layout.alignment:Qt.AlignHCenter; onClicked:root.allRows.length?root.clearFilters():root.newTask("to_do") }
            }
        }
        RowLayout {
            visible:!!root.feedback || features.busy || features.hasMore
            Layout.fillWidth:true; implicitHeight:26
            MokaidIcon { name:features.busy?"refresh":"check"; color:features.busy?Theme.primary:Theme.success; size:15 }
            MokaidLabel { text:features.pendingTaskId?"Saving task status…":features.busy?"Synchronizing tasks…":root.feedback; font.pixelSize:11; color:Theme.secondary; Layout.fillWidth:true }
            MokaidButton { visible:features.hasMore; text:"Load more tasks"; implicitHeight:28; enabled:!features.busy; onClicked:features.loadMore() }
        }
    }
    Rectangle {
        anchors.fill:parent; z:45; visible:root.hasSelection; color:"#80050810"
        MouseArea { anchors.fill:parent; onClicked:root.closeInspector(); Accessible.name:"Close task details" }
    }
    TasksInspector {
        id:inspector; objectName:"tasksInspector"; z:46
        anchors.top:parent.top; anchors.bottom:parent.bottom; anchors.right:parent.right
        width:Math.min(root.width-16,root.width<900?460:438)
        visible:root.hasSelection
        controller:root
        onCloseRequested:root.closeInspector()
        onActionRequested:function(action) { root.request(action) }
    }
    MokaidMenu {
        id:taskMenu; objectName:"taskActionsMenu"
        MokaidMenu.Entry { text:"Open task"; onTriggered:root.selectRecord(root.menuTaskId) }
        MokaidMenu.Separator {}
        MokaidMenu.Entry { objectName:"taskMoveTodo"; text:"Move to Todo"; enabled:features.canMoveTasks; onTriggered:root.moveTask(root.menuTaskId,"to_do") }
        MokaidMenu.Entry { objectName:"taskMoveDoing"; text:"Move to In progress"; enabled:features.canMoveTasks; onTriggered:root.moveTask(root.menuTaskId,"in_progress") }
        MokaidMenu.Entry { objectName:"taskMoveReview"; text:"Move to Needs attention"; enabled:features.canMoveTasks; onTriggered:root.moveTask(root.menuTaskId,"in_review") }
        MokaidMenu.Entry { objectName:"taskMoveDone"; text:"Mark as completed"; enabled:features.canMoveTasks; onTriggered:root.moveTask(root.menuTaskId,"completed") }
        MokaidMenu.Separator {}
        MokaidMenu.Entry { text:"Edit task"; enabled:features.canMoveTasks; onTriggered:root.taskAction("edit") }
        MokaidMenu.Entry { text:"Delete task…"; destructive:true; enabled:features.canMoveTasks && features.actions.some(function(a){return a.id==="delete"}); onTriggered:root.taskAction("delete") }
    }
    MokaidMenu {
        id:priorityMenu; objectName:"tasksPriorityMenu"
        MokaidMenu.Entry { text:"All priorities"; checkable:true; checked:root.priorityFilter==="all"; onTriggered:root.priorityFilter="all" }
        MokaidMenu.Entry { text:"Urgent"; checkable:true; checked:root.priorityFilter==="urgent"; onTriggered:root.priorityFilter="urgent" }
        MokaidMenu.Entry { text:"High"; checkable:true; checked:root.priorityFilter==="high"; onTriggered:root.priorityFilter="high" }
        MokaidMenu.Entry { text:"Medium"; checkable:true; checked:root.priorityFilter==="medium"; onTriggered:root.priorityFilter="medium" }
        MokaidMenu.Entry { text:"Low"; checkable:true; checked:root.priorityFilter==="low"; onTriggered:root.priorityFilter="low" }
    }
}
