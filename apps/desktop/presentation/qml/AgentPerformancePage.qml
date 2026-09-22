pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    objectName: "performancePage"
    clip: true
    property double now: Date.now()

    readonly property var agent: {
        if (!features.selectedId) return ({})
        const rows = features.allRecords || []
        let record = rows.find(function(row) { return row.id === features.selectedId }) || ({})
        const details = features.details || ({})
        if (details.id === features.selectedId) record = Object.assign({}, record, details)
        return record
    }
    readonly property bool tasksReady: features.selectedAgentTasksState === "ready"
    readonly property var assignedTasks: features.selectedAgentTasks || []
    readonly property int openTaskCount: root.tasksReady ? root.assignedTasks.filter(function(task) {
        return task.status !== "completed" && task.status !== "canceled"
    }).length : -1
    readonly property int completedTaskCount: root.tasksReady ? root.assignedTasks.filter(function(task) {
        return task.status === "completed"
    }).length : -1
    readonly property var taskCompletionPercent: {
        if (!root.tasksReady || root.assignedTasks.length === 0) return null
        return Math.round(root.completedTaskCount / root.assignedTasks.length * 100)
    }
    readonly property bool hasScore: root.agent.performance_score !== undefined && root.agent.performance_score !== null && root.agent.performance_score !== ""
    readonly property real performanceMeter: root.hasScore ? Math.max(0, Math.min(1, Number(root.agent.performance_score) / 100)) : -1
    readonly property string performanceLabel: root.hasScore ? String(Math.round(Number(root.agent.performance_score))) : "—"
    readonly property var latestRunTotals: {
        if (!root.tasksReady) return { credits: null, tokens: null }
        let credits = null
        let tokens = null
        for (let i = 0; i < root.assignedTasks.length; ++i) {
            const run = root.assignedTasks[i].latest_run
            if (!run) continue
            const charged = Number(run.credits_charged)
            if (isFinite(charged)) credits = (credits || 0) + charged
            const usage = run.token_usage || ({})
            const used = Number(usage.total_tokens)
            if (isFinite(used)) tokens = (tokens || 0) + used
        }
        return { credits: credits, tokens: tokens }
    }
    readonly property var statusHistogram: root.histogram(root.assignedTasks, "status", {
        to_do: "To do", in_progress: "In progress", in_review: "In review", waiting: "Waiting",
        blocked: "Blocked", completed: "Completed", canceled: "Canceled", overdue: "Overdue"
    }, ["to_do", "in_progress", "in_review", "waiting", "blocked", "completed", "canceled", "overdue"])
    readonly property var priorityHistogram: root.histogram(root.assignedTasks, "priority", {
        low: "Low", medium: "Medium", high: "High", urgent: "Urgent", "": "Not set"
    }, ["urgent", "high", "medium", "low", ""])
    readonly property var progressHistogram: {
        if (!root.tasksReady) return []
        const buckets = [0, 0, 0, 0]
        for (let i = 0; i < root.assignedTasks.length; ++i) {
            const value = Number(root.assignedTasks[i].progress_percent)
            if (!isFinite(value)) continue
            const clamped = Math.max(0, Math.min(100, value))
            buckets[clamped >= 100 ? 3 : Math.min(3, Math.floor(clamped / 25))] += 1
        }
        return buckets
    }
    readonly property var completionSeries: {
        if (!root.tasksReady) return []
        const end = new Date(root.now)
        const endUtc = Date.UTC(end.getUTCFullYear(), end.getUTCMonth(), end.getUTCDate())
        const rows = []
        const index = {}
        for (let i = 13; i >= 0; --i) {
            const day = new Date(endUtc - i * 86400000)
            const key = root.dayKey(day)
            index[key] = rows.length
            rows.push(0)
        }
        for (let i = 0; i < root.assignedTasks.length; ++i) {
            const task = root.assignedTasks[i]
            if (task.status !== "completed" || !task.completed_at) continue
            const date = new Date(task.completed_at)
            if (isNaN(date.getTime())) continue
            const slot = index[root.dayKey(date)]
            if (slot === undefined) continue
            rows[slot] += 1
        }
        return rows
    }
    readonly property var activityLog: {
        if (!root.tasksReady) return []
        const entries = []
        function push(at, title, detail) {
            if (!at) return
            const date = new Date(at)
            if (isNaN(date.getTime())) return
            entries.push({ at: date.toISOString(), title: title, detail: detail || "" })
        }
        for (let i = 0; i < root.assignedTasks.length; ++i) {
            const task = root.assignedTasks[i]
            const name = task.title || "Assigned task"
            push(task.inserted_at, "Task created", name)
            push(task.started_at, "Task started", name)
            if (task.status === "completed") push(task.completed_at, "Task completed", name)
            const run = task.latest_run
            if (run) {
                push(run.started_at, "Run started", name)
                if (run.completed_at) push(run.completed_at, run.status === "failed" ? "Run failed" : "Run finished", name)
                if (run.error) push(run.completed_at || run.started_at, "Run error", String(run.error))
            }
            const comments = task.comments || []
            for (let c = 0; c < comments.length; ++c) {
                const comment = comments[c]
                push(comment.inserted_at, comment.author_name || "Comment", comment.body || "")
            }
        }
        entries.sort(function(a, b) { return a.at < b.at ? 1 : a.at > b.at ? -1 : 0 })
        return entries.slice(0, 40)
    }

    function dayKey(date) {
        const month = date.getUTCMonth() + 1
        const day = date.getUTCDate()
        return date.getUTCFullYear() + "-" + (month < 10 ? "0" : "") + month + "-" + (day < 10 ? "0" : "") + day
    }
    function histogram(tasks, field, labels, order) {
        if (!root.tasksReady) return []
        const counts = {}
        for (let i = 0; i < tasks.length; ++i) {
            const raw = tasks[i][field]
            const key = raw === undefined || raw === null ? "" : String(raw)
            counts[key] = (counts[key] || 0) + 1
        }
        const keys = Object.keys(counts)
        keys.sort(function(a, b) {
            const left = order.indexOf(a)
            const right = order.indexOf(b)
            return (left < 0 ? 99 : left) - (right < 0 ? 99 : right)
        })
        return keys.map(function(key) {
            return { key: key, label: labels[key] || (key || "Not set"), count: counts[key] }
        })
    }
    function countText(value) {
        return value < 0 ? "—" : String(value)
    }
    function optionalText(value) {
        return value === null || value === undefined ? "—" : String(value)
    }

    component MetricCard: Rectangle {
        id: card
        property string value: ""
        property string label: ""
        property string note: ""
        property color accent: "#b184ff"
        property real meter: -1
        Layout.fillWidth: true
        Layout.preferredHeight: 118
        radius: 14
        color: "#121320"
        border.color: "#2c2844"
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 4
            MokaidLabel { text: card.value; color: card.accent; font.pixelSize: 26; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
            MokaidLabel { text: card.label; color: "#d5d8ea"; font.pixelSize: 12; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
            Item { Layout.fillWidth: true; Layout.preferredHeight: 8; visible: card.meter >= 0
                Rectangle { anchors.fill: parent; radius: 4; color: "#241f36" }
                Rectangle { width: parent.width * Math.max(0, Math.min(1, card.meter)); height: parent.height; radius: 4; color: card.accent }
            }
            MokaidLabel { text: card.note; color: "#8f9bb8"; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight }
        }
    }
    component ChartCard: Rectangle {
        id: chart
        property string title: ""
        property string note: ""
        property var counts: []
        property var labels: []
        property color ink: "#b184ff"
        Layout.fillWidth: true
        Layout.preferredHeight: 196
        radius: 14
        color: "#121320"
        border.color: "#2c2844"
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8
            MokaidLabel { text: chart.title; font.pixelSize: 13; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
            Canvas {
                id: plot
                Layout.fillWidth: true
                Layout.fillHeight: true
                onPaint: {
                    const ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    const values = chart.counts || []
                    if (width < 4 || height < 4 || values.length === 0) return
                    let max = 1
                    for (let i = 0; i < values.length; ++i) max = Math.max(max, Number(values[i]) || 0)
                    const gap = values.length > 10 ? 3 : 8
                    const barWidth = Math.max(4, (width - gap * (values.length - 1)) / values.length)
                    for (let i = 0; i < values.length; ++i) {
                        const sample = Math.max(0, Number(values[i]) || 0) / max
                        const barHeight = Math.max(sample > 0 ? 4 : 0, sample * (height - 4))
                        const x = i * (barWidth + gap)
                        ctx.fillStyle = chart.ink
                        ctx.globalAlpha = 0.16
                        ctx.fillRect(x, 0, barWidth, height - 2)
                        ctx.globalAlpha = 0.95
                        if (barHeight > 0) ctx.fillRect(x, height - 2 - barHeight, barWidth, barHeight)
                    }
                }
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                Connections {
                    target: chart
                    function onCountsChanged() { plot.requestPaint() }
                    function onInkChanged() { plot.requestPaint() }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                visible: (chart.labels || []).length > 0 && (chart.labels || []).length <= 8
                Repeater {
                    model: chart.labels || []
                    delegate: MokaidLabel {
                        required property string modelData
                        Layout.fillWidth: true
                        text: modelData
                        color: "#8f9bb8"
                        font.pixelSize: 10
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                    }
                }
            }
            MokaidLabel { text: chart.note; color: "#8f9bb8"; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 14
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            MokaidButton {
                objectName: "performanceBack"
                iconName: "chevron-left"
                text: "Office"
                quiet: true
                implicitHeight: 40
                onClicked: features.navigate("office")
            }
            WorkforcePortrait { agent: root.agent; size: 52; visible: !!root.agent.id }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                MokaidLabel {
                    Layout.fillWidth: true
                    text: root.agent.display_name || "Agent performance"
                    font.pixelSize: 26
                    font.weight: Font.Bold
                    elide: Text.ElideRight
                }
                MokaidLabel {
                    Layout.fillWidth: true
                    text: root.agent.id ? (root.agent.role_title || "AI agent") : "Choose an agent from the office."
                    color: Theme.secondary
                    font.pixelSize: 13
                    elide: Text.ElideRight
                }
            }
        }
        MokaidLabel {
            Layout.fillWidth: true
            text: features.selectedAgentTasksState === "unavailable"
                  ? "Assigned tasks could not be loaded. Scores already stored on the agent stay visible."
                  : features.selectedAgentTasksState === "loading"
                    ? "Loading assigned tasks…"
                    : "Performance is the current score. Charts and the log count this agent's real assigned tasks, runs and comments."
            color: features.selectedAgentTasksState === "unavailable" ? Theme.warning : "#8f9bb8"
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }
        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: body.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            ColumnLayout {
                id: body
                width: parent.width
                spacing: 14
                GridLayout {
                    Layout.fillWidth: true
                    columns: width < 760 ? 2 : 4
                    columnSpacing: 10
                    rowSpacing: 10
                    MetricCard { value: root.performanceLabel; label: "Performance"; note: root.hasScore ? "Current score" : "Not rated yet"; meter: root.performanceMeter; accent: "#8eb7ff" }
                    MetricCard { value: String(root.agent.missions_completed || 0); label: "Missions completed"; note: "Recorded on the agent"; accent: "#c9a6ff"; visible: !!root.agent.id }
                    MetricCard { value: root.agent.id ? ("Lv " + (root.agent.level || 1)) : "—"; label: "Level"; note: (root.agent.xp || 0) + " / " + (root.agent.xp_for_next_level || 100) + " XP"; meter: root.agent.id ? Math.max(0, Math.min(1, Number(root.agent.xp || 0) / Math.max(1, Number(root.agent.xp_for_next_level || 100)))) : -1; accent: "#b184ff" }
                    MetricCard { value: root.countText(root.openTaskCount); label: "Open tasks"; note: "Not completed or canceled"; accent: "#7ec8ff" }
                    MetricCard { value: root.countText(root.completedTaskCount); label: "Tasks completed"; note: "Assigned tasks"; accent: "#7ddeb8" }
                    MetricCard { value: root.taskCompletionPercent === null ? "—" : (root.taskCompletionPercent + "%"); label: "Task completion"; note: root.tasksReady ? (root.assignedTasks.length + " assigned") : "Waiting for tasks"; accent: "#f0c58b" }
                    MetricCard { value: root.optionalText(root.latestRunTotals.credits); label: "Credits"; note: "Sum of latest runs"; accent: "#e7b0ff" }
                    MetricCard { value: root.optionalText(root.latestRunTotals.tokens); label: "Tokens"; note: "Sum of latest runs"; accent: "#9ad7ff" }
                }
                GridLayout {
                    Layout.fillWidth: true
                    columns: width < 860 ? 1 : 2
                    columnSpacing: 10
                    rowSpacing: 10
                    ChartCard {
                        objectName: "performanceStatusChart"
                        title: "Task status"
                        note: root.tasksReady ? (root.statusHistogram.length ? "Assigned tasks by status" : "No assigned tasks yet") : "Waiting for tasks"
                        counts: root.statusHistogram.map(function(row) { return row.count })
                        labels: root.statusHistogram.map(function(row) { return row.label })
                        ink: "#7ea6f2"
                    }
                    ChartCard {
                        title: "Priority"
                        note: root.tasksReady ? (root.priorityHistogram.length ? "Assigned tasks by priority" : "No assigned tasks yet") : "Waiting for tasks"
                        counts: root.priorityHistogram.map(function(row) { return row.count })
                        labels: root.priorityHistogram.map(function(row) { return row.label })
                        ink: "#f0c58b"
                    }
                    ChartCard {
                        title: "Progress"
                        note: root.tasksReady ? "Current progress of assigned tasks" : "Waiting for tasks"
                        counts: root.progressHistogram
                        labels: root.tasksReady ? ["0–24", "25–49", "50–74", "75–100"] : []
                        ink: "#b184ff"
                    }
                    ChartCard {
                        objectName: "performanceCompletionChart"
                        title: "Tasks completed"
                        note: root.tasksReady ? "Last 14 days, from completion dates" : "Waiting for tasks"
                        counts: root.completionSeries
                        labels: []
                        ink: "#7ddeb8"
                    }
                }
                Rectangle {
                    objectName: "performanceLog"
                    Layout.fillWidth: true
                    radius: 14
                    color: "#121320"
                    border.color: "#2c2844"
                    implicitHeight: logColumn.implicitHeight + 28
                    ColumnLayout {
                        id: logColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 14
                        spacing: 8
                        MokaidLabel { text: "Activity"; font.pixelSize: 15; font.weight: Font.DemiBold }
                        MokaidLabel {
                            Layout.fillWidth: true
                            text: root.tasksReady
                                  ? (root.activityLog.length ? "Newest task, run and comment events." : "No dated activity on the assigned tasks yet.")
                                  : "Activity appears once assigned tasks load."
                            color: "#8f9bb8"
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }
                        Repeater {
                            model: root.activityLog
                            delegate: RowLayout {
                                id: logRow
                                required property var modelData
                                Layout.fillWidth: true
                                spacing: 10
                                Rectangle { implicitWidth: 6; implicitHeight: 6; radius: 3; color: "#b184ff"; Layout.alignment: Qt.AlignVCenter }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 1
                                    MokaidLabel { text: logRow.modelData.title; font.pixelSize: 12; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                                    MokaidLabel { text: logRow.modelData.detail; visible: text.length > 0; color: "#c5cbe0"; font.pixelSize: 12; Layout.fillWidth: true; elide: Text.ElideRight }
                                    MokaidLabel { text: logRow.modelData.at; color: "#8f9bb8"; font.pixelSize: 10; Layout.fillWidth: true; elide: Text.ElideRight }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
