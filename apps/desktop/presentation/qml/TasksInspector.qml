pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQml.Models
import "FeatureLogic.js" as Logic

Rectangle {
    id: root
    objectName: "tasksInspector"
    required property var controller
    signal closeRequested()
    signal actionRequested(var action)
    property string activeTab: "overview"
    property bool browserMode: false
    property string pendingCommentContext: ""
    property string pendingCommentTask: ""
    property string pendingCommentText: ""
    property string commentError: ""
    property string pendingFeedbackContext: ""
    property string pendingFeedbackTask: ""
    property string pendingFeedbackText: ""
    property string feedbackError: ""
    property bool improving: false
    property string pendingBudgetContext: ""
    property string budgetError: ""
    property bool budgetIncreased: false
    property int budgetRetryCredits: 0
    readonly property var currentRecord: features.currentPage === "tasks" ? features.selectedRecord || ({}) : ({})
    readonly property string taskId: features.currentPage === "tasks" ? features.selectedId : ""
    readonly property string taskRunState: Logic.taskRunState(currentRecord)
    readonly property string latestRunId: (currentRecord.latest_run || {}).id || ""
    readonly property var runtime: Logic.taskRuntime(currentRecord)
    readonly property var toolEvents: list((currentRecord.latest_run || {}).tool_activity)
    readonly property var selectionActions: features.currentPage === "tasks" ? features.actions.filter(function(action) { return action.selection }) : []
    readonly property var editAction: action("edit")
    readonly property var commentAction: action("comment")
    readonly property var comments: list(currentRecord.comments)
    readonly property var subtasks: list(currentRecord.subtasks)
    readonly property var files: features.showingRecordDetails && !features.detailView.canGoBack ? features.detailView.deliverables : []
    readonly property int runtimeFileCount: runtime.manifest ? list(runtime.manifest).filter(function(file) { return !!file.id }).length : files.length
    readonly property var progressValue: Logic.progress(currentRecord)
    readonly property bool sendingComment: pendingCommentContext.length > 0
    readonly property bool statusPending: features.pendingTaskId === taskId
    readonly property var statuses: [
        { id: "to_do", label: "Todo", color: "#dfe4f7" },
        { id: "in_progress", label: "In progress", color: "#7a9cff" },
        { id: "in_review", label: "In review", color: "#ffc568" },
        { id: "waiting", label: "Waiting", color: "#ffc568" },
        { id: "blocked", label: "Blocked", color: "#ff929e" },
        { id: "overdue", label: "Overdue", color: "#ff929e" },
        { id: "completed", label: "Completed", color: "#67eaa3" },
        { id: "canceled", label: "Canceled", color: "#a4aec9" }
    ]
    readonly property var statusInfo: statuses.find(function(status) { return status.id === root.currentRecord.status }) || ({label: Logic.status(currentRecord, "tasks") || "Todo", color: "#dfe4f7"})
    readonly property color statusColor: statusInfo.color
    readonly property var primaryRunAction: taskRunState === "running" ? action("stop") : action("run")
    readonly property string responseText: Logic.taskResponse(currentRecord)
    readonly property bool awaitingPdf: (currentRecord.pending_approval || {}).tool_name === "export_pdf"
    readonly property var pendingDecision: currentRecord.pending_approval || ({})
    readonly property bool needsDecision: !!pendingDecision.id && !awaitingPdf && taskRunState !== "running" && currentRecord.status !== "canceled"
    readonly property bool deliveryChoice: (pendingDecision.input_payload || {}).kind === "site_delivery_choice"
    readonly property bool responseReady: (currentRecord.latest_run || {}).status === "completed"
    readonly property var responseFeedback: currentRecord.response_feedback || ({})
    readonly property bool accepted: responseFeedback.rating === "good" && (responseFeedback.run_id || "") === ((currentRecord.latest_run || {}).id || "")
    readonly property bool hasResponse: responseReady && (String(((currentRecord.latest_run || {}).output || {}).summary || "").trim().length > 0 || list(((currentRecord.latest_run || {}).output || {}).artifacts).length > 0)
    readonly property bool canReview: !awaitingPdf && !!(currentRecord.latest_run || {}).id && !!currentRecord.assigned_agent_id && currentRecord.assigned_agent_kind !== "human_linked" && taskRunState !== "running" && currentRecord.status !== "canceled" && (hasResponse || taskRunState === "feedback" || taskRunState === "failed" || ["completed", "waiting_for_user_input", "needs_input"].indexOf((currentRecord.latest_run || {}).status) >= 0)
    readonly property bool sendingFeedback: pendingFeedbackContext.length > 0
    readonly property bool canShowRun: !awaitingPdf && (taskRunState === "running" || (!canReview && !!currentRecord.assigned_agent_id && currentRecord.assigned_agent_kind !== "human_linked" && ["completed", "canceled"].indexOf(currentRecord.status) < 0))

    color: "#10121d"
    border.color: "#353048"
    radius: 16
    clip: true
    implicitWidth: 410
    implicitHeight: 720

    // QVariantList is an indexed QML sequence, but is not always a JS Array.
    function list(value) {
        const result = []
        if (value && typeof value.length === "number")
            for (let i = 0; i < value.length; ++i) result.push(value[i])
        return result
    }
    function action(id) { return selectionActions.find(function(candidate) { return candidate.id === id }) || ({id: id, title: "", enabled: false}) }
    function request(next) {
        if (!next.enabled) return
        if (next.id === "runs") { activeTab = "activity"; browserMode = true }
        if (next.id === "comment") { composer.forceActiveFocus(); return }
        actionRequested(next)
    }
    function showActivity() { request(action("runs")) }
    function switchTab(tab) {
        activeTab = tab
        browserMode = false
        if (!features.showingRecordDetails || features.detailView.canGoBack) features.showRecordDetails()
    }
    function draft(id) { return String(controller.commentDrafts[id] || "") }
    function sendComment() {
        const body = draft(taskId).trim()
        if (!body || !commentAction.enabled || sendingComment || features.busy) return
        pendingCommentTask = taskId
        pendingCommentText = draft(taskId)
        pendingCommentContext = features.actionContext("comment")
        commentError = ""
        features.submit("comment", { body: body, _context: pendingCommentContext })
    }
    function respond(decision, payload) {
        if (!needsDecision || !action("respond").enabled) return
        const values = { approval_request_id: pendingDecision.id, decision: decision, _context: features.actionContext("respond") }
        if (payload) values.payload = payload
        features.submit("respond", values)
    }
    function improvementDraft(id) { return String(controller.improvementDrafts[id] || "") }
    function startImproving() {
        improving = true
        feedbackError = ""
        Qt.callLater(function() { improvementPrompt.forceActiveFocus() })
    }
    function extendBudget(credits) {
        const runId = (currentRecord.latest_run || {}).id
        if (!runId || pendingBudgetContext || !action("runtime-budget").enabled || budgetIncreased || (budgetRetryCredits && budgetRetryCredits !== credits)) return
        budgetRetryCredits = credits
        budgetError = ""
        pendingBudgetContext = features.actionContext("runtime-budget")
        features.submit("runtime-budget", {run_id: runId, additional_credits: credits, _context: pendingBudgetContext})
    }
    function sendFeedback(rating) {
        if (!canReview || !action("feedback").enabled || sendingFeedback || features.busy) return
        const prompt = improvementDraft(taskId).trim()
        if ((rating === "needs_improvement" && !prompt) || (rating === "good" && !hasResponse)) return
        pendingFeedbackTask = taskId
        pendingFeedbackText = improvementDraft(taskId)
        pendingFeedbackContext = features.actionContext("feedback")
        feedbackError = ""
        const values = { rating: rating, _context: pendingFeedbackContext }
        if (rating === "needs_improvement") values.prompt = prompt
        const runId = (currentRecord.latest_run || {}).id
        if (runId) values.run_id = runId
        features.submit("feedback", values)
    }
    function initials(name) {
        const words = String(name || "?").trim().split(/\s+/)
        return (words[0].charAt(0) + (words.length > 1 ? words[words.length - 1].charAt(0) : "")).toUpperCase()
    }
    function author(comment) { return Logic.first(comment, ["author_name", "member_name", "agent_name"], "Workspace member") }
    function activityAuthor(event) {
        if (event.agent_name) return event.agent_name
        const participant = list(runtime.participants).find(function(row) { return row.agent_id === event.agent_id })
        return participant ? participant.name : ""
    }
    function resetPending() {
        pendingCommentContext = ""
        pendingCommentTask = ""
        pendingCommentText = ""
        pendingFeedbackContext = ""
        pendingFeedbackTask = ""
        pendingFeedbackText = ""
        feedbackError = ""
        improving = false
        pendingBudgetContext = ""
        budgetError = ""
        budgetIncreased = false
        budgetRetryCredits = 0
        commentError = ""
    }
    function closeIfAllowed(event) {
        if (selectionMenu.opened || statusMenu.opened) { event.accepted = false; return }
        event.accepted = true
        closeRequested()
    }
    Keys.onEscapePressed: function(event) { root.closeIfAllowed(event) }
    onLatestRunIdChanged: {
        pendingBudgetContext = ""
        budgetError = ""
        budgetIncreased = false
        budgetRetryCredits = 0
    }
    onRuntimeChanged: {
        if (runtime.status === "running" && !pendingBudgetContext) {
            budgetIncreased = false
            budgetError = ""
            budgetRetryCredits = 0
        }
    }
    onTaskIdChanged: {
        activeTab = "overview"
        browserMode = false
        commentError = ""
        feedbackError = ""
        improving = improvementDraft(taskId).length > 0
        pendingBudgetContext = ""
        budgetError = ""
        budgetIncreased = false
        budgetRetryCredits = 0
        statusMenu.close()
        selectionMenu.close()
    }
    Connections {
        target: session
        ignoreUnknownSignals: true
        function onWorkspaceChanged() { root.resetPending() }
        function onCleared() { root.resetPending() }
    }
    Connections {
        target: features
        function onActionSucceeded(context) {
            if (root.pendingBudgetContext && context === root.pendingBudgetContext) {
                root.pendingBudgetContext = ""
                root.budgetError = ""
                root.budgetIncreased = true
                root.budgetRetryCredits = 0
            }
            if (root.pendingCommentContext && context === root.pendingCommentContext) {
                if (root.draft(root.pendingCommentTask) === root.pendingCommentText) root.controller.setCommentDraft(root.pendingCommentTask, "")
                root.pendingCommentContext = ""
                root.pendingCommentText = ""
                root.pendingCommentTask = ""
                root.commentError = ""
            }
            if (root.pendingFeedbackContext && context === root.pendingFeedbackContext) {
                if (root.improvementDraft(root.pendingFeedbackTask) === root.pendingFeedbackText)
                    root.controller.setImprovementDraft(root.pendingFeedbackTask, "")
                if (root.pendingFeedbackTask === root.taskId) { root.improving = false; root.feedbackError = "" }
                root.pendingFeedbackContext = ""
                root.pendingFeedbackTask = ""
                root.pendingFeedbackText = ""
            }
        }
        function onChanged() {
            if (features.currentPage !== "tasks") { root.resetPending(); return }
            if (root.pendingBudgetContext && !features.busy && features.error.length) {
                root.budgetError = features.error
                root.pendingBudgetContext = ""
            }
            if (root.pendingCommentContext && !features.busy && features.error.length) {
                if (root.pendingCommentTask === root.taskId) root.commentError = features.error
                root.pendingCommentContext = ""
                root.pendingCommentTask = ""
                root.pendingCommentText = ""
            }
            if (root.pendingFeedbackContext && !features.busy && features.error.length) {
                if (root.pendingFeedbackTask === root.taskId) root.feedbackError = features.error
                root.pendingFeedbackContext = ""
                root.pendingFeedbackTask = ""
                root.pendingFeedbackText = ""
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 20; Layout.rightMargin: 16; Layout.topMargin: 12; Layout.bottomMargin: 14
            spacing: 10
            RowLayout {
                Layout.fillWidth: true; spacing: 6
                MokaidIcon { name: "tasks"; size: 15; color: Theme.muted }
                MokaidLabel { text: "Tasks"; color: Theme.muted; font.pixelSize: 11 }
                MokaidIcon { name: "chevron-right"; size: 12; color: "#6f7996" }
                MokaidLabel { text: "Task details"; font.pixelSize: 11; color: Theme.secondary; Layout.fillWidth: true }
                MokaidButton { objectName: "selectionActionsButton"; implicitHeight: 32; implicitWidth: 32; iconName: "more"; quiet: true; Accessible.name: "More task actions"; onClicked: selectionMenu.openFor(this); ToolTip.visible: hovered; ToolTip.text: "More actions" }
                MokaidButton { objectName: "taskInspectorClose"; implicitHeight: 32; implicitWidth: 32; iconName: "close"; quiet: true; Accessible.name: "Close task details"; onClicked: root.closeRequested(); ToolTip.visible: hovered; ToolTip.text: "Close details · Esc" }
            }
            MokaidLabel {
                objectName: "taskInspectorTitle"
                Layout.fillWidth: true; Layout.rightMargin: 4
                text: Logic.title(root.currentRecord, "tasks")
                font.pixelSize: 21; font.weight: Font.DemiBold
                wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
                Accessible.name: text
            }
            RowLayout {
                Layout.fillWidth: true; spacing: 8
                Button {
                    id: statusButton
                    objectName: "taskStatusButton"
                    implicitWidth: statusContents.implicitWidth + 24; implicitHeight: 33
                    enabled: features.canMoveTasks && !root.statusPending
                    hoverEnabled: true
                    Accessible.name: "Change task status. Current status: " + root.statusInfo.label
                    onClicked: statusMenu.openFor(this)
                    contentItem: RowLayout {
                        id: statusContents
                        spacing: 7
                        Rectangle { implicitWidth: 7; implicitHeight: 7; radius: 4; color: root.statusInfo.color }
                        MokaidLabel { text: root.statusPending ? "Updating…" : root.statusInfo.label; font.pixelSize: 11; font.weight: Font.DemiBold; color: root.statusInfo.color }
                        MokaidIcon { name: "chevron-down"; size: 12; color: root.statusInfo.color }
                    }
                    background: Rectangle { radius: 7; color: Logic.alpha(root.statusColor, statusButton.hovered ? .15 : .08); border.color: statusButton.visualFocus ? Theme.focusBorder : Logic.alpha(root.statusColor, .26) }
                }
                Rectangle {
                    visible: !!root.currentRecord.priority
                    implicitWidth: priorityText.implicitWidth + 16; implicitHeight: 27; radius: 7
                    color: Logic.alpha(root.currentRecord.priority === "high" || root.currentRecord.priority === "urgent" ? Theme.danger : Theme.primary, .1)
                    MokaidLabel { id: priorityText; anchors.centerIn: parent; text: Logic.human(root.currentRecord.priority); font.pixelSize: 10; color: root.currentRecord.priority === "high" || root.currentRecord.priority === "urgent" ? Theme.danger : "#baa0f7" }
                }
                Item { Layout.fillWidth: true }
                MokaidButton { objectName: "taskEditButton"; implicitHeight: 32; implicitWidth: 32; iconName: "pen"; quiet: true; enabled: root.editAction.enabled; Accessible.name: "Edit task"; onClicked: root.request(root.editAction); ToolTip.visible: hovered; ToolTip.text: "Edit task" }
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: "#282737" }
        RowLayout {
            Layout.fillWidth: true; Layout.leftMargin: 20; Layout.rightMargin: 20; spacing: 20
            Repeater {
                model: [{ id: "overview", label: "Overview" }, { id: "activity", label: "Activity" }, { id: "files", label: "Files" }]
                Button {
                    id: tabButton
                    required property var modelData
                    objectName: "taskTab_" + modelData.id
                    implicitWidth: tabLabel.implicitWidth + 8; implicitHeight: 44
                    checkable: true; checked: root.activeTab === modelData.id
                    Accessible.name: modelData.label
                    onClicked: root.switchTab(modelData.id)
                    contentItem: MokaidLabel { id: tabLabel; text: tabButton.modelData.label; font.pixelSize: 12; font.weight: tabButton.checked ? Font.DemiBold : Font.Medium; color: tabButton.checked ? "#c5a9ff" : Theme.muted; verticalAlignment: Text.AlignVCenter; horizontalAlignment: Text.AlignHCenter }
                    background: Item {
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; radius: 1; color: "#b182ff"; visible: tabButton.checked }
                        Rectangle { anchors.fill: parent; anchors.margins: 3; radius: 6; color: "transparent"; border.color: Theme.focusBorder; visible: tabButton.visualFocus }
                    }
                }
            }
            Item { Layout.fillWidth: true }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: "#222332" }

        ScrollView {
            id: overviewScroll
            objectName: "taskOverviewScroll"
            visible: root.activeTab === "overview"
            Layout.fillWidth: true; Layout.fillHeight: true
            contentWidth: availableWidth; clip: true
            layer.enabled: true
            background: Rectangle { color: root.color }
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                width: overviewScroll.availableWidth; spacing: 20
                ColumnLayout {
                    Layout.fillWidth: true; Layout.margins: 20; Layout.bottomMargin: 0; spacing: 20
                    TaskRuntimePanel { Layout.fillWidth: true; runtime: root.runtime; fileCount: root.runtimeFileCount; canExtendBudget: root.action("runtime-budget").enabled; extendingBudget: root.pendingBudgetContext.length > 0; budgetIncreased: root.budgetIncreased; budgetRetryCredits: root.budgetRetryCredits; budgetError: root.budgetError; onExtendBudgetRequested: function(credits) { root.extendBudget(credits) }; onFilesRequested: root.switchTab("files") }
                    GridLayout {
                        Layout.fillWidth: true; columns: 2; columnSpacing: 14; rowSpacing: 18
                        ColumnLayout {
                            Layout.fillWidth: true; Layout.preferredWidth: 1; spacing: 7
                            MokaidLabel { text: "Assigned to"; color: Theme.muted; font.pixelSize: 10 }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 7
                                WorkforcePortrait {
                                    size: 27
                                    agent: root.controller.portraitFor(root.currentRecord)
                                }
                                MokaidLabel { Layout.fillWidth: true; text: root.currentRecord.assigned_agent_name || "Unassigned"; elide: Text.ElideRight; font.pixelSize: 12 }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; Layout.preferredWidth: 1; spacing: 9
                            MokaidLabel { text: "Due date"; color: Theme.muted; font.pixelSize: 10 }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 7
                                MokaidIcon { name: "calendar"; size: 16; color: Theme.secondary }
                                MokaidLabel { Layout.fillWidth: true; text: Logic.shortDate(root.currentRecord.due_at) || "No due date"; elide: Text.ElideRight; font.pixelSize: 12; color: root.currentRecord.status === "overdue" ? Theme.danger : Theme.text }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; Layout.preferredWidth: 1; spacing: 9
                            MokaidLabel { text: "Project"; color: Theme.muted; font.pixelSize: 10 }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 7
                                MokaidIcon { name: "projects"; size: 16; color: Theme.secondary }
                                MokaidLabel { Layout.fillWidth: true; text: root.currentRecord.project_name || "No project"; elide: Text.ElideRight; font.pixelSize: 12 }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; Layout.preferredWidth: 1; spacing: 9
                            MokaidLabel { text: "Priority"; color: Theme.muted; font.pixelSize: 10 }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 7
                                MokaidIcon { name: "analytics"; size: 16; color: root.currentRecord.priority === "high" || root.currentRecord.priority === "urgent" ? Theme.danger : Theme.primary }
                                MokaidLabel { Layout.fillWidth: true; text: Logic.human(root.currentRecord.priority) || "Not set"; font.pixelSize: 12 }
                            }
                        }
                    }
                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: "#282737" }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 9
                        RowLayout {
                            Layout.fillWidth: true
                            MokaidLabel { text: "The brief"; font.pixelSize: 13; font.weight: Font.DemiBold; Layout.fillWidth: true }
                            MokaidButton { implicitHeight: 26; implicitWidth: 26; iconName: "pen"; quiet: true; enabled: root.editAction.enabled; Accessible.name: "Edit task brief"; onClicked: root.request(root.editAction) }
                        }
                        TextEdit { objectName: "taskBrief"; Layout.fillWidth: true; text: Logic.body("tasks", root.currentRecord) || "Add a clear brief so your teammate knows what success looks like."; readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText; color: Logic.body("tasks", root.currentRecord) ? "#c9d1e7" : Theme.muted; font.family: Theme.fontFamily; font.pixelSize: 12; selectionColor: Theme.selection; selectedTextColor: Theme.text; Accessible.name: "Task brief" }
                    }
                    Rectangle {
                        Layout.fillWidth: true; implicitHeight: executionContent.implicitHeight + 26; radius: 11
                        color: "#171528"; border.color: "#342b4c"
                        ColumnLayout {
                            id: executionContent
                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 13; spacing: 10
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                MokaidIcon { name: "bolt"; size: 16; color: Theme.primary }
                                MokaidLabel { Layout.fillWidth: true; text: root.awaitingPdf ? "Exporting PDF" : root.accepted ? "Response accepted" : root.canReview && root.hasResponse ? "How is the response?" : root.canReview ? "Continue the task" : root.taskRunState === "running" ? "Agent is working" : "Agent workspace"; font.pixelSize: 12; font.weight: Font.DemiBold }
                            }
                            MokaidLabel { visible: !root.responseText; Layout.fillWidth: true; text: root.awaitingPdf ? "Your agent is creating the PDF. It will appear in Files when ready." : Logic.taskHint(root.currentRecord); color: root.taskRunState === "failed" ? Theme.danger : Theme.secondary; font.pixelSize: 11; wrapMode: Text.Wrap }
                            ColumnLayout {
                                visible: root.progressValue !== null && !root.canReview
                                Layout.fillWidth: true; spacing: 6
                                RowLayout {
                                    Layout.fillWidth: true
                                    MokaidLabel { text: "Progress"; Layout.fillWidth: true; font.pixelSize: 10; color: Theme.muted }
                                    MokaidLabel { text: (root.progressValue || 0) + "%"; font.pixelSize: 10; color: Theme.secondary }
                                }
                                Rectangle {
                                    Layout.fillWidth: true; implicitHeight: 5; radius: 3; color: "#2d2a40"
                                    Rectangle { width: parent.width * (root.progressValue || 0) / 100; height: parent.height; radius: 3; color: root.currentRecord.status === "completed" ? Theme.success : "#b17bff" }
                                }
                            }
                            TextEdit {
                                objectName: "taskResponse"
                                visible: root.responseText.length > 0
                                Layout.fillWidth: true
                                text: root.responseText; readOnly: true; selectByMouse: true
                                wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText
                                color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: 12
                                selectionColor: Theme.selection; selectedTextColor: Theme.text
                                Accessible.name: "Agent response"
                            }
                            ColumnLayout {
                                visible: root.needsDecision
                                Layout.fillWidth: true; spacing: 8
                                MokaidLabel { Layout.fillWidth: true; text: root.pendingDecision.proposed_action || "Your agent has a question before continuing."; font.pixelSize: 12; color: Theme.text; wrapMode: Text.Wrap }
                                RowLayout {
                                    Layout.fillWidth: true; spacing: 8
                                    MokaidButton { visible: !root.deliveryChoice; objectName: "taskDecisionAllow"; text: "Allow once"; highlighted: true; Layout.fillWidth: true; implicitHeight: 35; font.pixelSize: 11; enabled: root.action("respond").enabled; onClicked: root.respond("approved") }
                                    MokaidButton { visible: !root.deliveryChoice; objectName: "taskDecisionDecline"; text: "Decline"; Layout.fillWidth: true; implicitHeight: 35; font.pixelSize: 11; enabled: root.action("respond").enabled; onClicked: root.respond("rejected") }
                                    MokaidButton { visible: root.deliveryChoice; objectName: "taskDeliveryHtml"; text: "HTML website"; highlighted: true; Layout.fillWidth: true; implicitHeight: 35; font.pixelSize: 11; enabled: root.action("respond").enabled; onClicked: root.respond("edited", {delivery: "html"}) }
                                    MokaidButton { visible: root.deliveryChoice; objectName: "taskDeliveryWebapp"; text: "Web app"; Layout.fillWidth: true; implicitHeight: 35; font.pixelSize: 11; enabled: root.action("respond").enabled; onClicked: root.respond("edited", {delivery: "webapp"}) }
                                }
                                MokaidLabel { visible: features.error.length > 0; Layout.fillWidth: true; text: features.error; color: Theme.danger; font.pixelSize: 11; wrapMode: Text.Wrap }
                            }
                            RowLayout {
                                visible: root.canReview
                                Layout.fillWidth: true; spacing: 8
                                MokaidButton {
                                    objectName: "taskFeedbackGood"; Layout.fillWidth: true; Layout.minimumWidth: 0
                                    text: root.accepted ? "Accepted" : "Good response"; iconName: "check"
                                    implicitHeight: 35; font.pixelSize: 11; highlighted: !root.improving
                                    enabled: root.hasResponse && !root.accepted && root.action("feedback").enabled && !root.sendingFeedback
                                    onClicked: root.sendFeedback("good")
                                }
                                MokaidButton {
                                    objectName: "taskFeedbackImprove"; Layout.fillWidth: true; Layout.minimumWidth: 0
                                    text: "Needs improvement"; iconName: "pen"; implicitHeight: 35; font.pixelSize: 11
                                    enabled: root.action("feedback").enabled && !root.sendingFeedback
                                    onClicked: root.startImproving()
                                }
                            }
                            ColumnLayout {
                                visible: root.canReview && root.improving
                                Layout.fillWidth: true; spacing: 8
                                ScrollView {
                                    Layout.fillWidth: true; Layout.minimumWidth: 0; Layout.preferredHeight: 110
                                    contentWidth: availableWidth; clip: true
                                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                                    MokaidTextArea {
                                        id: improvementPrompt
                                        objectName: "taskFeedbackPrompt"
                                        width: parent.width
                                        placeholderText: "Tell the agent what to improve or do next…"
                                        text: root.improvementDraft(root.taskId)
                                        wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText
                                        enabled: !root.sendingFeedback
                                        Accessible.name: "Instructions to improve the response"
                                        onTextChanged: if (root.taskId && text !== root.improvementDraft(root.taskId)) root.controller.setImprovementDraft(root.taskId, text)
                                        Keys.onPressed: function(event) {
                                            if ((event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { root.sendFeedback("needs_improvement"); event.accepted = true }
                                        }
                                    }
                                }
                                MokaidButton {
                                    objectName: "taskFeedbackContinue"; Layout.fillWidth: true
                                    text: root.sendingFeedback ? "Sending…" : "Continue and improve"; iconName: "play"
                                    implicitHeight: 35; font.pixelSize: 11; highlighted: true
                                    enabled: root.action("feedback").enabled && !root.sendingFeedback && root.improvementDraft(root.taskId).trim().length > 0
                                    onClicked: root.sendFeedback("needs_improvement")
                                }
                            }
                            MokaidLabel { visible: root.feedbackError.length > 0; Layout.fillWidth: true; text: root.feedbackError; color: Theme.danger; font.pixelSize: 11; wrapMode: Text.Wrap; Accessible.role: Accessible.AlertMessage }
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                MokaidButton { visible: root.canShowRun; objectName: "taskQuick_" + root.primaryRunAction.id; Layout.fillWidth: true; Layout.minimumWidth: 0; implicitHeight: 35; font.pixelSize: 11; highlighted: root.taskRunState !== "running"; text: root.taskRunState === "running" ? "Stop agent" : "Start agent"; iconName: root.taskRunState === "running" ? "stop" : "play"; enabled: root.primaryRunAction.enabled; onClicked: root.request(root.primaryRunAction) }
                                MokaidButton { objectName: "taskQuick_runs"; text: "Activity"; iconName: "pulse"; implicitHeight: 35; font.pixelSize: 11; enabled: root.action("runs").enabled; onClicked: root.showActivity() }
                            }
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 10; visible: root.subtasks.length > 0
                        RowLayout {
                            Layout.fillWidth: true
                            MokaidLabel { text: "Subtasks"; font.pixelSize: 13; font.weight: Font.DemiBold; Layout.fillWidth: true }
                            MokaidLabel { text: root.subtasks.filter(Logic.subtaskDone).length + " / " + root.subtasks.length; font.pixelSize: 11; color: Theme.muted }
                        }
                        Repeater {
                            model: root.subtasks
                            RowLayout {
                                id: subtaskRow
                                required property var modelData
                                Layout.fillWidth: true; spacing: 9
                                Rectangle {
                                    implicitWidth: 18; implicitHeight: 18; radius: 5
                                    color: Logic.subtaskDone(subtaskRow.modelData) ? Logic.alpha(Theme.success, .12) : "transparent"
                                    border.color: Logic.subtaskDone(subtaskRow.modelData) ? Theme.success : "#555d78"
                                    MokaidIcon { anchors.centerIn: parent; visible: Logic.subtaskDone(subtaskRow.modelData); name: "check"; size: 12; color: Theme.success }
                                }
                                MokaidLabel { Layout.fillWidth: true; text: subtaskRow.modelData.title || subtaskRow.modelData.name || "Subtask"; wrapMode: Text.Wrap; font.pixelSize: 12; color: Logic.subtaskDone(subtaskRow.modelData) ? Theme.muted : Theme.secondary; font.strikeout: Logic.subtaskDone(subtaskRow.modelData) }
                            }
                        }
                    }
                    MokaidButton { text: "All task information"; iconName: "chevron-right"; quiet: true; implicitHeight: 32; font.pixelSize: 11; onClicked: { root.activeTab = "activity"; root.browserMode = true; features.showRecordDetails() } }
                }
                Item { Layout.preferredHeight: 3 }
            }
        }

        ScrollView {
            id: activityScroll
            visible: root.activeTab === "activity" && !root.browserMode
            Layout.fillWidth: true; Layout.fillHeight: true; contentWidth: availableWidth; clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                width: activityScroll.availableWidth; spacing: 18
                ColumnLayout {
                    Layout.fillWidth: true; Layout.margins: 20; spacing: 18
                    RowLayout {
                        Layout.fillWidth: true
                        MokaidLabel { text: "Conversation"; font.pixelSize: 13; font.weight: Font.DemiBold; Layout.fillWidth: true }
                        MokaidLabel { visible: root.comments.length > 0; text: root.comments.length; font.pixelSize: 11; color: Theme.muted }
                    }
                    MokaidLabel { visible: root.comments.length === 0; Layout.fillWidth: true; text: "Keep decisions and feedback together. Add the first comment below."; font.pixelSize: 12; wrapMode: Text.Wrap; color: Theme.muted }
                    Repeater {
                        model: root.comments
                        RowLayout {
                            id: commentRow
                            required property var modelData
                            Layout.fillWidth: true; spacing: 10; Layout.alignment: Qt.AlignTop
                            Rectangle { Layout.alignment: Qt.AlignTop; implicitWidth: 27; implicitHeight: 27; radius: 14; color: "#272239"; border.color: "#51426c"; MokaidLabel { anchors.centerIn: parent; text: root.initials(root.author(commentRow.modelData)); font.pixelSize: 9; color: "#d4bfff" } }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 6
                                RowLayout {
                                    Layout.fillWidth: true
                                    MokaidLabel { text: root.author(commentRow.modelData); Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: 11; font.weight: Font.DemiBold; color: Theme.secondary }
                                    MokaidLabel { text: Logic.shortDate(commentRow.modelData.inserted_at || commentRow.modelData.created_at); font.pixelSize: 9; color: Theme.muted }
                                }
                                TextEdit { Layout.fillWidth: true; text: String(commentRow.modelData.body || ""); readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText; color: Theme.secondary; font.family: Theme.fontFamily; font.pixelSize: 12; selectionColor: Theme.selection; selectedTextColor: Theme.text; Accessible.name: "Comment by " + root.author(commentRow.modelData) }
                            }
                        }
                    }
                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: "#282737" }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 9
                        MokaidLabel { text: "Agent activity"; font.pixelSize: 13; font.weight: Font.DemiBold }
                        TaskRuntimePanel { Layout.fillWidth: true; runtime: root.runtime; fileCount: root.runtimeFileCount; canExtendBudget: root.action("runtime-budget").enabled; extendingBudget: root.pendingBudgetContext.length > 0; budgetIncreased: root.budgetIncreased; budgetRetryCredits: root.budgetRetryCredits; budgetError: root.budgetError; onExtendBudgetRequested: function(credits) { root.extendBudget(credits) }; onFilesRequested: root.switchTab("files") }
                        Repeater {
                            model: root.toolEvents
                            MokaidLabel {
                                required property var modelData
                                Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 11; color: Theme.secondary; textFormat: Text.PlainText
                                text: (root.activityAuthor(modelData) ? root.activityAuthor(modelData) + " · " : "") + (modelData.description || modelData.tool || "Activity")
                            }
                        }
                        MokaidLabel { visible: !root.responseText; Layout.fillWidth: true; text: Logic.taskHint(root.currentRecord); color: Theme.muted; font.pixelSize: 12; wrapMode: Text.Wrap }
                        MokaidButton { objectName: "taskExecutionHistory"; text: "View execution history"; iconName: "pulse"; implicitHeight: 36; font.pixelSize: 11; enabled: root.action("runs").enabled; onClicked: root.showActivity() }
                    }
                }
            }
        }

        ColumnLayout {
            visible: root.activeTab === "activity" && root.browserMode
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.margins: 16; spacing: 10
            RowLayout {
                Layout.fillWidth: true
                MokaidButton { iconName: "chevron-left"; quiet: true; implicitHeight: 30; implicitWidth: 30; Accessible.name: features.detailView.canGoBack ? "Back in task activity" : "Back to conversation"; onClicked: { if (features.detailView.canGoBack) features.detailView.goBack(); else root.switchTab("activity") } }
                MokaidLabel { text: features.detailView.heading; Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: 12; font.weight: Font.DemiBold; color: Theme.secondary }
            }
            ListView {
                id: detailRows
                objectName: "taskActivityDetails"
                Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 8; reuseItems: true
                model: features.detailView.rows
                delegate: Rectangle {
                    id: detailDelegate
                    required property string rowId
                    required property string title
                    required property var record
                    width: detailRows.width; height: detailContent.implicitHeight + 22
                    color: record.container ? "#171927" : "transparent"; radius: 9
                    border.color: record.container ? "#2b2c42" : "transparent"
                    ColumnLayout {
                        id: detailContent
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 11; spacing: 7
                        MokaidLabel { Layout.fillWidth: true; text: detailDelegate.title; wrapMode: Text.Wrap; font.pixelSize: 11; font.weight: Font.DemiBold; color: Theme.secondary }
                        TextEdit { Layout.fillWidth: true; text: detailDelegate.record.text || ""; readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText; color: Theme.text; font.family: Theme.fontFamily; font.pixelSize: 12; selectionColor: Theme.selection; selectedTextColor: Theme.text; Accessible.name: detailDelegate.title }
                        Flow {
                            Layout.fillWidth: true; spacing: 5
                            visible: detailDelegate.record.expandable || detailDelegate.record.fileAvailable || (detailDelegate.record.referencePage || "").length > 0
                            MokaidButton { implicitHeight: 31; font.pixelSize: 10; text: detailDelegate.record.container ? "Explore" : "Read full text"; visible: detailDelegate.record.expandable; onClicked: features.detailView.enter(detailDelegate.rowId) }
                            MokaidButton { implicitHeight: 31; font.pixelSize: 10; text: "Open record"; visible: (detailDelegate.record.referencePage || "").length > 0; onClicked: features.detailView.openReference(detailDelegate.rowId) }
                            MokaidButton { implicitHeight: 31; font.pixelSize: 10; text: "Open deliverable"; visible: detailDelegate.record.fileAvailable; onClicked: features.detailView.openFile(detailDelegate.rowId) }
                        }
                    }
                }
                MokaidLabel { anchors.centerIn: parent; width: parent.width - 20; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; visible: detailRows.count === 0; text: features.busy ? "Loading activity…" : "No activity is available yet."; font.pixelSize: 12; color: Theme.muted }
                ScrollBar.vertical: ScrollBar {}
            }
        }

        ScrollView {
            id: filesScroll
            visible: root.activeTab === "files"
            Layout.fillWidth: true; Layout.fillHeight: true; contentWidth: availableWidth; clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ColumnLayout {
                width: filesScroll.availableWidth; spacing: 16
                ColumnLayout {
                    Layout.fillWidth: true; Layout.margins: 20; spacing: 12
                    MokaidLabel { text: "Files & deliverables"; font.pixelSize: 13; font.weight: Font.DemiBold }
                    MokaidLabel { visible: root.files.length === 0; Layout.fillWidth: true; text: features.busy ? "Loading files…" : "Files and deliverables from this task will stay available here."; wrapMode: Text.Wrap; font.pixelSize: 12; color: Theme.muted }
                    DeliveryGallery { Layout.fillWidth: true; showHeading: false; files: root.files }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: "#2a263b" }
        ColumnLayout {
            Layout.fillWidth: true; Layout.margins: 14; Layout.topMargin: 12; spacing: 7
            MokaidLabel { visible: root.commentError.length > 0; Layout.fillWidth: true; text: root.commentError; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight; font.pixelSize: 10; color: Theme.danger }
            Rectangle {
                Layout.fillWidth: true; implicitHeight: 90; radius: 11; color: "#0d0f19"
                border.color: composer.activeFocus ? "#8e68d2" : "#333047"
                ScrollView {
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 2
                    height: 48; clip: true; contentWidth: availableWidth
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                    MokaidTextArea {
                        id: composer
                        objectName: "taskCommentComposer"
                        width: parent.width
                        padding: 10; font.pixelSize: 12; wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText
                        placeholderText: "Write a comment…"
                        text: root.draft(root.taskId)
                        onTextChanged: { if (root.taskId && text !== root.draft(root.taskId)) root.controller.setCommentDraft(root.taskId, text) }
                        background: Item {}
                        Accessible.name: "Task comment"
                        Keys.onPressed: function(event) { if ((event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { root.sendComment(); event.accepted = true } }
                    }
                }
                RowLayout {
                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.leftMargin: 11; anchors.rightMargin: 7; anchors.bottomMargin: 7
                    spacing: 8
                    MokaidLabel { Layout.fillWidth: true; text: features.offline ? "Draft saved · Offline" : root.draft(root.taskId).length ? "Draft saved in this workspace" : "⌘ / Ctrl + Enter to send"; color: "#818da9"; font.pixelSize: 9; elide: Text.ElideRight }
                    MokaidButton { objectName: "taskQuick_comment"; implicitHeight: 29; implicitWidth: 78; leftPadding: 10; rightPadding: 10; font.pixelSize: 10; text: root.sendingComment ? "Sending…" : "Send"; iconName: "send"; highlighted: true; enabled: root.commentAction.enabled && !root.sendingComment && root.draft(root.taskId).trim().length > 0; Accessible.name: "Send task comment"; onClicked: root.sendComment() }
                }
            }
        }
    }

    MokaidMenu {
        id: statusMenu
        objectName: "taskStatusMenu"
        Instantiator {
            model: root.statuses
            delegate: MokaidMenu.Entry {
                required property var modelData
                objectName: "taskStatus_" + modelData.id
                text: modelData.label
                checkable: true; checked: root.currentRecord.status === modelData.id
                enabled: features.canMoveTasks && !root.statusPending
                onTriggered: { if (root.currentRecord.status !== modelData.id) features.moveTask(root.taskId, modelData.id) }
            }
            onObjectAdded: function(index, object) { statusMenu.insertItem(index, object) }
            onObjectRemoved: function(index, object) { statusMenu.removeItem(object) }
        }
    }
    MokaidMenu {
        id: selectionMenu
        objectName: "selectionActionsMenu"
        Instantiator {
            model: root.selectionActions.filter(function(candidate) { return candidate.id !== "feedback" && candidate.id !== "respond" && candidate.id !== "runtime-budget" })
            delegate: MokaidMenu.Entry {
                required property var modelData
                objectName: "selectionAction_" + modelData.id
                text: modelData.id === "run" ? "Start agent" : modelData.title
                enabled: modelData.enabled; destructive: Boolean(modelData.destructive)
                onTriggered: root.request(modelData)
            }
            onObjectAdded: function(index, object) { selectionMenu.insertItem(index, object) }
            onObjectRemoved: function(index, object) { selectionMenu.removeItem(object) }
        }
    }
}
