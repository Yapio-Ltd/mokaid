pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQml.Models
import QtQuick.Shapes

Item {
    id: root
    objectName: "agentsPage"
    clip: true
    signal actionRequested(var action)
    property string statusFilter: "all"
    property bool gridMode: false
    property int inspectorTab: 0
    property bool reportOpen: false
    property string reportTitle: ""
    property string observedSelection: ""
    property bool initialSelectionMade: false
    property double now: Date.now()
    readonly property var allAgents: features.allRecords
    readonly property var filteredAgents: {
        const agents = features.visibleRecords
        return agents.filter(function(agent) {
            return root.statusFilter === "all" || root.statusGroup(agent) === root.statusFilter
        })
    }
    readonly property var selectedAgent: {
        if (!features.selectedId) return ({})
        const rows = allAgents
        let record = rows.find(function(agent) { return agent.id === features.selectedId }) || ({})
        if (features.selectedRecord.id === features.selectedId)
            record = Object.assign({}, record, features.selectedRecord)
        return record
    }
    readonly property bool hasSelection: Boolean(selectedAgent.id)
    readonly property var inspectorTaskBars: activityBars(selectedAgent)
    readonly property var inspectorMissionBars: missionBars(selectedAgent)
    readonly property string inspectorCurrentTask: currentTaskText(selectedAgent)
    readonly property string inspectorMissionNote: missionNote(selectedAgent)
    readonly property real inspectorPerformanceMeter: performanceMeter(selectedAgent)
    readonly property var summary: {
        let active = 0, idle = 0, training = 0, completed = 0, scoreTotal = 0, rated = 0
        let added = 0
        const today = new Date(now)
        for (const agent of allAgents) {
            const group = statusGroup(agent)
            if (group === "active") active++
            if (group === "idle") idle++
            if (group === "training") training++
            completed += Number(agent.missions_completed || 0)
            if (hasScore(agent)) { scoreTotal += Number(agent.performance_score); rated++ }
            const created = new Date(agent.inserted_at || "")
            if (created.getFullYear() === today.getFullYear() && created.getMonth() === today.getMonth()) added++
        }
        return { total: allAgents.length, active: active, idle: idle, training: training,
            completed: completed, score: rated ? Math.round(scoreTotal / rated) : null, rated: rated, added: added }
    }
    readonly property color panelBorder: "#27263d"
    readonly property color panelSurface: "#11121e"
    readonly property color supportingText: "#adb6d4"

    function statusGroup(agent) {
        const value = String(agent.status || "").toLowerCase()
        return value === "active" || value === "busy" ? "active" : value
    }
    function statusName(agent) {
        const value = String(agent.status || "unknown").replace(/_/g, " ")
        return value.charAt(0).toUpperCase() + value.slice(1)
    }
    function statusColor(agent) {
        const status = String(agent.status || "")
        if (status === "active") return "#38e5af"
        if (status === "idle") return "#55beff"
        if (["training", "busy", "waiting"].indexOf(status) >= 0) return "#f2b45e"
        if (status === "blocked") return "#ff91a9"
        return "#b0bad5"
    }
    function hasScore(agent) {
        return agent.performance_score !== undefined && agent.performance_score !== null
            && agent.performance_score !== "" && isFinite(Number(agent.performance_score))
    }
    function tasksReady(agent) {
        return Boolean(agent && agent.id) && features.selectedId === agent.id && features.selectedAgentTasksState === "ready"
    }
    function assignedTasks(agent) {
        if (!tasksReady(agent)) return []
        return (features.selectedAgentTasks || []).filter(function(task) {
            return task && task.assigned_agent_id === agent.id
        })
    }
    function activeTasks(agent) {
        return assignedTasks(agent).filter(function(task) {
            return task.status !== "completed" && task.status !== "canceled"
        })
    }
    function performanceMeter(agent) {
        return hasScore(agent) ? Math.max(0, Math.min(1, Number(agent.performance_score) / 100)) : -1
    }
    function activityBars(agent) {
        if (!tasksReady(agent)) return []
        return activeTasks(agent).slice(0, 8).map(function(task) {
            const progress = Number(task.progress_percent)
            return isFinite(progress) ? Math.max(0, Math.min(1, progress / 100)) : 0
        })
    }
    function missionBars(agent) {
        if (!tasksReady(agent)) return []
        const days = 8
        const today = new Date(now)
        const end = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate())
        const start = end - (days - 1) * 86400000
        const buckets = []
        for (let i = 0; i < days; ++i) buckets.push(0)
        for (const task of assignedTasks(agent)) {
            if (task.status !== "completed" || !task.completed_at) continue
            const completedAt = Date.parse(task.completed_at)
            if (!isFinite(completedAt) || completedAt < start || completedAt > end + 86400000 - 1) continue
            const index = Math.floor((completedAt - start) / 86400000)
            if (index >= 0 && index < days) buckets[index]++
        }
        const peak = Math.max.apply(null, buckets)
        if (peak <= 0) return []
        return buckets.map(function(count) { return count / peak })
    }
    function currentTaskText(agent) {
        if (!agent || !agent.id) return "—"
        if (features.selectedId === agent.id && features.selectedAgentTasksState === "loading") return "—"
        if (tasksReady(agent)) {
            const count = activeTasks(agent).length
            return count > 0 ? String(count) : "—"
        }
        return agent.current_task_id ? "1" : "—"
    }
    function currentTaskNote(agent) {
        if (!agent || !agent.id) return "No current task"
        if (features.selectedId === agent.id && features.selectedAgentTasksState === "loading") return "Loading tasks"
        if (features.selectedId === agent.id && features.selectedAgentTasksState === "unavailable") return "Task progress unavailable"
        if (tasksReady(agent)) {
            const count = activeTasks(agent).length
            if (count === 0) return "No current task"
            return count === 1 ? "Assigned task" : count + " active tasks"
        }
        return agent.current_task_id ? "Assigned task" : "No current task"
    }
    function missionNote(agent) {
        return tasksReady(agent) ? "Last 8 days" : "All time"
    }
    function scoreText(agent) { return hasScore(agent) ? Math.round(Number(agent.performance_score)) + "%" : "—" }
    function skillNames(agent) {
        return (agent.skills || []).map(function(skill) {
            return typeof skill === "string" ? skill : String(skill.name || skill.label || skill.key || "")
        }).filter(function(skill) { return skill.length > 0 })
    }
    function relativeDate(value) {
        if (!value) return "Never"
        const date = new Date(value)
        if (isNaN(date.getTime())) return "Not available"
        const minutes = Math.floor((now - date.getTime()) / 60000)
        if (minutes < 0) return Qt.formatDateTime(date, "MMM d, yyyy")
        if (minutes < 1) return "Just now"
        if (minutes < 60) return minutes + " min ago"
        if (minutes < 1440) return Math.floor(minutes / 60) + (minutes < 120 ? " hour ago" : " hours ago")
        if (minutes < 10080) return Math.floor(minutes / 1440) + (minutes < 2880 ? " day ago" : " days ago")
        return Qt.formatDateTime(date, "MMM d, yyyy")
    }
    function activityText(agent) {
        if (agent.current_task_id) return "Working on a task"
        if (agent.status === "training") return "Training in progress"
        if (!agent.last_active_at) return "No activity yet"
        return agent.office_activity ? String(agent.office_activity).replace(/_/g, " ") : "No current task"
    }
    function action(id) {
        return features.actions.find(function(item) { return item.id === id }) || ({enabled: false})
    }
    function runAction(id) {
        if (id === "create") { features.navigate("agent-new"); return }
        const next = action(id)
        if (!next.enabled) return
        if (["training", "progression", "permissions", "schedules"].indexOf(id) >= 0) {
            reportOpen = true
            reportTitle = next.title
        }
        actionRequested(next)
    }
    function selectAgent(agent) {
        reportOpen = false
        inspectorTab = 0
        features.select(agent.id)
    }
    function closeInspector() {
        initialSelectionMade = true
        reportOpen = false
        features.clearSelection()
    }
    function considerInitialSelection() {
        if (features.currentPage !== "agents" || initialSelectionMade || features.busy || allAgents.length === 0) return
        initialSelectionMade = true
        if (!features.selectedId) selectAgent(allAgents[0])
    }
    Component.onCompleted: considerInitialSelection()
    Connections {
        target: features
        function onChanged() {
            root.considerInitialSelection()
            if (root.observedSelection !== features.selectedId) {
                root.observedSelection = features.selectedId
                root.inspectorTab = 0
                root.reportOpen = false
            }
        }
    }
    Timer { interval: 60000; running: root.visible; repeat: true; onTriggered: root.now = Date.now() }

    Canvas {
        z: 0
        anchors.fill: parent
        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            const top = ctx.createRadialGradient(width - 36, 8, 0, width - 36, 8, 260)
            top.addColorStop(0, "rgba(168, 114, 255, 0.16)")
            top.addColorStop(0.42, "rgba(120, 74, 220, 0.05)")
            top.addColorStop(1, "rgba(120, 74, 220, 0)")
            ctx.fillStyle = top
            ctx.fillRect(0, 0, width, height)
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    component StatusBadge: Rectangle {
        id: badge
        property var agent: ({})
        property bool compact: false
        implicitWidth: badgeContents.implicitWidth + (compact ? 14 : 20)
        implicitHeight: compact ? 28 : 32
        radius: 8
        color: Qt.rgba(root.statusColor(agent).r, root.statusColor(agent).g, root.statusColor(agent).b, .1)
        RowLayout {
            id: badgeContents
            anchors.centerIn: parent
            spacing: 6
            Rectangle { implicitWidth: 7; implicitHeight: 7; radius: 4; color: root.statusColor(badge.agent) }
            MokaidLabel { text: root.statusName(badge.agent); font.pixelSize: 11; font.weight: Font.Medium; color: root.statusColor(badge.agent) }
        }
    }
    component SkillTag: Rectangle {
        id: tag
        property string label: ""
        property real maximumWidth: 140
        implicitWidth: Math.min(tagLabel.implicitWidth + 14, maximumWidth)
        implicitHeight: 23
        radius: 5
        color: "#1d2031"
        MokaidLabel { id: tagLabel; anchors.fill: parent; anchors.leftMargin: 7; anchors.rightMargin: 7; text: tag.label; color: "#b8c2e1"; font.pixelSize: 10; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
        ToolTip.visible: tagHover.hovered && tagLabel.truncated
        ToolTip.text: label
        HoverHandler { id: tagHover }
    }
    component SmallHeading: MokaidLabel {
        font.pixelSize: 12
        font.weight: Font.DemiBold
        Layout.fillWidth: true
        Layout.topMargin: 8
    }
    component MetaLine: RowLayout {
        id: line
        property string label: ""
        property string value: ""
        Layout.fillWidth: true
        spacing: 14
        MokaidLabel { text: line.label; color: root.supportingText; font.pixelSize: 11; Layout.preferredWidth: 100 }
        MokaidLabel { text: line.value; color: Theme.text; font.pixelSize: 11; Layout.fillWidth: true; wrapMode: Text.Wrap }
    }
    component TrendChart: Canvas {
        id: chart
        property var samples: []
        property color ink: "#7eb6ff"
        property string mode: "line"
        property real meter: -1
        antialiasing: true
        onSamplesChanged: requestPaint()
        onInkChanged: requestPaint()
        onModeChanged: requestPaint()
        onMeterChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const ctx = chart.getContext("2d")
            ctx.clearRect(0, 0, chart.width, chart.height)
            ctx.globalAlpha = 1
            ctx.setLineDash([])
            if (chart.width < 2 || chart.height < 2) return
            const values = chart.samples || []
            if (chart.mode === "meter") {
                if (!(chart.meter >= 0)) {
                    ctx.strokeStyle = chart.ink
                    ctx.globalAlpha = 0.35
                    ctx.lineWidth = 1
                    ctx.setLineDash([2, 3])
                    ctx.beginPath()
                    ctx.moveTo(1, chart.height - 2)
                    ctx.lineTo(chart.width - 1, chart.height - 2)
                    ctx.stroke()
                    return
                }
                const segments = 8
                const score = Math.max(0, Math.min(1, chart.meter))
                const gap = Math.max(2, chart.width * 0.04)
                const barWidth = Math.max(2, (chart.width - gap * (segments - 1)) / segments)
                for (let i = 0; i < segments; ++i) {
                    const barHeight = 4 + (i / (segments - 1)) * (chart.height - 6)
                    const x = i * (barWidth + gap)
                    const y = chart.height - barHeight
                    const radius = Math.min(1.5, barWidth / 2, barHeight / 2)
                    ctx.beginPath()
                    ctx.moveTo(x, chart.height)
                    ctx.lineTo(x, y + radius)
                    ctx.arcTo(x, y, x + radius, y, radius)
                    ctx.lineTo(x + barWidth - radius, y)
                    ctx.arcTo(x + barWidth, y, x + barWidth, y + radius, radius)
                    ctx.lineTo(x + barWidth, chart.height)
                    ctx.closePath()
                    ctx.fillStyle = chart.ink
                    ctx.globalAlpha = 0.16
                    ctx.fill()
                    const filled = Math.max(0, Math.min(1, score * segments - i))
                    if (filled <= 0) continue
                    ctx.globalAlpha = 0.9
                    ctx.fillRect(x, y, Math.max(1, barWidth * filled), barHeight)
                }
                return
            }
            if (chart.mode === "bars") {
                if (values.length === 0) {
                    ctx.strokeStyle = chart.ink
                    ctx.globalAlpha = 0.35
                    ctx.lineWidth = 1
                    ctx.setLineDash([2, 3])
                    ctx.beginPath()
                    ctx.moveTo(1, chart.height - 2)
                    ctx.lineTo(chart.width - 1, chart.height - 2)
                    ctx.stroke()
                    return
                }
                const gap = Math.max(2, chart.width * 0.08)
                const barWidth = Math.min(10, Math.max(3, (chart.width - gap * (values.length - 1)) / values.length))
                const used = values.length * barWidth + gap * (values.length - 1)
                const origin = Math.max(0, chart.width - used)
                for (let i = 0; i < values.length; ++i) {
                    const sample = Math.max(0, Math.min(1, Number(values[i]) || 0))
                    const x = origin + i * (barWidth + gap)
                    const radius = Math.min(1.5, barWidth / 2)
                    ctx.beginPath()
                    ctx.moveTo(x, chart.height)
                    ctx.lineTo(x, 1 + radius)
                    ctx.arcTo(x, 1, x + radius, 1, radius)
                    ctx.lineTo(x + barWidth - radius, 1)
                    ctx.arcTo(x + barWidth, 1, x + barWidth, 1 + radius, radius)
                    ctx.lineTo(x + barWidth, chart.height)
                    ctx.closePath()
                    ctx.fillStyle = chart.ink
                    ctx.globalAlpha = 0.14
                    ctx.fill()
                    const barHeight = sample * (chart.height - 2)
                    if (barHeight <= 0.5) continue
                    const y = chart.height - barHeight
                    ctx.beginPath()
                    ctx.moveTo(x, chart.height)
                    ctx.lineTo(x, y + radius)
                    ctx.arcTo(x, y, x + radius, y, radius)
                    ctx.lineTo(x + barWidth - radius, y)
                    ctx.arcTo(x + barWidth, y, x + barWidth, y + radius, radius)
                    ctx.lineTo(x + barWidth, chart.height)
                    ctx.closePath()
                    ctx.globalAlpha = 0.9
                    ctx.fill()
                }
                return
            }
            if (values.length < 2) {
                ctx.strokeStyle = chart.ink
                ctx.globalAlpha = 0.35
                ctx.lineWidth = 1
                ctx.setLineDash([2, 3])
                ctx.beginPath()
                ctx.moveTo(1, chart.height - 2)
                ctx.lineTo(chart.width - 1, chart.height - 2)
                ctx.stroke()
                return
            }
            const baseline = chart.height - 1
            const points = values.map(function(sample, index) {
                return {
                    x: 1 + (index / (values.length - 1)) * (chart.width - 2),
                    y: baseline - sample * (chart.height - 3)
                }
            })
            ctx.beginPath()
            ctx.moveTo(points[0].x, points[0].y)
            for (let i = 1; i < points.length; ++i) {
                const previous = points[i - 1]
                const point = points[i]
                const middle = (previous.x + point.x) / 2
                ctx.bezierCurveTo(middle, previous.y, middle, point.y, point.x, point.y)
            }
            ctx.strokeStyle = chart.ink
            ctx.lineWidth = 1.6
            ctx.lineJoin = "round"
            ctx.lineCap = "round"
            ctx.globalAlpha = 1
            ctx.stroke()
            ctx.lineTo(points[points.length - 1].x, baseline)
            ctx.lineTo(points[0].x, baseline)
            ctx.closePath()
            ctx.fillStyle = chart.ink
            ctx.globalAlpha = 0.16
            ctx.fill()
        }
    }
    component DetailMetric: Rectangle {
        id: metric
        property string value: ""
        property string label: ""
        property string note: ""
        property real percentage: -1
        property color accent: "#a385ff"
        property string chart: "line"
        property var series: []
        property real meter: -1
        Layout.fillWidth: true
        Layout.preferredHeight: 124
        radius: 12
        border.color: "#343056"
        gradient: Gradient {
            GradientStop { position: 0; color: "#1a1830" }
            GradientStop { position: 1; color: "#121422" }
        }
        ColumnLayout {
            anchors.fill: parent; anchors.margins: 10; spacing: 2
            MokaidLabel { text: metric.value; font.pixelSize: 22; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
            MokaidLabel { text: metric.label; font.pixelSize: 10; color: root.supportingText; Layout.fillWidth: true; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
            Item { Layout.preferredHeight: 4 }
            TrendChart {
                Layout.fillWidth: true
                Layout.preferredHeight: 32
                samples: metric.series
                ink: metric.accent
                mode: metric.chart
                meter: metric.meter
                Accessible.name: metric.label
            }
            MokaidLabel { text: metric.note; font.pixelSize: 9; color: "#a5afcd"; Layout.fillWidth: true; elide: Text.ElideRight }
        }
    }
    component SummaryMetric: Rectangle {
        id: metric
        property string value: ""
        property string label: ""
        property string note: ""
        property string icon: "agents"
        property color accent: "#b484ff"
        Layout.fillWidth: true
        Layout.preferredHeight: width < 115 ? 86 : root.height < 700 ? 84 : 103
        radius: 12
        color: Qt.rgba(accent.r, accent.g, accent.b, .07)
        RowLayout {
            anchors.fill: parent; anchors.margins: root.height < 700 ? 10 : 13; spacing: 10
            Rectangle {
                visible: metric.width >= 165
                Layout.preferredWidth: 40; Layout.preferredHeight: 44; Layout.alignment: Qt.AlignTop
                radius: 11; color: Qt.rgba(metric.accent.r, metric.accent.g, metric.accent.b, .12)
                border.color: Qt.rgba(metric.accent.r, metric.accent.g, metric.accent.b, .22)
                MokaidIcon { anchors.centerIn: parent; size: 22; name: metric.icon; color: metric.accent }
            }
            ColumnLayout {
                Layout.fillWidth: true; spacing: 6
                MokaidLabel { text: metric.value; color: metric.accent; font.pixelSize: metric.width < 115 ? 20 : 23; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                MokaidLabel { text: metric.label; color: "#c4c7df"; font.pixelSize: metric.width < 115 ? 9 : 10; Layout.fillWidth: true; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
                MokaidLabel { visible: metric.width >= 115; text: metric.note; color: metric.accent; font.pixelSize: 9; opacity: .9; Layout.fillWidth: true; elide: Text.ElideRight }
            }
        }
    }

    ColumnLayout {
        z: 1
        anchors.fill: parent
        anchors.leftMargin: 0; anchors.rightMargin: 0
        anchors.topMargin: 8; anchors.bottomMargin: 12
        spacing: 18
        RowLayout {
            Layout.fillWidth: true; spacing: 18
            ColumnLayout {
                Layout.fillWidth: true; spacing: 7
                MokaidLabel { text: "AGENTS"; color: "#a2a6c6"; font.pixelSize: 10; font.letterSpacing: 1.1 }
                MokaidLabel { text: "Your AI workforce"; font.pixelSize: root.width < 900 ? 28 : 32; font.weight: Font.Bold; font.letterSpacing: -.5; Layout.fillWidth: true; elide: Text.ElideRight }
                MokaidLabel { text: features.offline ? "Saved workforce · offline" : "Build, manage and scale your team of AI agents."; color: root.supportingText; font.pixelSize: 13; Layout.fillWidth: true; wrapMode: Text.Wrap }
            }
            MokaidButton {
                text: "Create agent"; iconName: "plus"; highlighted: true; implicitHeight: 45
                enabled: root.action("create").enabled
                onClicked: root.runAction("create")
            }
        }
        Rectangle {
            visible: features.error.length > 0
            Layout.fillWidth: true; Layout.preferredHeight: errorContent.implicitHeight + 20
            radius: 10; color: "#281d28"; border.color: "#59414c"
            RowLayout {
                id: errorContent; anchors.fill: parent; anchors.margins: 10; spacing: 12
                MokaidLabel { text: features.error; color: Theme.warning; Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12 }
                MokaidButton { text: "Retry"; implicitHeight: 32; enabled: !features.busy; onClicked: features.refresh() }
            }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 18
            ColumnLayout {
                id: roster
                Layout.fillWidth: true; Layout.fillHeight: true
                Layout.minimumWidth: 300; spacing: 16
                readonly property bool showActivity: width >= 660
                readonly property bool showPerformance: width >= 540
                readonly property bool showCurrentTask: width >= 445
                GridLayout {
                    Layout.fillWidth: true; columns: roster.width >= 660 ? 2 : 1
                    columnSpacing: 18; rowSpacing: 10
                    RowLayout {
                        spacing: 6
                        Repeater {
                            model: [{key: "all", label: "All agents", count: root.summary.total},
                                {key: "active", label: "Active", count: root.summary.active},
                                {key: "idle", label: "Idle", count: root.summary.idle},
                                {key: "training", label: "Training", count: root.summary.training}]
                            MokaidButton {
                                id: filterButton
                                objectName: "agentFilter_" + modelData.key
                                required property var modelData
                                readonly property bool chosen: root.statusFilter === modelData.key
                                text: (roster.width < 400 && modelData.key === "all" ? "All" : modelData.label) + "  " + modelData.count
                                implicitWidth: contentItem.implicitWidth + 20; implicitHeight: 36
                                leftPadding: 10; rightPadding: 10; font.pixelSize: 11
                                highlighted: chosen
                                Accessible.name: modelData.label + ", " + modelData.count + " agents"
                                Accessible.checkable: true; Accessible.checked: chosen
                                onClicked: root.statusFilter = modelData.key
                            }
                        }
                        Item { Layout.fillWidth: true }
                    }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 7
                        Rectangle {
                            Layout.preferredWidth: 73; Layout.preferredHeight: 36; radius: 9
                            color: "#10121e"; border.color: root.panelBorder
                            Row {
                                anchors.fill: parent; anchors.margins: 2; spacing: 1
                                Repeater {
                                    model: [false, true]
                                    AbstractButton {
                                        id: viewButton
                                        objectName: modelData ? "agentGridMode" : "agentListMode"
                                        required property bool modelData
                                        width: 33; height: 32; hoverEnabled: true
                                        Accessible.name: modelData ? "Grid view" : "List view"
                                        Accessible.checkable: true; Accessible.checked: root.gridMode === modelData
                                        onClicked: root.gridMode = modelData
                                        background: Rectangle { radius: 7; color: root.gridMode === viewButton.modelData ? "#292941" : viewButton.hovered ? "#1c1e30" : "transparent"; border.color: viewButton.visualFocus ? Theme.focusBorder : "transparent" }
                                        contentItem: Item {
                                            Shape {
                                                anchors.centerIn: parent; width: 18; height: 18
                                                ShapePath {
                                                    strokeColor: root.gridMode === viewButton.modelData ? "#ece8ff" : "#8f9bbd"; strokeWidth: 1.3; fillColor: "transparent"
                                                    PathSvg { path: viewButton.modelData ? "M2 2H7V7H2ZM11 2H16V7H11ZM2 11H7V16H2ZM11 11H16V16H11Z" : "M1 3H3M6 3H17M1 9H3M6 9H17M1 15H3M6 15H17" }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        MokaidTextField {
                            id: agentSearch
                            objectName: "agentSearch"
                            Layout.fillWidth: true; Layout.minimumWidth: 120
                            implicitHeight: 36; leftPadding: 30; topPadding: 7; bottomPadding: 7; font.pixelSize: 11
                            placeholderText: "Search agents…"
                            Accessible.name: "Search agents by name, role or skill"
                            onTextEdited: features.search(text)
                            MokaidIcon { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter; name: "search"; size: 13; color: "#9ba8c7" }
                        }
                        MokaidButton { iconName: "refresh"; implicitWidth: 34; implicitHeight: 36; leftPadding: 8; rightPadding: 8; quiet: true; enabled: !features.busy; Accessible.name: "Refresh agents"; ToolTip.visible: hovered; ToolTip.text: "Refresh agents"; onClicked: features.refresh() }
                    }
                }
                Rectangle {
                    id: rosterPanel
                    objectName: "agentRosterPanel"
                    Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 145
                    radius: 13; color: "#a610111b"; border.color: root.panelBorder
                    ColumnLayout {
                        anchors.fill: parent; spacing: 0
                        RowLayout {
                            visible: !root.gridMode
                            Layout.fillWidth: true; Layout.preferredHeight: 38; Layout.leftMargin: 16; Layout.rightMargin: 14; spacing: 12
                            MokaidLabel { text: "AGENT"; color: root.supportingText; font.pixelSize: 9; font.weight: Font.Medium; Layout.fillWidth: true }
                            MokaidLabel { text: "STATUS"; color: root.supportingText; font.pixelSize: 9; Layout.preferredWidth: 74; Layout.minimumWidth: 74; Layout.maximumWidth: 74 }
                            MokaidLabel { visible: roster.showCurrentTask; text: "CURRENT"; color: root.supportingText; font.pixelSize: 9; Layout.preferredWidth: 55; Layout.minimumWidth: 55; Layout.maximumWidth: 55 }
                            MokaidLabel { visible: roster.showPerformance; text: "PERFORMANCE"; color: root.supportingText; font.pixelSize: 9; Layout.preferredWidth: 108; Layout.minimumWidth: 108; Layout.maximumWidth: 108 }
                            MokaidLabel { visible: roster.showActivity; text: "LAST ACTIVITY"; color: root.supportingText; font.pixelSize: 9; Layout.preferredWidth: 110; Layout.minimumWidth: 110; Layout.maximumWidth: 110 }
                            Item { Layout.preferredWidth: 24 }
                        }
                        ListView {
                            id: agentList
                            visible: !root.gridMode
                            Layout.fillWidth: true; Layout.fillHeight: true
                            model: root.filteredAgents; clip: true; reuseItems: true
                            delegate: ItemDelegate {
                                id: agentRow
                                objectName: "agentRow_" + modelData.id
                                required property var modelData
                                width: agentList.width; height: 93; hoverEnabled: true
                                highlighted: features.selectedId === modelData.id
                                leftPadding: 15; rightPadding: 12
                                Accessible.name: modelData.display_name + ", " + (modelData.role_title || "Agent") + ", " + root.statusName(modelData)
                                background: Rectangle {
                                    radius: 10
                                    gradient: Gradient {
                                        GradientStop { position: 0; color: agentRow.highlighted ? "#1b1a32" : agentRow.hovered ? "#171827" : "#13141f" }
                                        GradientStop { position: 1; color: agentRow.highlighted ? "#171a2c" : agentRow.hovered ? "#171827" : "#10121b" }
                                    }
                                    border.width: 1
                                    border.color: agentRow.visualFocus ? Theme.focusBorder : agentRow.highlighted ? "#6450aa" : "#1b1e2f"
                                }
                                contentItem: RowLayout {
                                    spacing: 12
                                    WorkforcePortrait { agent: agentRow.modelData; size: roster.width < 470 ? 43 : 55; Layout.alignment: Qt.AlignVCenter }
                                    ColumnLayout {
                                        Layout.fillWidth: true; Layout.minimumWidth: 70; spacing: 5
                                        MokaidLabel { text: agentRow.modelData.display_name || "Unnamed agent"; font.pixelSize: 12; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                                        MokaidLabel { text: agentRow.modelData.role_title || "AI agent"; color: root.supportingText; font.pixelSize: 10; Layout.fillWidth: true; elide: Text.ElideRight }
                                        Row {
                                            Layout.fillWidth: true; spacing: 4; clip: true; Layout.preferredHeight: 20
                                            Repeater {
                                                model: root.skillNames(agentRow.modelData).slice(0, 3)
                                                SkillTag { required property string modelData; label: modelData; maximumWidth: roster.width < 660 ? 90 : 110; implicitHeight: 20 }
                                            }
                                            SkillTag { visible: root.skillNames(agentRow.modelData).length === 0 && Boolean(agentRow.modelData.department); label: agentRow.modelData.department || ""; implicitHeight: 20 }
                                        }
                                    }
                                    Item { Layout.preferredWidth: 74; Layout.minimumWidth: 74; Layout.maximumWidth: 74; Layout.fillHeight: true; StatusBadge { anchors.verticalCenter: parent.verticalCenter; agent: agentRow.modelData; compact: true } }
                                    ColumnLayout {
                                        visible: roster.showCurrentTask; Layout.preferredWidth: 55; Layout.minimumWidth: 55; Layout.maximumWidth: 55; spacing: 4
                                        MokaidLabel { text: agentRow.modelData.current_task_id ? "1" : "—"; font.pixelSize: 15; font.weight: Font.DemiBold }
                                        MokaidLabel { text: agentRow.modelData.current_task_id ? "task" : "No task"; color: root.supportingText; font.pixelSize: 9 }
                                    }
                                    RowLayout {
                                        visible: roster.showPerformance; Layout.preferredWidth: 108; Layout.minimumWidth: 108; Layout.maximumWidth: 108; spacing: 6
                                        TrendChart {
                                            visible: root.hasScore(agentRow.modelData)
                                            Layout.preferredWidth: 36; Layout.preferredHeight: 16
                                            mode: "meter"; meter: root.performanceMeter(agentRow.modelData)
                                            ink: "#6ec8ff"
                                        }
                                        MokaidLabel { text: root.scoreText(agentRow.modelData); color: root.hasScore(agentRow.modelData) ? "#bce8fa" : root.supportingText; font.pixelSize: 12; font.weight: Font.Medium; Layout.fillWidth: true; elide: Text.ElideRight }
                                    }
                                    ColumnLayout {
                                        visible: roster.showActivity; Layout.preferredWidth: 110; Layout.minimumWidth: 110; Layout.maximumWidth: 110; spacing: 5
                                        MokaidLabel { text: root.relativeDate(agentRow.modelData.last_active_at); font.pixelSize: 10; Layout.fillWidth: true; elide: Text.ElideRight }
                                        MokaidLabel { text: root.activityText(agentRow.modelData); color: root.supportingText; font.pixelSize: 9; Layout.fillWidth: true; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
                                    }
                                    MokaidButton {
                                        iconName: "more"; quiet: true; implicitWidth: 26; implicitHeight: 31; leftPadding: 4; rightPadding: 4
                                        Accessible.name: "Actions for " + agentRow.modelData.display_name
                                        objectName: "agentActions_" + agentRow.modelData.id
                                        onClicked: { root.selectAgent(agentRow.modelData); agentActions.openFor(this) }
                                    }
                                }
                                onClicked: root.selectAgent(modelData)
                                onDoubleClicked: { office.selectAgent(modelData.id); features.navigate("office") }
                            }
                            footer: MokaidButton { visible: features.hasMore; width: agentList.width; text: features.busy ? "Loading…" : "Load more agents"; enabled: !features.busy; onClicked: features.loadMore() }
                            ScrollBar.vertical: ScrollBar { }
                        }
                        GridView {
                            id: agentGrid
                            visible: root.gridMode
                            Layout.fillWidth: true; Layout.fillHeight: true; Layout.margins: 9
                            model: root.filteredAgents; clip: true; reuseItems: true
                            cellWidth: width / Math.max(1, Math.floor(width / 235)); cellHeight: 222
                            delegate: ItemDelegate {
                                id: agentTile
                                objectName: "agentTile_" + modelData.id
                                required property var modelData
                                width: agentGrid.cellWidth - 8; height: agentGrid.cellHeight - 8
                                padding: 15; hoverEnabled: true; highlighted: features.selectedId === modelData.id
                                Accessible.name: modelData.display_name + ", " + root.statusName(modelData)
                                background: Rectangle { radius: 12; color: agentTile.highlighted ? "#201d35" : agentTile.hovered ? "#1b1c2b" : "#141622"; border.color: agentTile.visualFocus ? Theme.focusBorder : agentTile.highlighted ? "#7055af" : "#2a293f" }
                                contentItem: ColumnLayout {
                                    spacing: 10
                                    RowLayout {
                                        Layout.fillWidth: true
                                        WorkforcePortrait { agent: agentTile.modelData; size: 49 }
                                        Item { Layout.fillWidth: true }
                                        StatusBadge { agent: agentTile.modelData; compact: true }
                                    }
                                    MokaidLabel { text: agentTile.modelData.display_name || "Unnamed agent"; font.pixelSize: 13; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                                    MokaidLabel { text: agentTile.modelData.role_title || "AI agent"; color: root.supportingText; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight }
                                    Row { Layout.fillWidth: true; clip: true; spacing: 4; Repeater { model: root.skillNames(agentTile.modelData).slice(0, 2); SkillTag { required property string modelData; label: modelData; maximumWidth: 110 } } }
                                    Item { Layout.fillHeight: true }
                                    RowLayout {
                                        MokaidLabel { text: root.scoreText(agentTile.modelData) + " performance"; font.pixelSize: 10; color: "#b6bedc"; Layout.fillWidth: true }
                                        MokaidButton { objectName: "agentTileActions_" + agentTile.modelData.id; iconName: "more"; quiet: true; implicitWidth: 25; implicitHeight: 24; leftPadding: 3; rightPadding: 3; Accessible.name: "Actions for " + agentTile.modelData.display_name; onClicked: { root.selectAgent(agentTile.modelData); agentActions.openFor(this) } }
                                    }
                                }
                                onClicked: root.selectAgent(modelData)
                            }
                            ScrollBar.vertical: ScrollBar { }
                        }
                    }
                    ColumnLayout {
                        anchors.centerIn: parent; width: Math.min(parent.width - 40, 310); spacing: 14
                        visible: root.filteredAgents.length === 0
                        BusyIndicator { running: features.busy; visible: running; Layout.alignment: Qt.AlignHCenter; implicitWidth: 32; implicitHeight: 32 }
                        MokaidIcon { visible: !features.busy; name: "agents"; size: 30; color: Theme.primary; Layout.alignment: Qt.AlignHCenter }
                        MokaidLabel { text: features.busy ? "Loading your workforce…" : root.allAgents.length ? "No matching agents" : "Your team starts here"; font.pixelSize: 17; font.weight: Font.DemiBold; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
                        MokaidLabel { text: features.busy ? "Your workspace is syncing." : root.allAgents.length ? "Try another name, skill or status." : features.offline ? "No agents have been saved on this device." : "Create your first agent to get started."; color: root.supportingText; font.pixelSize: 12; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
                        MokaidButton { visible: !features.busy && root.allAgents.length > 0; text: "Clear filters"; Layout.alignment: Qt.AlignHCenter; onClicked: { agentSearch.clear(); features.search(""); root.statusFilter = "all" } }
                        MokaidButton { visible: !features.busy && root.allAgents.length === 0; text: "Create agent"; highlighted: true; Layout.alignment: Qt.AlignHCenter; enabled: root.action("create").enabled; onClicked: root.runAction("create") }
                    }
                }
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: summaryGrid.implicitHeight + 16
                    radius: 13; color: "#9410111c"; border.color: root.panelBorder
                    GridLayout {
                        id: summaryGrid; anchors.fill: parent; anchors.margins: 8; columnSpacing: 8; rowSpacing: 8
                        columns: 4
                        SummaryMetric { value: String(root.summary.total); label: "Total agents"; note: "+" + root.summary.added + " this month"; icon: "agents"; accent: "#ba8cff" }
                        SummaryMetric { value: String(root.summary.active); label: "Active now"; note: root.summary.total ? Math.round(root.summary.active / root.summary.total * 100) + "% of total" : "No agents yet"; icon: "pulse"; accent: "#48dbae" }
                        SummaryMetric { value: String(root.summary.completed); label: "Missions completed"; note: "Across your workforce"; icon: "analytics"; accent: "#61b5ff" }
                        SummaryMetric { value: root.summary.score === null ? "—" : root.summary.score + "%"; label: "Avg. performance"; note: root.summary.rated ? root.summary.rated + " rated agents" : "Not rated yet"; icon: "tasks"; accent: "#f2b458" }
                    }
                }
            }
            Rectangle {
                id: inspector
                objectName: "agentInspector"
                visible: root.hasSelection
                Layout.preferredWidth: Math.max(330, Math.min(430, root.width * .35))
                Layout.fillHeight: true; Layout.minimumWidth: 320
                radius: 15; border.width: 1; border.color: "#4a3d72"
                gradient: Gradient {
                    GradientStop { position: 0; color: "#1c1733" }
                    GradientStop { position: 0.42; color: "#141226" }
                    GradientStop { position: 1; color: "#0e1018" }
                }
                ColumnLayout {
                    anchors.fill: parent; spacing: 0
                    RowLayout {
                        Layout.fillWidth: true; Layout.margins: 16; Layout.bottomMargin: 10; spacing: 12
                        WorkforcePortrait { agent: root.selectedAgent; size: inspector.width < 370 ? 60 : 70 }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 6
                            MokaidLabel { text: root.selectedAgent.display_name || "Agent"; font.pixelSize: 18; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                            MokaidLabel { text: root.selectedAgent.role_title || "AI agent"; font.pixelSize: 11; color: root.supportingText; Layout.fillWidth: true; elide: Text.ElideRight }
                            RowLayout { spacing: 5; Rectangle { implicitWidth: 6; implicitHeight: 6; radius: 3; color: root.statusColor(root.selectedAgent) } MokaidLabel { text: root.statusName(root.selectedAgent); color: root.statusColor(root.selectedAgent); font.pixelSize: 10 } }
                        }
                        ColumnLayout {
                            spacing: 3; Layout.alignment: Qt.AlignTop
                            MokaidButton { iconName: "close"; quiet: true; implicitWidth: 26; implicitHeight: 27; leftPadding: 4; rightPadding: 4; Accessible.name: "Close agent details"; onClicked: root.closeInspector() }
                            MokaidButton { objectName: "selectedAgentActions"; iconName: "more"; quiet: true; implicitWidth: 26; implicitHeight: 27; leftPadding: 4; rightPadding: 4; Accessible.name: "Selected agent actions"; onClicked: agentActions.openFor(this) }
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; spacing: 0
                        Repeater {
                            model: ["Overview", "Tasks", "Skills", "Settings"]
                            AbstractButton {
                                id: inspectorTabButton
                                objectName: "agentTab_" + index
                                required property string modelData
                                required property int index
                                Layout.fillWidth: true; implicitHeight: 40; hoverEnabled: true
                                Accessible.name: modelData; Accessible.role: Accessible.PageTab; Accessible.selected: root.inspectorTab === index
                                onClicked: { root.inspectorTab = index; root.reportOpen = false; features.showRecordDetails() }
                                contentItem: MokaidLabel { text: inspectorTabButton.modelData; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; color: root.inspectorTab === inspectorTabButton.index ? "#f3eaff" : root.supportingText; font.pixelSize: 11; font.weight: root.inspectorTab === inspectorTabButton.index ? Font.DemiBold : Font.Normal }
                                background: Rectangle {
                                    color: inspectorTabButton.hovered ? "#191727" : "transparent"; radius: 6
                                    border.color: inspectorTabButton.visualFocus ? Theme.focusBorder : "transparent"
                                    Rectangle { visible: root.inspectorTab === inspectorTabButton.index; anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter; width: parent.width - 14; height: 2; radius: 1; color: "#ad79ff" }
                                }
                            }
                        }
                    }
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.panelBorder }
                    ScrollView {
                        id: inspectorScroll
                        visible: !root.reportOpen
                        Layout.fillWidth: true; Layout.fillHeight: true
                        contentWidth: availableWidth; clip: true
                        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                        ColumnLayout {
                            width: inspectorScroll.availableWidth; spacing: 15
                            ColumnLayout {
                                visible: root.inspectorTab === 0
                                Layout.fillWidth: true; Layout.margins: 15; spacing: 14
                                RowLayout {
                                    Layout.fillWidth: true; spacing: 8
                                    DetailMetric { value: root.scoreText(root.selectedAgent); label: "Performance"; chart: "meter"; meter: root.performanceMeter(root.selectedAgent); note: root.hasScore(root.selectedAgent) ? "Current score" : "Not rated yet"; accent: "#8eb7ff" }
                                    DetailMetric { value: root.currentTaskText(root.selectedAgent); label: "Current task"; chart: "bars"; series: root.activityBars(root.selectedAgent); note: root.currentTaskNote(root.selectedAgent); accent: "#7ea6f2" }
                                    DetailMetric { value: String(root.selectedAgent.missions_completed || 0); label: "Missions completed"; chart: "bars"; series: root.missionBars(root.selectedAgent); note: root.missionNote(root.selectedAgent); accent: "#b184ff" }
                                }
                                SmallHeading { text: "About" }
                                MokaidLabel {
                                    Layout.fillWidth: true; text: root.selectedAgent.instructions || "No instructions added yet. Edit this agent to describe how it should work."
                                    color: root.supportingText; font.pixelSize: 12; wrapMode: Text.Wrap; lineHeight: 1.35; maximumLineCount: 6; elide: Text.ElideRight
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true; spacing: 8
                                    MetaLine { label: "Role"; value: root.selectedAgent.role_title || "Not specified" }
                                    MetaLine { label: "Model quality"; value: root.selectedAgent.model_quality ? root.selectedAgent.model_quality.charAt(0).toUpperCase() + root.selectedAgent.model_quality.slice(1) : "Not specified" }
                                    MetaLine { label: "Last activity"; value: root.relativeDate(root.selectedAgent.last_active_at) }
                                    MetaLine { label: "Created"; value: root.selectedAgent.inserted_at ? Qt.formatDateTime(new Date(root.selectedAgent.inserted_at), "MMM d, yyyy") : "Not available" }
                                    MetaLine { label: "Department"; value: root.selectedAgent.department || "Not specified" }
                                }
                                SmallHeading { text: "Skills" }
                                Flow {
                                    Layout.fillWidth: true; spacing: 6
                                    Repeater { model: root.skillNames(root.selectedAgent); SkillTag { required property string modelData; label: modelData; maximumWidth: inspector.width - 45 } }
                                }
                                MokaidLabel { visible: root.skillNames(root.selectedAgent).length === 0; text: "No skills recorded yet."; color: root.supportingText; font.pixelSize: 11; Layout.fillWidth: true }
                                SmallHeading { text: "Workspace access" }
                                RowLayout {
                                    Layout.fillWidth: true
                                    MokaidIcon { name: "shield"; size: 16; color: "#94a1e7" }
                                    MokaidLabel { text: root.selectedAgent.autonomy_mode ? root.selectedAgent.autonomy_mode.charAt(0).toUpperCase() + root.selectedAgent.autonomy_mode.slice(1) + " autonomy" : "Not configured"; color: root.supportingText; font.pixelSize: 11; Layout.fillWidth: true }
                                    MokaidButton { text: "Permissions"; quiet: true; implicitHeight: 31; implicitWidth: 95; font.pixelSize: 10; enabled: root.action("permissions").enabled; onClicked: root.runAction("permissions") }
                                }
                            }
                            ColumnLayout {
                                visible: root.inspectorTab === 1
                                Layout.fillWidth: true; Layout.margins: 18; spacing: 15
                                SmallHeading { text: "Current task" }
                                MokaidLabel { Layout.fillWidth: true; text: root.selectedAgent.current_task_id ? "This agent has a current assigned task." : "No current task assigned."; color: root.supportingText; font.pixelSize: 12; wrapMode: Text.Wrap }
                                MokaidButton { visible: Boolean(root.selectedAgent.current_task_id); text: "Open current task"; iconName: "arrow-right"; Layout.fillWidth: true; onClicked: features.openRecord("tasks", root.selectedAgent.current_task_id) }
                                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.panelBorder; Layout.topMargin: 8; Layout.bottomMargin: 8 }
                                MetaLine { label: "Completed"; value: String(root.selectedAgent.missions_completed || 0) + " missions" }
                                MokaidLabel { Layout.fillWidth: true; text: "Give your agent a new mission, or assign an existing workspace task."; color: root.supportingText; font.pixelSize: 12; wrapMode: Text.Wrap; lineHeight: 1.3 }
                                MokaidButton { text: "New mission"; iconName: "plus"; highlighted: true; Layout.fillWidth: true; enabled: !features.offline && root.selectedAgent.kind !== "human_linked"; onClicked: missions.beginForAgent(root.selectedAgent.id) }
                                MokaidButton { text: "Assign existing task"; Layout.fillWidth: true; enabled: root.action("assign-task").enabled; onClicked: root.runAction("assign-task") }
                                MokaidButton { text: "View workspace tasks"; quiet: true; Layout.fillWidth: true; onClicked: features.navigate("tasks") }
                            }
                            ColumnLayout {
                                visible: root.inspectorTab === 2
                                Layout.fillWidth: true; Layout.margins: 18; spacing: 15
                                RowLayout {
                                    Layout.fillWidth: true
                                    SmallHeading { text: "Skills & experience" }
                                    MokaidLabel { text: "Level " + (root.selectedAgent.level || 1); color: "#be98ff"; font.pixelSize: 12; font.weight: Font.DemiBold }
                                }
                                Flow { Layout.fillWidth: true; spacing: 6; Repeater { model: root.skillNames(root.selectedAgent); SkillTag { required property string modelData; label: modelData; maximumWidth: inspector.width - 45 } } }
                                MokaidLabel { visible: root.skillNames(root.selectedAgent).length === 0; Layout.fillWidth: true; text: "This agent hasn’t recorded any skills yet."; color: root.supportingText; font.pixelSize: 12; wrapMode: Text.Wrap }
                                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 5; radius: 3; color: "#28243b"; Rectangle { height: parent.height; radius: 3; width: parent.width * Math.max(0, Math.min(1, Number(root.selectedAgent.xp || 0) / Math.max(1, Number(root.selectedAgent.xp_for_next_level || 100)))); color: "#a17bea" } }
                                MokaidLabel { text: (root.selectedAgent.xp || 0) + " / " + (root.selectedAgent.xp_for_next_level || 100) + " XP toward the next level"; color: root.supportingText; font.pixelSize: 11; Layout.fillWidth: true; wrapMode: Text.Wrap }
                                MokaidButton { text: "View progression"; Layout.fillWidth: true; enabled: root.action("progression").enabled; onClicked: root.runAction("progression") }
                                MokaidButton { text: "Training progress"; Layout.fillWidth: true; enabled: root.action("training").enabled; onClicked: root.runAction("training") }
                            }
                            ColumnLayout {
                                visible: root.inspectorTab === 3
                                Layout.fillWidth: true; Layout.margins: 18; spacing: 15
                                SmallHeading { text: "Agent settings" }
                                MetaLine { label: "Status"; value: root.statusName(root.selectedAgent) }
                                MetaLine { label: "Autonomy"; value: root.selectedAgent.autonomy_mode || "Not configured" }
                                MetaLine { label: "AI assistance"; value: root.selectedAgent.ai_enabled === false ? "Disabled" : root.selectedAgent.ai_enabled === true ? "Enabled" : "Not specified" }
                                MetaLine { label: "Human takeover"; value: root.selectedAgent.human_takeover_enabled ? "Allowed" : "Not allowed" }
                                MokaidButton { text: "Edit agent settings"; iconName: "settings"; Layout.fillWidth: true; enabled: root.action("edit").enabled; onClicked: root.runAction("edit") }
                                MokaidButton { text: "Permission rules"; Layout.fillWidth: true; enabled: root.action("permissions").enabled; onClicked: root.runAction("permissions") }
                                MokaidButton { text: "Schedules"; iconName: "calendar"; Layout.fillWidth: true; enabled: root.action("schedules").enabled; onClicked: root.runAction("schedules") }
                                SmallHeading { text: "Instructions" }
                                TextEdit { Layout.fillWidth: true; text: root.selectedAgent.instructions || "No instructions added."; readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText; color: root.supportingText; font.family: Theme.fontFamily; font.pixelSize: 12; selectionColor: Theme.selection; selectedTextColor: Theme.text; Accessible.name: "Agent instructions" }
                                MokaidButton { text: "Remove agent"; Layout.fillWidth: true; enabled: root.action("delete").enabled; onClicked: root.runAction("delete") }
                            }
                        }
                    }
                    ColumnLayout {
                        visible: root.reportOpen
                        Layout.fillWidth: true; Layout.fillHeight: true; Layout.margins: 16; spacing: 12
                        MokaidButton { text: "Back to agent"; iconName: "chevron-left"; quiet: true; onClicked: { root.reportOpen = false; features.showRecordDetails() } }
                        MokaidLabel { text: root.reportTitle; font.pixelSize: 16; font.weight: Font.DemiBold; Layout.fillWidth: true; wrapMode: Text.Wrap }
                        BusyIndicator { running: features.busy; visible: running; implicitWidth: 24; implicitHeight: 24; Layout.alignment: Qt.AlignHCenter }
                        ListView {
                            id: reportRows
                            Layout.fillWidth: true; Layout.fillHeight: true; model: features.busy ? null : features.detailView.rows; clip: true; spacing: 9
                            delegate: Rectangle {
                                id: reportRow
                                required property string rowId
                                required property string title
                                required property var record
                                width: reportRows.width; height: reportContent.implicitHeight + 22; radius: 10; color: "#161826"; border.color: "#29283c"
                                ColumnLayout {
                                    id: reportContent; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 11; spacing: 8
                                    MokaidLabel { text: reportRow.title; color: root.supportingText; font.pixelSize: 11; Layout.fillWidth: true; wrapMode: Text.Wrap }
                                    MokaidLabel { text: reportRow.record.text || ""; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.Wrap }
                                    MokaidButton { visible: reportRow.record.expandable; text: "View details"; implicitHeight: 32; onClicked: features.detailView.enter(reportRow.rowId) }
                                }
                            }
                            MokaidLabel { anchors.centerIn: parent; width: parent.width; visible: reportRows.count === 0 && !features.busy; text: "No records to show."; color: root.supportingText; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter }
                            ScrollBar.vertical: ScrollBar { }
                        }
                        MokaidButton { visible: features.detailView.canGoBack; text: "Back in report"; onClicked: features.detailView.goBack() }
                    }
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: root.panelBorder }
                    RowLayout {
                        Layout.fillWidth: true; Layout.margins: 14; spacing: 10
                        MokaidButton {
                            objectName: "testSelectedAgent"
                            text: "Test agent"; Layout.fillWidth: true; implicitHeight: 45
                            enabled: !features.offline && root.selectedAgent.kind !== "human_linked"
                            onClicked: missions.beginForAgent(root.selectedAgent.id)
                        }
                        MokaidButton {
                            id: editButton
                            text: "Edit agent"; Layout.fillWidth: true; implicitHeight: 45; highlighted: true
                            enabled: root.action("edit").enabled
                            onClicked: root.runAction("edit")
                            background: Rectangle {
                                radius: 10; opacity: editButton.enabled ? 1 : .5
                                gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: editButton.hovered ? "#987bff" : "#8970f2" } GradientStop { position: 1; color: editButton.hovered ? "#8653fc" : "#7040ed" } }
                                border.color: editButton.visualFocus ? "#e1ccff" : "#9a78ff"
                            }
                        }
                    }
                }
            }
        }
    }
    MokaidMenu {
        id: agentActions
        objectName: "agentActionsMenu"
        MokaidMenu.Entry { objectName: "agentChatAction"; text: "Open agent chat"; enabled: root.hasSelection; onTriggered: { office.selectAgent(root.selectedAgent.id); features.navigate("office") } }
        MokaidMenu.Entry { objectName: "agentPerformanceAction"; text: "View performance"; enabled: root.hasSelection; onTriggered: features.openRecord("agent-performance", root.selectedAgent.id) }
        MokaidMenu.Entry { objectName: "agentRentAction"; text: "Rent out"; enabled: root.hasSelection && !features.offline && root.selectedAgent.kind === "ai"; onTriggered: features.openMarketplaceOffer(root.selectedAgent.id, "rent") }
        MokaidMenu.Entry { objectName: "agentSellAction"; text: "Sell copies"; enabled: root.hasSelection && !features.offline && root.selectedAgent.kind === "ai"; onTriggered: features.openMarketplaceOffer(root.selectedAgent.id, "sale") }
        MokaidMenu.Entry { objectName: "agentTestAction"; text: "Test agent"; enabled: root.hasSelection && !features.offline && root.selectedAgent.kind !== "human_linked"; onTriggered: missions.beginForAgent(root.selectedAgent.id) }
        MokaidMenu.Separator { }
        Instantiator {
            model: features.actions.filter(function(action) { return Boolean(action.selection) && action.id !== "upload"; })
            delegate: MokaidMenu.Entry {
                required property var modelData
                objectName: "agentAction_" + modelData.id
                text: modelData.title; enabled: modelData.enabled; destructive: Boolean(modelData.destructive)
                onTriggered: root.runAction(modelData.id)
            }
            onObjectAdded: function(index, object) { agentActions.insertItem(index + 3, object); }
            onObjectRemoved: function(index, object) { agentActions.removeItem(object); }
        }
    }
}
