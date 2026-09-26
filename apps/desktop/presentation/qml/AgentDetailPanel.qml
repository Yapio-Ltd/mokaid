pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

FocusScope {
    id: root
    objectName: "agentDetailPanel"
    property var agent: ({})
    property int currentTab: 0
    property bool chatOpen: false
    property alias content: detailContent
    readonly property bool hasDrafts: detailContent.hasDrafts
    property string observedAgentId: ""
    property double now: Date.now()
    signal closed()
    signal actionRequested(var action)
    readonly property bool compact: height < 700 || chatOpen
    readonly property bool tight: height < 590
    readonly property bool tasksReady: features.selectedId === agent.id && features.selectedAgentTasksState === "ready"
    readonly property var tasks: features.selectedId === agent.id ? (features.selectedAgentTasks || []) : []
    readonly property var recentTasks: tasks.slice().sort(function(a, b) {
        return String(b.updated_at || b.inserted_at || "").localeCompare(String(a.updated_at || a.inserted_at || ""))
    }).slice(0, 4)
    readonly property var currentTask: agent.screen_task && agent.screen_task.id === agent.current_task_id ? agent.screen_task : tasks.find(function(task) { return task.id === root.agent.current_task_id }) || ({})
    readonly property var skills: (agent.skills || []).map(function(skill) { return typeof skill === "string" ? skill : skill.name || skill.label || skill.key || "" }).filter(function(skill) { return !!skill })
    readonly property string presence: agent.status === "blocked" ? "Needs attention" : agent.status === "waiting" ? "Waiting" : agent.status === "training" ? "Training" : agent.status === "offline" || agent.status === "away" ? "Away" : agent.current_task_id || agent.status === "busy" ? "Working" : "Available"
    readonly property color presenceColor: presence === "Needs attention" || presence === "Waiting" ? Theme.warning : presence === "Away" ? Theme.secondary : presence === "Training" ? Theme.primary : Theme.success
    readonly property real progress: currentTask.progress_percent === null || currentTask.progress_percent === undefined ? -1 : Math.max(0, Math.min(100, Number(currentTask.progress_percent)))
    readonly property string averageDuration: {
        if (!tasksReady) return "—"
        const times = tasks.filter(function(task) { return task.status === "completed" && task.started_at && task.completed_at }).map(function(task) { return new Date(task.completed_at) - new Date(task.started_at) }).filter(function(ms) { return isFinite(ms) && ms >= 0 })
        if (!times.length) return "—"
        const minutes = times.reduce(function(sum, ms) { return sum + ms }, 0) / times.length / 60000
        return minutes < 1 ? "<1m" : minutes < 60 ? Math.round(minutes) + "m" : minutes < 1440 ? (minutes / 60).toFixed(1).replace(/\.0$/, "") + "h" : (minutes / 1440).toFixed(1).replace(/\.0$/, "") + "d"
    }
    function action(id) { return (features.actions || []).find(function(item) { return item.id === id }) || ({enabled: false}) }
    function runAction(id) { const next = action(id); if (next.enabled) actionRequested(next) }
    function selectTab(index) { currentTab = index; chatOpen = false }
    function openReport(id) {
        selectTab(id === "training" || id === "progression" ? 2 : 3)
        detailContent.openReport(id)
    }
    function relativeDate(value) {
        if (!value) return ""
        const ms = now - new Date(value).getTime()
        if (!isFinite(ms)) return ""
        const mins = Math.max(0, Math.floor(ms / 60000))
        return mins < 1 ? "Just now" : mins < 60 ? mins + "m ago" : mins < 1440 ? Math.floor(mins / 60) + "h ago" : Math.floor(mins / 1440) + "d ago"
    }
    function taskStatus(task) { return ({to_do: "Not started", in_progress: "In progress", in_review: "In review", completed: "Completed", canceled: "Canceled", waiting: "Waiting", blocked: "Blocked", overdue: "Overdue"})[task.status] || "Not started" }
    function taskColor(task) { return task.status === "completed" ? Theme.success : ["blocked", "overdue", "waiting"].indexOf(task.status) >= 0 ? Theme.warning : ["in_progress", "in_review"].indexOf(task.status) >= 0 ? Theme.primary : Theme.muted }
    onAgentChanged: {
        if (observedAgentId !== String(agent.id || "")) {
            observedAgentId = String(agent.id || "")
            currentTab = 0; chatOpen = false
        }
    }
    Keys.onEscapePressed: function(event) {
        if (chatOpen) { chatOpen = false; chatAction.forceActiveFocus() }
        else root.closed()
        event.accepted = true
    }
    Timer { interval: 60000; running: root.visible; repeat: true; onTriggered: root.now = Date.now() }
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: function(wheel) { wheel.accepted = true } }

    component Surface: Rectangle {
        radius: 14; border.color: Theme.border
        gradient: Gradient { GradientStop { position: 0; color: "#141623" } GradientStop { position: 1; color: "#0e101b" } }
    }
    component Metric: Item {
        id: metric
        property string value
        property string label
        property string iconName
        property color accent
        property string hint
        implicitHeight: 56
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6; spacing: 8
            Rectangle {
                visible: root.width >= 400
                implicitWidth: 30; implicitHeight: 32; radius: 9; color: Qt.rgba(metric.accent.r, metric.accent.g, metric.accent.b, .14)
                MokaidIcon { anchors.centerIn: parent; name: metric.iconName; size: 17; color: metric.accent }
            }
            ColumnLayout {
                Layout.fillWidth: true; spacing: 3
                MokaidLabel { Layout.fillWidth: true; text: metric.value; font.pixelSize: 16; font.weight: Font.DemiBold; elide: Text.ElideRight }
                MokaidLabel { Layout.fillWidth: true; text: metric.label; color: Theme.secondary; font.pixelSize: 10; elide: Text.ElideRight }
            }
        }
        HoverHandler { id: metricHover }
        ToolTip.visible: metricHover.hovered; ToolTip.text: hint; ToolTip.delay: 550
        Accessible.role: Accessible.StaticText; Accessible.name: label + ": " + value + ". " + hint
    }
    component FooterAction: AbstractButton {
        id: control
        property string iconName
        property bool selected: false
        implicitHeight: root.tight ? 66 : 76; implicitWidth: 70; hoverEnabled: true
        contentItem: ColumnLayout {
            spacing: 7
            Rectangle {
                Layout.alignment: Qt.AlignHCenter; implicitWidth: 44; implicitHeight: 44; radius: 16
                color: control.selected ? "#452176" : control.hovered ? Theme.hover : "#11131f"
                border.color: control.visualFocus ? Theme.focusBorder : control.selected ? "#9858ed" : Theme.border
                MokaidIcon { anchors.centerIn: parent; name: control.iconName; size: 20; color: control.selected ? "#ece0ff" : Theme.secondary }
            }
            MokaidLabel { Layout.fillWidth: true; text: control.text; font.pixelSize: root.width < 380 ? 10 : 11; color: control.enabled ? Theme.text : Theme.muted; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight }
        }
        opacity: enabled ? 1 : .45
        Accessible.name: text
        ToolTip.visible: hovered; ToolTip.delay: 700; ToolTip.text: text
    }

    ColumnLayout {
        anchors.fill: parent; spacing: root.tight ? 8 : 10
        Surface {
            id: profile
            objectName: "agentDetailProfile"
            Layout.fillWidth: true; Layout.preferredHeight: root.chatOpen ? 110 : root.tight ? 116 : root.compact ? 204 : 300
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 12; spacing: 12
                RowLayout {
                    Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 0; spacing: 8
                    Item {
                        Layout.preferredWidth: root.compact ? 86 : root.width >= 410 ? 145 : 110
                        Layout.fillHeight: true
                        Rectangle {
                            anchors.centerIn: parent; width: parent.width * .85; height: width; radius: width / 2
                            color: "#251a3c"; border.color: "#7143a8"; border.width: 1
                            Rectangle { anchors.fill: parent; anchors.margins: 7; radius: width / 2; color: "#302044"; border.color: "#58317f" }
                        }
                        WorkforcePortrait { anchors.fill: parent; agent: root.agent; framed: false; size: parent.width }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.minimumWidth: 0; Layout.minimumHeight: 0; spacing: root.compact ? 5 : 8
                        RowLayout {
                            Layout.fillWidth: true
                            Rectangle {
                                implicitWidth: statusText.implicitWidth + 18; implicitHeight: 25; radius: 9
                                color: Qt.rgba(root.presenceColor.r, root.presenceColor.g, root.presenceColor.b, .17)
                                MokaidLabel { id: statusText; anchors.centerIn: parent; text: root.presence; font.pixelSize: 11; font.weight: Font.DemiBold; color: root.presenceColor }
                            }
                            Item { Layout.fillWidth: true }
                            MokaidIconButton { objectName: "agentDetailClose"; iconName: "close"; hint: "Close agent details"; subtle: true; implicitWidth: 32; implicitHeight: 32; onClicked: root.closed() }
                        }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 5
                            MokaidLabel { Layout.fillWidth: true; Layout.minimumWidth: 0; text: root.agent.display_name || "Agent"; font.pixelSize: root.compact ? 21 : 25; font.weight: Font.Bold; elide: Text.ElideRight }
                            Rectangle {
                                implicitWidth: levelText.implicitWidth + 15; implicitHeight: 26; radius: 9; color: "#2c1d44"; border.color: "#8250c1"
                                MokaidLabel { id: levelText; anchors.centerIn: parent; text: "Lv. " + (root.agent.level || 1); font.pixelSize: 10; font.weight: Font.DemiBold; color: "#e0c7ff" }
                            }
                        }
                        MokaidLabel { Layout.fillWidth: true; text: root.agent.role_title || (root.agent.kind === "human_linked" ? "Team member" : "AI agent"); color: Theme.secondary; font.pixelSize: 12; elide: Text.ElideRight }
                        MokaidLabel {
                            visible: !root.compact; Layout.fillWidth: true
                            text: root.agent.instructions || "Ready to help with your next mission."
                            color: Theme.secondary; font.pixelSize: 12; lineHeight: 1.25; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
                        }
                        Flow {
                            visible: !root.compact && root.skills.length > 0; Layout.fillWidth: true; spacing: 5
                            Repeater {
                                model: root.skills.slice(0, root.width < 410 ? 2 : 3)
                                Rectangle {
                                    required property string modelData
                                    width: Math.min(tagText.implicitWidth + 16, 90); height: 24; radius: 9; color: "#25283a"
                                    MokaidLabel { id: tagText; anchors.fill: parent; anchors.margins: 6; text: parent.modelData; font.pixelSize: 10; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter }
                                }
                            }
                            MokaidButton { visible: root.skills.length > (root.width < 410 ? 2 : 3); text: "+" + (root.skills.length - (root.width < 410 ? 2 : 3)); implicitHeight: 24; implicitWidth: 30; leftPadding: 5; rightPadding: 5; font.pixelSize: 10; Accessible.name: "View all agent skills"; onClicked: root.selectTab(2) }
                        }
                        Item { Layout.fillHeight: true; visible: !root.compact }
                    }
                }
                Rectangle {
                    visible: !root.chatOpen && !root.tight
                    objectName: "agentDetailMetrics"
                    Layout.fillWidth: true; Layout.preferredHeight: 60; radius: 11; color: "#11141f"; border.color: Theme.divider
                    RowLayout {
                        anchors.fill: parent; spacing: 0
                        Metric { Layout.fillWidth: true; Layout.preferredWidth: 1; value: root.agent.missions_completed !== undefined ? String(root.agent.missions_completed) : "—"; label: "Missions done"; iconName: "tasks"; accent: Theme.success; hint: "Completed missions recorded for this agent." }
                        Rectangle { implicitWidth: 1; Layout.preferredHeight: 42; color: Theme.divider }
                        Metric { Layout.fillWidth: true; Layout.preferredWidth: 1; value: root.agent.performance_score !== undefined && root.agent.performance_score !== null ? Math.round(Number(root.agent.performance_score)) + "%" : "—"; label: "Performance"; iconName: "shield"; accent: Theme.primary; hint: "Recorded performance score. Unrated agents display a dash." }
                        Rectangle { implicitWidth: 1; Layout.preferredHeight: 42; color: Theme.divider }
                        Metric { Layout.fillWidth: true; Layout.preferredWidth: 1; value: root.averageDuration; label: "Avg. duration"; iconName: "clock"; accent: "#7898ff"; hint: "Average duration of completed assigned tasks with recorded start and completion times." }
                    }
                }
            }
        }
        Surface {
            Layout.fillWidth: true; Layout.preferredHeight: root.tight ? 46 : 50
            RowLayout {
                anchors.fill: parent; anchors.margins: 5; spacing: 2
                Repeater {
                    model: ["Overview", "Tasks", "Knowledge", "Settings"]
                    MokaidButton {
                        required property string modelData; required property int index
                        objectName: "agentTab_" + index
                        Layout.fillWidth: true; Layout.preferredWidth: 1; implicitWidth: 0; implicitHeight: 40; leftPadding: 2; rightPadding: 2
                        text: modelData; font.pixelSize: root.width < 380 ? 11 : 12
                        highlighted: !root.chatOpen && root.currentTab === index; quiet: !highlighted
                        Accessible.role: Accessible.PageTab; Accessible.selected: highlighted
                        onClicked: root.selectTab(index)
                        Keys.onRightPressed: { const next = (index + 1) % 4; root.selectTab(next); parent.children[next].forceActiveFocus() }
                        Keys.onLeftPressed: { const next = (index + 3) % 4; root.selectTab(next); parent.children[next].forceActiveFocus() }
                    }
                }
            }
        }
        MokaidLabel { visible: !session.online; Layout.fillWidth: true; text: "Offline · Showing saved information"; color: Theme.warning; font.pixelSize: 11; wrapMode: Text.Wrap }
        RowLayout {
            visible: !!features.error && !root.chatOpen && root.currentTab === 0
            Layout.fillWidth: true; spacing: 8
            MokaidLabel { Layout.fillWidth: true; text: features.error || ""; color: Theme.warning; font.pixelSize: 11; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
            MokaidButton { text: "Retry"; implicitHeight: 32; implicitWidth: 64; enabled: session.online && !features.busy; onClicked: features.select(root.agent.id) }
        }
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 80
            ScrollView {
                id: overviewScroll
                visible: root.currentTab === 0 && !root.chatOpen
                anchors.fill: parent; contentWidth: availableWidth; clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ColumnLayout {
                    width: overviewScroll.availableWidth; spacing: 10
                    Surface {
                        Layout.fillWidth: true; Layout.preferredHeight: activityContent.implicitHeight + 24
                        ColumnLayout {
                            id: activityContent; anchors.fill: parent; anchors.margins: 12; spacing: 12
                            RowLayout {
                                Layout.fillWidth: true
                                MokaidLabel { Layout.fillWidth: true; text: "Current activity"; font.pixelSize: 13; font.weight: Font.DemiBold }
                                MokaidIconButton { visible: !!root.agent.current_task_id; implicitWidth: 24; implicitHeight: 24; subtle: true; iconName: "arrow-right"; hint: "Open current task"; onClicked: features.openRecord("tasks", root.agent.current_task_id) }
                            }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 12
                                Rectangle {
                                    implicitWidth: 48; implicitHeight: 50; radius: 19; color: "#492377"; border.color: "#9b56df"
                                    MokaidIcon { anchors.centerIn: parent; name: office.selectedAgent.id === root.agent.id && office.stream ? "chat" : root.agent.current_task_id ? "pulse" : "agents"; color: "#ebdaff"; size: 24 }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 5
                                    RowLayout {
                                        Layout.fillWidth: true
                                        MokaidLabel { Layout.fillWidth: true; text: office.selectedAgent.id === root.agent.id && office.stream ? "Typing a response…" : root.agent.current_task_id ? "Working on a mission" : root.presence === "Away" ? "Currently away" : "Ready for a new mission"; font.pixelSize: 12; elide: Text.ElideRight }
                                        MokaidLabel { text: root.relativeDate(root.currentTask.updated_at || root.agent.last_active_at); color: Theme.muted; font.pixelSize: 10 }
                                    }
                                    MokaidLabel { Layout.fillWidth: true; text: root.currentTask.title || (root.agent.current_task_id ? "Open the task to follow its progress." : "Send a message or assign a task to get started."); color: Theme.secondary; font.pixelSize: 11; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
                                    Rectangle {
                                        visible: root.progress >= 0; Layout.fillWidth: true; Layout.preferredHeight: 7; radius: 4; color: "#252337"
                                        Rectangle { width: parent.width * root.progress / 100; height: parent.height; radius: 4; color: "#aa45ee" }
                                        Accessible.name: "Task progress " + Math.round(root.progress) + " percent"
                                    }
                                }
                            }
                        }
                    }
                    Surface {
                        Layout.fillWidth: true; Layout.preferredHeight: recentContent.implicitHeight + 24
                        ColumnLayout {
                            id: recentContent; anchors.fill: parent; anchors.margins: 12; spacing: 4
                            RowLayout {
                                Layout.fillWidth: true; Layout.bottomMargin: 8
                                MokaidLabel { Layout.fillWidth: true; text: "Recent tasks"; font.pixelSize: 13; font.weight: Font.DemiBold }
                                MokaidButton { objectName: "agentDetailViewTasks"; text: "View all"; iconName: "arrow-right"; quiet: true; implicitHeight: 30; implicitWidth: 92; leftPadding: 4; rightPadding: 4; font.pixelSize: 11; onClicked: root.selectTab(1) }
                            }
                            Repeater {
                                model: root.recentTasks
                                AbstractButton {
                                    id: taskRow; required property var modelData
                                    objectName: "agentRecentTask_" + modelData.id
                                    Layout.fillWidth: true; implicitHeight: 46; hoverEnabled: true
                                    onClicked: features.openRecord("tasks", modelData.id)
                                    Accessible.name: (modelData.title || "Task") + ", " + root.taskStatus(modelData)
                                    background: Rectangle { radius: 8; color: taskRow.hovered ? Theme.hover : "transparent"; border.color: taskRow.visualFocus ? Theme.focusBorder : "transparent" }
                                    contentItem: RowLayout {
                                        spacing: 12
                                        Rectangle {
                                            Layout.leftMargin: 4; implicitWidth: 18; implicitHeight: 18; radius: 9
                                            color: taskRow.modelData.status === "completed" ? Theme.success : "transparent"; border.color: root.taskColor(taskRow.modelData); border.width: 2
                                            MokaidIcon { anchors.centerIn: parent; visible: taskRow.modelData.status === "completed"; name: "check"; color: "#11352c"; size: 13 }
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true; spacing: 5
                                            MokaidLabel { Layout.fillWidth: true; text: taskRow.modelData.title || "Untitled task"; elide: Text.ElideRight; font.pixelSize: 12 }
                                            RowLayout {
                                                spacing: 4
                                                MokaidLabel { text: root.taskStatus(taskRow.modelData); color: root.taskColor(taskRow.modelData); font.pixelSize: 11 }
                                                MokaidLabel { text: root.relativeDate(taskRow.modelData.completed_at || taskRow.modelData.updated_at || taskRow.modelData.inserted_at); color: Theme.muted; font.pixelSize: 11 }
                                            }
                                        }
                                        MokaidIcon { name: "chevron-right"; color: Theme.muted; size: 15 }
                                    }
                                }
                            }
                            BusyIndicator { Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: 28; Layout.preferredHeight: 28; running: features.selectedAgentTasksState === "loading"; visible: running }
                            MokaidLabel {
                                visible: root.recentTasks.length === 0 && features.selectedAgentTasksState !== "loading"
                                Layout.fillWidth: true; Layout.topMargin: 14; Layout.bottomMargin: 14; wrapMode: Text.Wrap; color: Theme.secondary; font.pixelSize: 12
                                text: root.tasksReady ? "No tasks yet. Give this agent a first mission." : "Tasks are unavailable. Refresh to try again."
                            }
                            MokaidButton { visible: !root.tasksReady && features.selectedAgentTasksState !== "loading"; text: "Refresh tasks"; iconName: "refresh"; Layout.fillWidth: true; enabled: session.online && !features.busy; onClicked: features.select(root.agent.id) }
                        }
                    }
                }
            }
            Surface {
                anchors.fill: parent; visible: root.currentTab > 0 && !root.chatOpen
                AgentDetailContent {
                    id: detailContent
                    anchors.fill: parent; anchors.margins: 12
                    agent: root.agent; tabIndex: root.currentTab
                    onActionRequested: function(action) { root.actionRequested(action) }
                }
            }
            ChatPanel { anchors.fill: parent; visible: root.chatOpen; enabled: visible; compact: true; embedded: true; onOverviewRequested: root.chatOpen = false }
        }
        Surface {
            objectName: "agentDetailFooter"
            Layout.fillWidth: true; Layout.preferredHeight: root.tight ? 82 : 94
            RowLayout {
                anchors.fill: parent; anchors.margins: 8; spacing: 2
                FooterAction { id: chatAction; objectName: "agentDetailChat"; Layout.fillWidth: true; text: "Chat"; iconName: "chat"; selected: root.chatOpen || root.currentTab === 0; onClicked: { if (office.selectedAgent.id !== root.agent.id) office.selectAgent(root.agent.id); root.chatOpen = !root.chatOpen } }
                FooterAction { objectName: "agentDetailAssign"; Layout.fillWidth: true; text: "Assign task"; iconName: "projects"; enabled: !!root.agent.id && session.online && root.agent.kind !== "human_linked"; onClicked: missions.beginForAgent(root.agent.id) }
                FooterAction { objectName: "agentDetailUpload"; Layout.fillWidth: true; text: "Upload file"; iconName: "upload"; enabled: root.action("upload").enabled; onClicked: root.runAction("upload") }
                FooterAction { objectName: "agentDetailRent"; Layout.fillWidth: true; text: "Rent out"; iconName: "marketplace"; enabled: session.online && root.agent.kind === "ai"; onClicked: features.openMarketplaceOffer(root.agent.id, "rent") }
                FooterAction { objectName: "agentDetailMore"; Layout.fillWidth: true; text: "More"; iconName: "more"; onClicked: moreMenu.openFor(this) }
            }
        }
    }
    MokaidMenu {
        id: moreMenu
        MokaidMenu.Entry { objectName: "agentDetailPerformance"; text: "View performance"; onTriggered: features.openRecord("agent-performance", root.agent.id) }
        MokaidMenu.Entry { text: "Edit agent settings"; onTriggered: root.selectTab(3) }
        MokaidMenu.Entry { text: "Skills and training"; onTriggered: root.selectTab(2) }
        MokaidMenu.Entry { text: "Sell copies"; enabled: session.online && root.agent.kind === "ai"; onTriggered: features.openMarketplaceOffer(root.agent.id, "sale") }
        MokaidMenu.Separator { }
        MokaidMenu.Entry { text: "Copy to another workspace…"; enabled: root.action("transfer").enabled; onTriggered: root.runAction("transfer") }
        MokaidMenu.Entry { text: "Remove agent…"; destructive: true; enabled: root.action("delete").enabled; onTriggered: root.runAction("delete") }
    }
}
