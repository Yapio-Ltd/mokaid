pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Basic as Basic
import QtQuick.Layouts
import "FeatureLogic.js" as Logic

Item {
    id: root
    objectName: "agentDetailContent"
    clip: true
    property var agent: ({})
    property int tabIndex: 1
    signal actionRequested(var action)

    readonly property color ink: "#f2f2fc"
    readonly property color supporting: "#b4c0df"
    readonly property color accent: "#bf8aff"
    readonly property color line: "#25273b"
    readonly property bool selected: !!agent.id && features.selectedId === agent.id
    readonly property var tasks: selected ? (features.selectedAgentTasks || []) : []
    readonly property string tasksState: selected ? features.selectedAgentTasksState : "idle"
    readonly property var knowledge: selected ? (features.selectedAgentKnowledge || []) : []
    readonly property string knowledgeState: selected ? features.selectedAgentKnowledgeState : "idle"
    property string taskQuery: ""
    property int taskFilter: 0
    property int knowledgeLimit: 12
    readonly property var filteredTasks: tasks.filter(function(task) {
        const isComplete = task.status === "completed"
        const isOpen = !isComplete && task.status !== "canceled"
        return (taskFilter === 0 || (taskFilter === 1 && isOpen) || (taskFilter === 2 && isComplete))
            && (!taskQuery.trim() || String(task.title || "").toLowerCase().indexOf(taskQuery.trim().toLowerCase()) >= 0)
    })
    readonly property var skillRows: (agent.skills || []).map(function(skill) {
        return typeof skill === "string" ? { name: skill } : skill
    }).filter(function(skill) { return !!(skill.name || skill.label || skill.key) })

    property var progression: ({})
    property var training: ({})
    property var permissionRules: []
    property var schedules: []
    property var reportStates: ({})
    property var reportErrors: ({})
    property string pendingReport: ""
    property string reportAgentId: ""
    property string reportContext: ""
    property bool permissionsExpanded: false
    property bool schedulesExpanded: false
    property string requestedReport: ""
    property string loadedAgentKey: ""
    property var draftCache: ({})
    property var baseValues: ({})
    property var draftValues: ({})
    property var changedFields: ({})
    property bool initializing: false
    property bool saving: false
    property string saveContext: ""
    property string saveAgentKey: ""
    property string settingsMessage: ""
    property bool settingsError: false
    readonly property bool dirty: Object.keys(changedFields).length > 0
    readonly property bool hasDrafts: dirty || Object.keys(draftCache).some(function(key) { return Object.keys(draftCache[key].changes || {}).length > 0 })
    readonly property string sessionIdentity: String((session.user || {}).id || "") + ":" + String(session.workspaceId || "") + ":" + String(session.authenticated)
    readonly property bool editEnabled: selected && !!action("edit").enabled && !saving
    readonly property var autonomyOptions: ["supervised", "balanced", "autonomous"]
    readonly property var modelOptions: ["fast", "smart"]
    readonly property var statusOptions: ["active", "busy", "idle", "waiting", "blocked", "away", "offline", "archived", "training"]
    readonly property var editableKeys: ["display_name", "role_title", "instructions", "autonomy_mode", "model_quality", "status", "human_takeover_enabled"]

    function action(id) {
        return (features.actions || []).find(function(value) { return value.id === id }) || ({ enabled: false })
    }
    function agentKey() { return sessionIdentity + ":" + String(agent.workspace_id || "") + ":" + String(agent.id || "") }
    function textValue(value) { return value === undefined || value === null ? "" : String(value) }
    function editorText(key) { return textValue(draftValues[key]) }
    function setField(key, value) {
        if (initializing || !agent.id || draftValues[key] === value) return
        const next = Object.assign({}, draftValues); next[key] = value; draftValues = next
        const changes = Object.assign({}, changedFields)
        if (value === baseValues[key]) delete changes[key]
        else changes[key] = true
        changedFields = changes
        settingsMessage = ""; settingsError = false
    }
    function syncAgent() {
        if (!agent.id) {
            if (pendingReport) {
                const states = Object.assign({}, reportStates); delete states[pendingReport]; reportStates = states
            }
            pendingReport = ""; reportContext = ""; requestedReport = ""
            return
        }
        initializing = true
        const key = agentKey()
        if (key !== loadedAgentKey) {
            if (loadedAgentKey && dirty) {
                const cached = Object.assign({}, draftCache)
                cached[loadedAgentKey] = { base: baseValues, draft: draftValues, changes: changedFields }
                draftCache = cached
            }
            loadedAgentKey = key
            const saved = draftCache[key]
            baseValues = saved ? saved.base : ({})
            draftValues = saved ? saved.draft : ({})
            changedFields = saved ? saved.changes : ({})
            if (saved) { const cached = Object.assign({}, draftCache); delete cached[key]; draftCache = cached }
            taskQuery = ""; taskFilter = 0; knowledgeLimit = 12
            progression = ({}); training = ({}); permissionRules = []; schedules = []
            reportStates = ({}); reportErrors = ({})
            pendingReport = ""; reportContext = ""; permissionsExpanded = false; schedulesExpanded = false; requestedReport = ""
            saving = !!saveContext && saveAgentKey === key
            settingsMessage = saved && saved.error ? saved.error : ""; settingsError = !!settingsMessage
        }
        const nextBase = Object.assign({}, baseValues)
        const nextDraft = Object.assign({}, draftValues)
        const nextChanges = Object.assign({}, changedFields)
        editableKeys.forEach(function(field) {
            const value = field === "human_takeover_enabled" ? agent[field] : textValue(agent[field])
            if (nextChanges[field] && value !== draftValues[field]) return
            delete nextChanges[field]
            nextBase[field] = value; nextDraft[field] = value
        })
        baseValues = nextBase; draftValues = nextDraft; changedFields = nextChanges
        initializing = false
        reportQueue.restart()
    }
    function discardDraft() {
        initializing = true; changedFields = ({}); baseValues = ({}); draftValues = ({})
        const cached = Object.assign({}, draftCache); delete cached[loadedAgentKey]; draftCache = cached
        settingsMessage = ""; settingsError = false; initializing = false; syncAgent()
    }
    function saveSettings() {
        if (!editEnabled || !dirty) return
        if (!editorText("display_name").trim()) {
            settingsError = true; settingsMessage = "Give this agent a name before saving."
            nameEditor.forceActiveFocus(); return
        }
        const values = { _id: agent.id, _context: features.actionContext("edit"), display_name: editorText("display_name").trim() }
        Object.keys(changedFields).forEach(function(field) {
            if (field !== "display_name") values[field] = draftValues[field]
        })
        saving = true; saveContext = values._context; saveAgentKey = agentKey()
        settingsMessage = ""; settingsError = false
        features.submit("edit", values)
        resolveFailure()
    }
    function setReportState(id, state, message) {
        const states = Object.assign({}, reportStates); states[id] = state; reportStates = states
        const errors = Object.assign({}, reportErrors); errors[id] = message || ""; reportErrors = errors
    }
    function requestReport(id) {
        if (!selected || features.busy || pendingReport || !action(id).enabled) return
        pendingReport = id; reportAgentId = agent.id; reportContext = features.actionContext(id)
        setReportState(id, "loading")
        features.submit(id, { _id: agent.id, _context: reportContext })
        resolveFailure()
    }
    function loadReports() {
        if (!visible || !selected || features.busy || pendingReport) return
        if (requestedReport && action(requestedReport).enabled) {
            const id = requestedReport; requestedReport = ""; requestReport(id); return
        }
        const ids = tabIndex === 2 ? ["progression", "training"] : tabIndex === 3 ? (permissionsExpanded ? ["permissions"] : []).concat(schedulesExpanded ? ["schedules"] : []) : []
        for (let i = 0; i < ids.length; ++i) {
            if (!reportStates[ids[i]] && action(ids[i]).enabled) { requestReport(ids[i]); return }
        }
    }
    function openReport(id) {
        if (["training", "progression", "permissions", "schedules"].indexOf(id) < 0) return
        if (id === "permissions") permissionsExpanded = true
        if (id === "schedules") schedulesExpanded = true
        requestedReport = id; reportQueue.restart()
    }
    function resolveFailure() {
        if (features.busy || !features.error) return
        if (pendingReport && reportAgentId === agent.id) {
            setReportState(pendingReport, "error", features.error)
            pendingReport = ""; reportContext = ""
        }
        if (saveContext) {
            saveContext = ""; saving = false
            const message = features.error + " Your changes are still here."
            if (saveAgentKey === loadedAgentKey) { settingsError = true; settingsMessage = message }
            else if (draftCache[saveAgentKey]) {
                const cached = Object.assign({}, draftCache)
                cached[saveAgentKey] = Object.assign({}, cached[saveAgentKey], { error: message }); draftCache = cached
            }
        }
    }
    function refreshKnowledge() {
        if (!selected || features.busy) return
        reportStates = ({}); reportErrors = ({})
        features.refresh(); reportQueue.restart()
    }
    function taskColor(task) {
        return task.status === "completed" ? "#32dfab" : ["blocked", "overdue"].indexOf(task.status) >= 0 ? "#ff9ba9"
            : task.status === "waiting" || task.status === "in_review" ? "#f0c58b" : task.status === "in_progress" ? accent : supporting
    }
    function knowledgeStatus(item) {
        const status = item.indexing_status || ""
        return status === "indexed" || status === "completed" || status === "ready" ? "Ready to use"
            : status === "failed" ? "Couldn’t process this file" : status === "processing" || status === "indexing" || status === "pending" ? "Preparing knowledge…"
            : item.status === "published" ? "Published" : Logic.human(status || item.status || "Added")
    }
    function readableSize(bytes) {
        const value = Number(bytes)
        if (!isFinite(value) || value <= 0) return ""
        return value >= 1048576 ? (value / 1048576).toFixed(1) + " MB" : Math.max(1, Math.round(value / 1024)) + " KB"
    }
    function scheduleWhen(schedule) {
        const parts = String(schedule.cron_expression || "").trim().split(/\s+/)
        if (parts.length !== 5) return "Custom schedule"
        if (parts.join(" ") === "* * * * *") return "Every minute"
        if (/^\*\/[1-9][0-9]*$/.test(parts[0]) && parts.slice(1).join(" ") === "* * * *") return "Every " + parts[0].slice(2) + " minutes"
        if (parts[0] === "0" && parts.slice(1).join(" ") === "* * * *") return "Every hour"
        if (!/^\d+$/.test(parts[0]) || !/^\d+$/.test(parts[1]) || Number(parts[0]) > 59 || Number(parts[1]) > 23) return "Custom schedule"
        const time = ("0" + parts[1]).slice(-2) + ":" + ("0" + parts[0]).slice(-2)
        if (parts[2] === "*" && parts[3] === "*") {
            if (parts[4] === "*") return "Daily at " + time
            if (parts[4] === "1-5") return "Weekdays at " + time
            if (/^[0-7]$/.test(parts[4])) return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][Number(parts[4])] + " at " + time
        }
        if (/^\d+$/.test(parts[2]) && parts[3] === "*" && parts[4] === "*") return "Day " + parts[2] + " of each month at " + time
        return "Custom schedule"
    }
    onAgentChanged: syncAgent()
    onSessionIdentityChanged: {
        initializing = true; draftCache = ({}); changedFields = ({}); baseValues = ({}); draftValues = ({})
        saving = false; saveContext = ""; saveAgentKey = ""
        loadedAgentKey = ""; initializing = false; syncAgent()
    }
    onTabIndexChanged: reportQueue.restart()
    onVisibleChanged: if (visible) reportQueue.restart()
    Component.onCompleted: syncAgent()
    Timer { id: reportQueue; interval: 1; onTriggered: root.loadReports() }
    Connections {
        target: features
        function onChanged() {
            root.resolveFailure()
            if (root.pendingReport && (!root.selected || root.reportContext !== features.actionContext(root.pendingReport))) {
                const states = Object.assign({}, root.reportStates); delete states[root.pendingReport]; root.reportStates = states
                root.pendingReport = ""; root.reportContext = ""
            }
            if (root.saveContext && !features.busy && root.saveContext !== features.actionContext("edit")) {
                root.saving = false; root.saveContext = ""
                if (root.saveAgentKey === root.loadedAgentKey) {
                    root.settingsError = false; root.settingsMessage = "Changes kept as a draft. Review this agent before saving again."
                }
            }
            if (!features.busy) reportQueue.restart()
        }
        function onActionResult(actionId, result) {
            if (actionId === "upload" && root.selected && result.agent_id === root.agent.id) {
                root.reportStates = ({}); reportQueue.restart()
            }
            if (actionId !== root.pendingReport || root.reportAgentId !== root.agent.id || !root.selected) return
            if (root.reportContext !== features.actionContext(actionId)) { root.pendingReport = ""; return }
            if (actionId === "progression") root.progression = result
            else if (actionId === "training") root.training = result
            else if (actionId === "permissions") root.permissionRules = result.items || []
            else if (actionId === "schedules") root.schedules = result.items || []
            root.setReportState(actionId, "ready")
            root.pendingReport = ""; root.reportContext = ""; reportQueue.restart()
        }
        function onActionSucceeded(context) {
            if (!root.saveContext || context !== root.saveContext) return
            root.saving = false; root.saveContext = ""
            const cached = Object.assign({}, root.draftCache); delete cached[root.saveAgentKey]; root.draftCache = cached
            if (root.saveAgentKey === root.loadedAgentKey) {
                root.changedFields = ({}); root.baseValues = Object.assign({}, root.draftValues)
                root.settingsError = false; root.settingsMessage = "Changes saved."
            }
        }
    }

    component SectionLabel: MokaidLabel {
        font.pixelSize: 13; font.weight: Font.DemiBold; color: root.ink
        Layout.fillWidth: true; wrapMode: Text.Wrap
    }
    component Hint: MokaidLabel {
        font.pixelSize: 11; color: root.supporting; Layout.fillWidth: true; wrapMode: Text.Wrap
    }
    component Divider: Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.line }
    component StatusMessage: ColumnLayout {
        property string title: ""
        property string detail: ""
        property string icon: "knowledge"
        Layout.fillWidth: true; spacing: 8
        MokaidIcon { name: parent.icon; color: root.accent; size: 25; Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 18 }
        MokaidLabel { text: parent.title; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; font.pixelSize: 13; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
        Hint { text: parent.detail; horizontalAlignment: Text.AlignHCenter; Layout.bottomMargin: 18 }
    }

    ColumnLayout {
        anchors.fill: parent; spacing: 12; visible: root.tabIndex === 1
        RowLayout {
            Layout.fillWidth: true; spacing: 8
            SectionLabel { text: "Assigned tasks" }
            MokaidLabel { text: root.tasksState === "ready" ? String(root.tasks.length) : ""; color: root.supporting; font.pixelSize: 12 }
            MokaidButton { objectName: "agentTasksRefresh"; iconName: "refresh"; quiet: true; implicitHeight: 30; implicitWidth: 30; leftPadding: 6; rightPadding: 6; enabled: root.selected && !features.busy; Accessible.name: "Refresh agent tasks"; onClicked: features.refresh() }
        }
        MokaidTextField {
            objectName: "agentTaskSearch"; Layout.fillWidth: true; implicitHeight: 38; leftPadding: 34
            text: root.taskQuery; placeholderText: "Search this agent’s tasks…"; Accessible.name: "Search agent tasks"
            onTextChanged: if (root.taskQuery !== text) root.taskQuery = text
            MokaidIcon { anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter; name: "search"; color: root.supporting; size: 15 }
        }
        RowLayout {
            Layout.fillWidth: true; spacing: 6
            Repeater {
                model: ["All", "Open", "Completed"]
                MokaidButton {
                    required property string modelData; required property int index
                    objectName: "agentTaskFilter_" + index; text: modelData; highlighted: root.taskFilter === index
                    Layout.fillWidth: true; Layout.minimumWidth: 0; implicitWidth: 70; implicitHeight: 32; font.pixelSize: 11; leftPadding: 8; rightPadding: 8
                    Accessible.name: modelData + " agent tasks"; Accessible.checkable: true; Accessible.checked: root.taskFilter === index
                    onClicked: root.taskFilter = index
                }
            }
        }
        ListView {
            id: taskList
            objectName: "agentTasksList"; Layout.fillWidth: true; Layout.fillHeight: true; clip: true; layer.enabled: true
            Rectangle { parent: taskList; anchors.fill: parent; z: -1; color: "#11131f" }
            model: root.filteredTasks; spacing: 1; reuseItems: true
            delegate: Basic.ItemDelegate {
                id: taskRow
                required property var modelData
                objectName: "agentTask_" + modelData.id; width: taskList.width; height: Math.max(68, taskRowContent.implicitHeight + 22)
                hoverEnabled: true; padding: 10
                Accessible.name: (modelData.title || "Untitled task") + ", " + Logic.human(modelData.status)
                background: Rectangle { radius: 9; color: taskRow.hovered || taskRow.down ? "#1e1c30" : "transparent"; border.color: taskRow.visualFocus ? Theme.focusBorder : "transparent" }
                contentItem: RowLayout {
                    id: taskRowContent; spacing: 10
                    Rectangle {
                        implicitWidth: 18; implicitHeight: 18; radius: 9; color: taskRow.modelData.status === "completed" ? root.taskColor(taskRow.modelData) : "transparent"
                        border.color: root.taskColor(taskRow.modelData); border.width: 1.5
                        MokaidIcon { anchors.centerIn: parent; visible: taskRow.modelData.status === "completed"; name: "check"; color: "#092d21"; size: 13 }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 5
                        MokaidLabel { text: taskRow.modelData.title || "Untitled task"; Layout.fillWidth: true; font.pixelSize: 12; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 5
                            MokaidLabel { text: Logic.human(taskRow.modelData.status); color: root.taskColor(taskRow.modelData); font.pixelSize: 10 }
                            MokaidLabel { text: taskRow.modelData.due_at ? "· Due " + Logic.date(taskRow.modelData.due_at) : ""; color: root.supporting; font.pixelSize: 10; Layout.fillWidth: true; elide: Text.ElideRight }
                        }
                    }
                    MokaidIcon { name: "chevron-right"; color: root.supporting; size: 15 }
                }
                onClicked: features.openRecord("tasks", modelData.id)
                Rectangle { anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.leftMargin: 38; anchors.right: parent.right; height: 1; color: root.line }
            }
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            StatusMessage {
                anchors.centerIn: parent; width: Math.max(0, parent.width - 24); visible: taskList.count === 0
                icon: root.tasksState === "unavailable" ? "alert" : "tasks"
                title: root.tasksState === "loading" || root.tasksState === "idle" ? "Loading tasks…" : root.tasksState === "unavailable" ? "Tasks are unavailable" : root.taskQuery || root.taskFilter ? "No matching tasks" : "Ready for a first task"
                detail: root.tasksState === "unavailable" ? "Refresh to try again." : root.tasksState !== "ready" ? "Getting this agent’s latest work." : root.taskQuery || root.taskFilter ? "Try another search or choose All." : "Assign a mission to give this agent its next goal."
            }
        }
        MokaidButton { objectName: "agentTasksAssign"; text: "Assign a task"; iconName: "plus"; highlighted: true; Layout.fillWidth: true; implicitHeight: 38; enabled: root.selected && !features.offline && root.agent.kind !== "human_linked"; onClicked: missions.beginForAgent(root.agent.id) }
    }

    ScrollView {
        id: knowledgeScroll
        objectName: "agentKnowledgeScroll"; anchors.fill: parent; visible: root.tabIndex === 2; clip: true; layer.enabled: true
        background: Rectangle { color: "#11131f" }
        contentWidth: availableWidth; ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ColumnLayout {
            width: knowledgeScroll.availableWidth; spacing: 14
            RowLayout {
                Layout.fillWidth: true; spacing: 6
                SectionLabel { text: "Knowledge & skills" }
                MokaidButton { objectName: "agentKnowledgeRefresh"; iconName: "refresh"; quiet: true; implicitWidth: 30; implicitHeight: 30; leftPadding: 6; rightPadding: 6; enabled: root.selected && !features.busy; Accessible.name: "Refresh agent knowledge"; onClicked: root.refreshKnowledge() }
            }
            Hint { text: "Reference material and experience that shape how this agent works." }
            MokaidButton { objectName: "agentKnowledgeUpload"; text: "Add reference files"; iconName: "plus"; highlighted: true; Layout.fillWidth: true; implicitHeight: 38; enabled: root.selected && root.action("upload").enabled; onClicked: root.actionRequested(root.action("upload")) }
            Divider { Layout.topMargin: 2 }
            RowLayout { Layout.fillWidth: true; SectionLabel { text: "Reference library" } MokaidLabel { text: root.knowledgeState === "ready" ? String(root.knowledge.length) : ""; color: root.supporting; font.pixelSize: 11 } }
            Hint { visible: root.knowledgeState !== "ready"; text: root.knowledgeState === "unavailable" ? "The library couldn’t be loaded. Refresh to try again." : "Loading reference files…"; color: root.knowledgeState === "unavailable" ? Theme.warning : root.supporting }
            Hint { visible: root.knowledgeState === "ready" && root.knowledge.length === 0; text: "No reference files yet. Add documents, notes or guides for this agent to learn from." }
            Repeater {
                model: root.knowledge.slice(0, root.knowledgeLimit)
                RowLayout {
                    id: knowledgeRow
                    required property var modelData
                    objectName: "agentKnowledge_" + modelData.id; Layout.fillWidth: true; spacing: 10
                    ToolTip.visible: referenceHover.hovered && referenceTitle.truncated
                    ToolTip.text: referenceTitle.text
                    HoverHandler { id: referenceHover }
                    Rectangle { implicitWidth: 34; implicitHeight: 38; radius: 9; color: "#24203b"; MokaidIcon { anchors.centerIn: parent; name: "file"; size: 18; color: root.accent } }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 4
                        MokaidLabel { id: referenceTitle; text: knowledgeRow.modelData.title || "Untitled reference"; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight }
                        Hint { text: root.knowledgeStatus(knowledgeRow.modelData) + (root.readableSize(knowledgeRow.modelData.file_size_bytes) ? " · " + root.readableSize(knowledgeRow.modelData.file_size_bytes) : ""); color: knowledgeRow.modelData.indexing_status === "failed" ? Theme.danger : root.supporting; font.pixelSize: 10 }
                    }
                }
            }
            MokaidButton {
                objectName: "agentKnowledgeShowMore"; visible: root.knowledge.length > root.knowledgeLimit
                text: "Show " + Math.min(12, root.knowledge.length - root.knowledgeLimit) + " more references"
                quiet: true; Layout.fillWidth: true; implicitHeight: 32; onClicked: root.knowledgeLimit += 12
            }
            Divider { Layout.topMargin: 5 }
            SectionLabel { text: "Skills" }
            Flow {
                Layout.fillWidth: true; spacing: 6
                Repeater {
                    model: root.skillRows
                    Rectangle {
                        id: skillTag
                        required property var modelData
                        width: Math.min(knowledgeScroll.availableWidth, skillLabel.implicitWidth + 18); height: 27; radius: 8; color: "#25223a"
                        MokaidLabel { id: skillLabel; anchors.centerIn: parent; width: Math.min(implicitWidth, parent.width - 18); text: skillTag.modelData.name || skillTag.modelData.label || Logic.human(skillTag.modelData.key); font.pixelSize: 10; color: "#dfd1ff"; elide: Text.ElideRight }
                        ToolTip.visible: skillHover.hovered && skillLabel.truncated
                        ToolTip.text: skillLabel.text
                        HoverHandler { id: skillHover }
                    }
                }
            }
            Hint { visible: root.skillRows.length === 0; text: "Skills will appear as this agent gains experience." }
            Divider { Layout.topMargin: 5 }
            RowLayout { Layout.fillWidth: true; SectionLabel { text: "Experience" } MokaidLabel { text: root.agent.level !== undefined ? "Level " + root.agent.level : ""; font.pixelSize: 12; color: root.accent; font.weight: Font.DemiBold } }
            Rectangle {
                Layout.fillWidth: true; implicitHeight: 5; radius: 3; color: "#29253e"
                visible: root.agent.xp !== undefined && Number(root.agent.xp_for_next_level) > 0
                Rectangle { height: parent.height; radius: 3; width: parent.width * Math.max(0, Math.min(1, Number(root.agent.xp) / Number(root.agent.xp_for_next_level))); color: "#aa53f4" }
            }
            Hint { visible: root.agent.xp !== undefined && Number(root.agent.xp_for_next_level) > 0; text: root.agent.xp + " / " + root.agent.xp_for_next_level + " XP toward the next level" }
            Hint { visible: !!root.progression.specialty; text: "Specialty · " + root.textValue(root.progression.specialty) }
            Hint { visible: root.reportStates.progression === "loading"; text: "Loading learning history…" }
            ColumnLayout {
                visible: root.reportStates.progression === "error"; Layout.fillWidth: true; spacing: 6
                Hint { text: root.reportErrors.progression || "Learning history couldn’t be loaded."; color: Theme.warning }
                MokaidButton { text: "Retry learning history"; quiet: true; implicitHeight: 32; enabled: root.action("progression").enabled; onClicked: root.requestReport("progression") }
            }
            ColumnLayout {
                Layout.fillWidth: true; visible: (root.progression.recent_memories || []).length > 0; spacing: 10
                SectionLabel { text: "Recently learned" }
                Repeater {
                    model: root.progression.recent_memories || []
                    RowLayout {
                        required property var modelData
                        Layout.fillWidth: true; spacing: 9
                        MokaidIcon { name: "knowledge"; size: 15; color: root.accent }
                        Hint { text: parent.modelData.title || "Mission memory" }
                    }
                }
            }
            Divider { Layout.topMargin: 5 }
            RowLayout {
                Layout.fillWidth: true; spacing: 8
                SectionLabel { text: "Training" }
                MokaidLabel { text: root.reportStates.training === "ready" ? root.training["complete?"] === true ? "Up to date" : root.training["complete?"] === false ? "In progress" : "" : ""; color: root.training["complete?"] ? Theme.success : root.accent; font.pixelSize: 11 }
            }
            Hint { text: root.reportStates.training === "loading" ? "Loading training progress…" : root.reportStates.training === "error" ? root.reportErrors.training || "Training progress couldn’t be loaded." : root.training["complete?"] === true ? "This agent is ready to put its skills to work." : root.training["complete?"] === false && root.training.target_level !== undefined ? "Building skills toward level " + root.training.target_level + "." : "Training details are not available yet."; color: root.reportStates.training === "error" ? Theme.warning : root.supporting }
            Hint { visible: root.reportStates.training === "ready" && Number((root.training.domain_pack || {}).seeded_count) > 0; text: (root.training.domain_pack || {}).seeded_count + " learning resources prepared" + (Number((root.training.domain_pack || {}).pending_count) > 0 ? " · " + (root.training.domain_pack || {}).pending_count + " remaining" : "") }
            MokaidButton { visible: root.reportStates.training === "error"; text: "Retry training progress"; quiet: true; implicitHeight: 32; enabled: root.action("training").enabled; onClicked: root.requestReport("training") }
            Item { Layout.preferredHeight: 4 }
        }
    }

    ColumnLayout {
        anchors.fill: parent; visible: root.tabIndex === 3; spacing: 12
        ScrollView {
            id: settingsScroll
            objectName: "agentSettingsScroll"; Layout.fillWidth: true; Layout.fillHeight: true; clip: true; layer.enabled: true
            background: Rectangle { color: "#11131f" }
            contentWidth: availableWidth; ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                width: settingsScroll.availableWidth; spacing: 12
                SectionLabel { text: "Make it work your way" }
                Hint { text: "Give this agent a clear role and the right level of independence." }
                ColumnLayout { Layout.fillWidth: true; spacing: 6; SectionLabel { text: "Name" } MokaidTextField { id: nameEditor; objectName: "agentSettingsName"; Layout.fillWidth: true; implicitHeight: 38; enabled: root.editEnabled; text: root.editorText("display_name"); placeholderText: "Agent name"; Accessible.name: "Agent name"; onTextChanged: root.setField("display_name", text) } }
                ColumnLayout { Layout.fillWidth: true; spacing: 6; SectionLabel { text: "Role" } MokaidTextField { objectName: "agentSettingsRole"; Layout.fillWidth: true; implicitHeight: 38; enabled: root.editEnabled; text: root.editorText("role_title"); placeholderText: "What does this agent specialize in?"; Accessible.name: "Agent role"; onTextChanged: root.setField("role_title", text) } }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 6
                    SectionLabel { text: "Instructions" }
                    MokaidTextArea {
                        objectName: "agentSettingsInstructions"; Layout.fillWidth: true; Layout.minimumHeight: 112
                        enabled: root.editEnabled; text: root.editorText("instructions"); wrapMode: TextEdit.Wrap
                        placeholderText: "Describe its responsibilities, preferred approach and boundaries…"; Accessible.name: "Agent instructions"
                        onTextChanged: root.setField("instructions", text)
                    }
                    Hint { text: "Be specific about the outcome you expect and when to ask for help." }
                }
                Divider { Layout.topMargin: 5; Layout.bottomMargin: 2 }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 6
                    SectionLabel { text: "Working style" }
                    MokaidComboBox {
                        objectName: "agentSettingsAutonomy"; Layout.fillWidth: true; implicitHeight: 38; enabled: root.editEnabled
                        model: ["Check with me", "Balanced", "Independent"]
                        currentIndex: root.autonomyOptions.indexOf(root.editorText("autonomy_mode"))
                        displayText: currentIndex < 0 ? "Choose a working style" : currentText
                        Accessible.name: "Agent working style"; onActivated: function(index) { root.setField("autonomy_mode", root.autonomyOptions[index]) }
                    }
                    Hint { text: root.editorText("autonomy_mode") === "supervised" ? "Asks for approval before taking action." : root.editorText("autonomy_mode") === "autonomous" ? "Works independently within its permissions." : root.editorText("autonomy_mode") === "balanced" ? "Works independently with safeguards for sensitive actions." : "Choose how much oversight this agent needs." }
                }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 6
                    SectionLabel { text: "Thinking style" }
                    MokaidComboBox {
                        objectName: "agentSettingsModel"; Layout.fillWidth: true; implicitHeight: 38; enabled: root.editEnabled
                        model: ["Fast", "Smart"]; currentIndex: root.modelOptions.indexOf(root.editorText("model_quality"))
                        displayText: currentIndex < 0 ? "Choose a thinking style" : currentText
                        Accessible.name: "Agent thinking style"; onActivated: function(index) { root.setField("model_quality", root.modelOptions[index]) }
                    }
                    Hint { text: root.editorText("model_quality") === "fast" ? "Prioritizes quick responses for everyday work." : root.editorText("model_quality") === "smart" ? "Prioritizes reasoning for complex work." : "Choose the approach that suits this agent’s work." }
                }
                Divider { Layout.topMargin: 5; Layout.bottomMargin: 2 }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 6
                    SectionLabel { text: "Availability" }
                    MokaidComboBox {
                        objectName: "agentSettingsStatus"; Layout.fillWidth: true; implicitHeight: 38; enabled: root.editEnabled
                        model: root.statusOptions.map(function(value) { return Logic.human(value) })
                        currentIndex: root.statusOptions.indexOf(root.editorText("status")); displayText: currentIndex < 0 ? "Choose a status" : currentText
                        Accessible.name: "Agent availability"; onActivated: function(index) { root.setField("status", root.statusOptions[index]) }
                    }
                }
                Basic.Switch {
                    id: takeoverSwitch
                    objectName: "agentSettingsTakeover"; Layout.fillWidth: true; visible: root.agent.human_takeover_enabled !== undefined && root.agent.human_takeover_enabled !== null
                    text: "Allow human takeover"; checked: root.draftValues.human_takeover_enabled === true
                    enabled: root.editEnabled; hoverEnabled: true; spacing: 10; padding: 2; leftPadding: 2; rightPadding: 2
                    Accessible.name: "Allow human takeover"; onToggled: root.setField("human_takeover_enabled", checked)
                    indicator: Rectangle {
                        implicitWidth: 34; implicitHeight: 20; x: takeoverSwitch.width - width - 2; y: (takeoverSwitch.height - height) / 2
                        radius: 10; color: takeoverSwitch.checked ? "#8543d7" : "#28263b"; border.color: takeoverSwitch.visualFocus ? Theme.focusBorder : takeoverSwitch.checked ? "#b887ff" : "#5c5c78"
                        Rectangle { x: takeoverSwitch.checked ? 17 : 3; y: 3; width: 14; height: 14; radius: 7; color: takeoverSwitch.enabled ? "#f1eaff" : "#aaa3bc" }
                    }
                    contentItem: MokaidLabel { text: takeoverSwitch.text; rightPadding: 48; font.pixelSize: 12; wrapMode: Text.Wrap; color: takeoverSwitch.enabled ? root.ink : root.supporting; verticalAlignment: Text.AlignVCenter }
                }
                Hint { visible: takeoverSwitch.visible; text: "Lets a teammate take over when hands-on help is needed." }
                Divider { Layout.topMargin: 5 }
                MokaidButton {
                    objectName: "agentSettingsPermissions"; text: "Permission rules"; iconName: root.permissionsExpanded ? "chevron-up" : "chevron-down"
                    quiet: true; Layout.fillWidth: true; implicitHeight: 36; enabled: root.selected && (!!root.action("permissions").id || root.permissionsExpanded)
                    onClicked: { root.permissionsExpanded = !root.permissionsExpanded; reportQueue.restart() }
                }
                ColumnLayout {
                    visible: root.permissionsExpanded; Layout.fillWidth: true; spacing: 10
                    Hint { visible: root.reportStates.permissions !== "ready" || root.permissionRules.length === 0; text: root.reportStates.permissions === "error" ? root.reportErrors.permissions || "Permissions couldn’t be loaded." : root.reportStates.permissions !== "ready" ? "Loading permission rules…" : "No custom rules. This agent follows its working style and workspace permissions."; color: root.reportStates.permissions === "error" ? Theme.warning : root.supporting }
                    Repeater {
                        model: root.permissionRules
                        RowLayout {
                            id: permissionRow; required property var modelData
                            Layout.fillWidth: true; spacing: 8
                            MokaidIcon { name: "shield"; size: 16; color: root.accent }
                            Hint { text: permissionRow.modelData.tool_pattern || "Workspace tool" }
                            MokaidLabel { text: Logic.human(permissionRow.modelData.behavior); color: permissionRow.modelData.behavior === "deny" ? Theme.danger : root.accent; font.pixelSize: 11 }
                        }
                    }
                    MokaidButton { visible: root.reportStates.permissions === "error"; text: "Retry permissions"; quiet: true; implicitHeight: 32; enabled: root.action("permissions").enabled; onClicked: root.requestReport("permissions") }
                }
                MokaidButton {
                    objectName: "agentSettingsSchedules"; text: "Scheduled work"; iconName: root.schedulesExpanded ? "chevron-up" : "chevron-down"
                    quiet: true; Layout.fillWidth: true; implicitHeight: 36; enabled: root.selected && (!!root.action("schedules").id || root.schedulesExpanded)
                    onClicked: { root.schedulesExpanded = !root.schedulesExpanded; reportQueue.restart() }
                }
                ColumnLayout {
                    visible: root.schedulesExpanded; Layout.fillWidth: true; spacing: 12
                    Hint { visible: root.reportStates.schedules !== "ready" || root.schedules.length === 0; text: root.reportStates.schedules === "error" ? root.reportErrors.schedules || "Scheduled work couldn’t be loaded." : root.reportStates.schedules !== "ready" ? "Loading scheduled work…" : "This agent has no scheduled work yet."; color: root.reportStates.schedules === "error" ? Theme.warning : root.supporting }
                    Repeater {
                        model: root.schedules
                        ColumnLayout {
                            id: scheduleRow; required property var modelData
                            Layout.fillWidth: true; spacing: 5
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                MokaidIcon { name: "calendar"; size: 16; color: root.accent }
                                MokaidLabel { text: scheduleRow.modelData.name || "Scheduled mission"; Layout.fillWidth: true; font.pixelSize: 12; wrapMode: Text.Wrap }
                                MokaidLabel { text: scheduleRow.modelData.enabled ? "Active" : "Paused"; color: scheduleRow.modelData.enabled ? Theme.success : root.supporting; font.pixelSize: 10 }
                            }
                            Hint { text: scheduleRow.modelData.prompt || "No instructions added." }
                            Hint { text: root.scheduleWhen(scheduleRow.modelData) + (scheduleRow.modelData.timezone ? " · " + scheduleRow.modelData.timezone : ""); font.pixelSize: 10 }
                            Hint { text: scheduleRow.modelData.last_run_at ? "Last run " + Logic.date(scheduleRow.modelData.last_run_at, true) : "Not run yet"; font.pixelSize: 10 }
                        }
                    }
                    MokaidButton { visible: root.reportStates.schedules === "error"; text: "Retry scheduled work"; quiet: true; implicitHeight: 32; enabled: root.action("schedules").enabled; onClicked: root.requestReport("schedules") }
                }
                Item { Layout.preferredHeight: 4 }
            }
        }
        Divider {}
        Hint { objectName: "agentSettingsMessage"; visible: !!root.settingsMessage || root.dirty || features.offline; text: root.settingsMessage || (features.offline ? "Reconnect to save changes." : "You have unsaved changes."); color: root.settingsError ? Theme.danger : root.settingsMessage ? Theme.success : root.supporting }
        RowLayout {
            Layout.fillWidth: true; spacing: 8
            MokaidButton { objectName: "agentSettingsDiscard"; text: "Discard"; quiet: true; Layout.fillWidth: true; implicitHeight: 38; enabled: root.dirty && !root.saving; onClicked: root.discardDraft() }
            MokaidButton { objectName: "agentSettingsSave"; text: root.saving ? "Saving…" : "Save changes"; highlighted: true; Layout.fillWidth: true; implicitHeight: 38; enabled: root.editEnabled && root.dirty; onClicked: root.saveSettings() }
        }
    }
}
