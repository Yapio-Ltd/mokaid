import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    required property var controller
    required property var voiceController
    property Item officeSlot: null
    property bool signedIn: false
    property bool reducedMotion: false
    property bool animated: true
    property bool expanded: false
    property bool fullscreen: false
    property bool voiceEnabled: false
    property bool voiceSession: false
    property bool pinnedToEnd: true
    property bool scrollLock: false
    property int currentTab: 0
    property int unread: 0
    property string announcement: ""
    property var previousFocus: null
    readonly property string voiceState: voiceController.state
    readonly property bool recording: voiceState === "listening"
    readonly property bool processingAudio: voiceState === "transcribing"
    readonly property bool audioActive: recording || processingAudio
    readonly property string mascotMode: recording ? "listening" : controller.busy || processingAudio ? "thinking" : activeMissions > 0 ? "working" : "idle"
    readonly property int activeMissions: controller.missions.filter(function(m) { return ["completed", "failed", "canceled", "cancelled"].indexOf(m.status) < 0 }).length
    readonly property point slotOrigin: {
        if (!officeSlot || !officeSlot.visible || officeSlot.width < 100 || officeSlot.height < 100)
            return Qt.point(-1, -1)
        officeSlot.x; officeSlot.y; officeSlot.width; officeSlot.height; width; height
        return mapFromItem(officeSlot, 0, 0)
    }
    readonly property bool useOfficeSlot: slotOrigin.x >= 0 && slotOrigin.y >= 48
    readonly property real mascotExtent: 122
    readonly property real mascotWidth: 116
    readonly property bool assigning: ["matching", "chosen", "launching", "assigned", "review", "unmatched"].indexOf(controller.assignmentPhase || "") >= 0
    property int assignmentScan: 0
    readonly property string status: !signedIn ? qsTr("Your copilot, right beside you") : recording ? qsTr("Listening…") : voiceState === "transcribing" ? qsTr("Transcribing your message…") : controller.busy ? qsTr("Thinking about your request…") : !controller.ready ? qsTr("Offline · draft kept") : activeMissions > 0 ? qsTr("%1 mission(s) in progress").arg(activeMissions) : qsTr("Ready to help")
    signal missionPrepared()

    function show() {
        if (!expanded) previousFocus = root.Window.window ? root.Window.window.activeFocusItem : null
        expanded = true
        unread = 0
        controller.refresh()
        Qt.callLater(function() { composer.forceActiveFocus() })
    }
    function hide() {
        expanded = false
        fullscreen = false
        voiceSession = false
        voiceController.cancel()
        if (previousFocus && previousFocus.forceActiveFocus) previousFocus.forceActiveFocus()
        else launcher.forceActiveFocus()
    }
    function send() {
        if (!controller.ready || controller.busy || !controller.draft.trim().length) return
        voiceController.cancel()
        currentTab = 0
        pinnedToEnd = true
        controller.sendMessage(controller.draft, controller.language)
    }
    function stickToLatest() {
        if (!pinnedToEnd) return
        scrollLock = true
        messages.positionViewAtEnd()
        Qt.callLater(function() { scrollLock = false })
    }
    function richBody(value) {
        let source = String(value || "")
        source = source.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        source = source.replace(/\*\*([^*\n]+)\*\*/g, "<b>$1</b>")
        source = source.replace(/\*([^*\n]+)\*/g, "<b>$1</b>")
        return source.replace(/\n/g, "<br>")
    }
    function startConversation() {
        voiceSession = false
        voiceController.cancel()
        currentTab = 0
        pinnedToEnd = true
        controller.newConversation()
        Qt.callLater(function() { composer.forceActiveFocus() })
    }
    function openThread(id) {
        pinnedToEnd = true
        currentTab = 0
        controller.openConversation(id)
        Qt.callLater(stickToLatest)
    }
    function microphone() {
        show()
        currentTab = 0
        if (recording) { voiceController.stopListening(); return }
        if (processingAudio) { voiceSession = false; voiceController.cancel(); return }
        if (!voiceController.ready) { voiceSettings.open(); return }
        voiceSession = true
        voiceController.startListening()
    }
    function portraitSource(agent) {
        const path = String((agent && agent.avatar_cdn_path) || "").trim()
        const match = /avatar_(male|design|finance|corporate|developer|research|legal|byte|nyx|moss)/.exec(path)
        return match ? "qrc:/ui/portrait-" + match[1] + ".png" : ""
    }
    function agentInitials(agent) {
        const words = String((agent && (agent.display_name || agent.name)) || "?").trim().split(/\s+/)
        const first = words[0] ? words[0].charAt(0) : "?"
        return (first + (words.length > 1 ? words[words.length - 1].charAt(0) : "")).toUpperCase()
    }
    function assignmentCopy(english, french, hebrew) {
        const lang = String(controller.language || "en").toLowerCase().slice(0, 2)
        if (lang === "fr") return french
        if (lang === "he") return hebrew
        return english
    }
    function assignmentTitle() {
        const phase = controller.assignmentPhase
        if (phase === "matching") return assignmentCopy("Finding the right agent…", "Recherche de l’agent…", "מחפש את הסוכן המתאים…")
        if (phase === "launching") return assignmentCopy("Assigning the mission…", "Assignation en cours…", "מעביר את המשימה…")
        if (phase === "assigned") return assignmentCopy("Mission assigned", "Mission assignée", "המשימה הוקצתה")
        if (phase === "review") return assignmentCopy("Choose the agent", "Choisissez l’agent", "בחרו סוכן")
        if (phase === "unmatched") return assignmentCopy("No agent on the team fits this mission", "Aucun agent de l’équipe n’est assez pertinent", "אין סוכן מתאים לצוות")
        return assignmentCopy("Agent selected", "Agent retenu", "הסוכן שנבחר")
    }
    function selectedAgentLabel() {
        const id = controller.assignmentAgentId
        const agents = controller.assignmentAgents || []
        for (let i = 0; i < agents.length; ++i) {
            if (agents[i].id === id) {
                const role = agents[i].role_title ? " · " + agents[i].role_title : ""
                return (agents[i].display_name || agents[i].name || "") + role
            }
        }
        return ""
    }
    function missionStatus(value) {
        const names = { to_do: qsTr("To do"), pending: qsTr("Waiting"), queued: qsTr("Waiting"), waiting: qsTr("Waiting"), in_progress: qsTr("In progress"), running: qsTr("In progress"), assigned: qsTr("Assigned"), completed: qsTr("Completed"), failed: qsTr("Needs review"), canceled: qsTr("Canceled"), cancelled: qsTr("Canceled"), waiting_input: qsTr("Waiting for your reply"), awaiting_input: qsTr("Waiting for your reply"), review: qsTr("In review"), in_review: qsTr("To approve"), overdue: qsTr("Overdue"), blocked: qsTr("Blocked") }
        return names[value] || qsTr("Status unavailable")
    }
    function resetView() { hide(); unread = 0; announcement = ""; voiceEnabled = false }
    onSignedInChanged: if (!signedIn) resetView()
    Timer {
        interval: 150; repeat: true
        running: root.assigning && root.controller.assignmentPhase === "matching" && !root.reducedMotion && root.expanded
        onTriggered: {
            const count = Math.max(1, (root.controller.assignmentAgents || []).length || 4)
            root.assignmentScan = (root.assignmentScan + 1) % count
        }
    }
    Connections {
        target: root.controller
        function onAssistantReplied(text) {
            if (!root.expanded) { root.unread += 1; root.announcement = text }
            Qt.callLater(root.stickToLatest)
        }
    }
    Connections {
        target: root.voiceController
        function onTranscribed(text, language) {
            if (!root.voiceSession) return
            root.voiceSession = false
            root.controller.language = language
            root.controller.draft = root.controller.draft.trim().length ? root.controller.draft + "\n" + text : text
            composer.forceActiveFocus()
        }
    }

    Rectangle {
        id: panel
        objectName: "mokedPanel"
        anchors.right: parent.right; anchors.bottom: parent.bottom
        anchors.rightMargin: 24; anchors.bottomMargin: 90
        width: Math.min(448, root.width - 32)
        height: Math.min(658, root.height - 120)
        radius: root.fullscreen ? 0 : 20; color: Theme.surface; border.color: Theme.selectedBorder
        visible: opacity > 0
        opacity: root.expanded ? 1 : 0
        enabled: root.expanded
        states: State {
            name: "fullscreen"
            when: root.fullscreen
            AnchorChanges { target: panel; anchors.left: root.left; anchors.top: root.top; anchors.right: root.right; anchors.bottom: root.bottom }
            PropertyChanges { target: panel; anchors.leftMargin: 0; anchors.rightMargin: 0; anchors.topMargin: 0; anchors.bottomMargin: 0; radius: 0 }
        }
        transform: Translate { y: root.expanded ? 0 : 12; Behavior on y { NumberAnimation { duration: root.reducedMotion ? 0 : 230; easing.type: Easing.OutCubic } } }
        Behavior on opacity { NumberAnimation { duration: root.reducedMotion ? 0 : 160 } }
        Keys.onEscapePressed: function(event) { root.hide(); event.accepted = true }
        // Consume clicks on the floating surface without blocking the workspace outside it.
        MouseArea { anchors.fill: parent; onPressed: function(mouse) { mouse.accepted = true } }
        RowLayout {
            anchors.fill: parent; spacing: 0
            Rectangle {
                visible: root.fullscreen
                Layout.preferredWidth: 280; Layout.fillHeight: true
                color: "#0c0e18"
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 16; spacing: 12
                    MokaidLabel { text: qsTr("Conversations"); font.pixelSize: 13; font.weight: Font.DemiBold; color: Theme.secondary }
                    MokaidButton {
                        objectName: "mokedNewChatSidebar"
                        Layout.fillWidth: true; text: qsTr("New chat"); iconName: "plus"; highlighted: true
                        enabled: root.signedIn
                        onClicked: root.startConversation()
                    }
                    Item {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        ListView {
                            id: historyList
                            anchors.fill: parent
                            clip: true; spacing: 4; boundsBehavior: Flickable.StopAtBounds
                            model: root.controller.conversations || []
                            delegate: AbstractButton {
                                required property var modelData
                                width: historyList.width; implicitHeight: 42; hoverEnabled: true
                                Accessible.name: modelData.title || qsTr("New chat")
                                onClicked: root.openThread(modelData.id)
                                background: Rectangle {
                                    radius: 10
                                    color: modelData.id === root.controller.activeConversationId ? Theme.selected : parent.hovered ? Theme.hover : "transparent"
                                }
                                contentItem: MokaidLabel {
                                    text: modelData.title || qsTr("New chat")
                                    elide: Text.ElideRight; font.pixelSize: 13; font.weight: Font.DemiBold
                                    leftPadding: 12; rightPadding: 12; verticalAlignment: Text.AlignVCenter
                                }
                            }
                        }
                        MokaidLabel {
                            visible: historyList.count === 0
                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                            wrapMode: Text.Wrap; color: Theme.muted; font.pixelSize: 12
                            text: qsTr("Past conversations stay here, each with its own context.")
                        }
                    }
                }
            }
            Rectangle { visible: root.fullscreen; Layout.preferredWidth: 1; Layout.fillHeight: true; color: Theme.divider }
            ColumnLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.margins: 18; spacing: 12
            RowLayout {
                Layout.fillWidth: true; spacing: 12
                Rectangle {
                    Layout.preferredWidth: 44; Layout.preferredHeight: 44; radius: 14
                    color: Theme.selected
                    MokaidIcon { anchors.centerIn: parent; name: "moked"; size: 27; color: "#d9c9ff" }
                }
                ColumnLayout {
                    spacing: 3; Layout.fillWidth: true
                    MokaidLabel { text: "Moked"; font.pixelSize: 21; font.weight: Font.Bold }
                    MokaidLabel { Layout.fillWidth: true; text: root.status; font.pixelSize: 11; color: root.recording ? Theme.success : Theme.secondary; elide: Text.ElideRight; Accessible.role: Accessible.StatusBar }
                }
                MokaidIconButton { objectName: "mokedNewChat"; iconName: "plus"; hint: qsTr("New conversation"); subtle: true; implicitWidth: 34; enabled: root.signedIn; onClicked: root.startConversation() }
                MokaidIconButton { objectName: "mokedFullscreen"; iconName: "fit"; hint: root.fullscreen ? qsTr("Exit full screen") : qsTr("Full screen"); subtle: true; implicitWidth: 34; onClicked: root.fullscreen = !root.fullscreen }
                MokaidIconButton { objectName: "mokedClose"; iconName: "minus"; hint: qsTr("Collapse Moked"); subtle: true; implicitWidth: 34; onClicked: root.hide() }
            }
            RowLayout {
                spacing: 6; Layout.fillWidth: true
                Repeater {
                    model: [qsTr("Conversation"), qsTr("Missions") + (root.activeMissions ? " · " + root.activeMissions : "")]
                    AbstractButton {
                        required property int index
                        required property string modelData
                        objectName: index === 0 ? "mokedChatTab" : "mokedMissionsTab"
                        Layout.fillWidth: true; implicitHeight: 36; hoverEnabled: true
                        Accessible.name: modelData; Accessible.role: Accessible.PageTab; Accessible.description: root.currentTab === index ? qsTr("Active tab") : ""
                        onClicked: { root.currentTab = index; if (index === 1) root.controller.refresh() }
                        background: Rectangle { radius: 9; color: root.currentTab === index ? Theme.selected : parent.hovered ? Theme.hover : "transparent"; border.color: parent.visualFocus ? Theme.focusBorder : "transparent" }
                        contentItem: MokaidLabel { text: parent.modelData; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; color: root.currentTab === parent.index ? Theme.text : Theme.secondary; font.weight: Font.DemiBold; font.pixelSize: 12 }
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.divider }
            StackLayout {
                Layout.fillWidth: true; Layout.fillHeight: true; currentIndex: root.currentTab
                Item {
                    ColumnLayout {
                        anchors.fill: parent; spacing: 10
                        Item {
                            Layout.fillWidth: true; Layout.fillHeight: true
                            ColumnLayout {
                                visible: root.controller.messages.length === 0 && !root.recording && !root.processingAudio
                                anchors.centerIn: parent; width: parent.width - 12; spacing: 14
                                MokedMascot { Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: panel.height < 600 ? 88 : 116; Layout.preferredHeight: panel.height < 600 ? 90 : 118; mode: root.mascotMode; reducedMotion: root.reducedMotion; animated: root.animated && root.expanded }
                                MokaidLabel { Layout.fillWidth: true; text: qsTr("One idea. One team.\nWe'll take it from here."); font.pixelSize: 23; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
                                MokaidLabel { Layout.fillWidth: true; text: root.signedIn ? qsTr("Describe your goal. I help you prepare missions and follow your agents' deliverables.") : qsTr("Sign in to your workspace to chat and assign a mission to your agents."); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; color: Theme.secondary; font.pixelSize: 12 }
                            }
                            ListView {
                                id: messages; objectName: "mokedMessages"
                                anchors.fill: parent; model: root.controller.messages; spacing: 18; clip: true
                                visible: count > 0
                                boundsBehavior: Flickable.StopAtBounds
                                onCountChanged: Qt.callLater(root.stickToLatest)
                                onHeightChanged: Qt.callLater(root.stickToLatest)
                                onContentHeightChanged: Qt.callLater(root.stickToLatest)
                                onContentYChanged: {
                                    if (root.scrollLock) return
                                    root.pinnedToEnd = contentHeight - contentY - height < 48
                                }
                                delegate: ColumnLayout {
                                    required property var modelData
                                    width: messages.width - 8; spacing: 6
                                    readonly property bool member: modelData.role === "user"
                                    MokaidLabel { text: parent.member ? qsTr("You") : "Moked"; color: parent.member ? Theme.secondary : Theme.primary; font.weight: Font.DemiBold; font.pixelSize: 11; Layout.alignment: parent.member ? Qt.AlignRight : Qt.AlignLeft }
                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.leftMargin: parent.member ? 26 : 0
                                        implicitHeight: messageText.implicitHeight + (parent.member ? 22 : 6)
                                        radius: 12; color: parent.member ? Theme.selected : "transparent"
                                        TextEdit {
                                            id: messageText; anchors.fill: parent; anchors.margins: parent.parent.member ? 11 : 3
                                            text: root.richBody(modelData.body || ""); textFormat: TextEdit.RichText; color: Theme.text
                                            readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap
                                            font.family: Theme.fontFamily; font.pixelSize: 13
                                            selectionColor: Theme.selection; selectedTextColor: Theme.text
                                            Accessible.name: (parent.parent.member ? qsTr("You: ") : "Moked : ") + (modelData.body || "")
                                        }
                                    }
                                    MokaidButton { visible: !!modelData.task_id; text: qsTr("Open mission"); iconName: "arrow-right"; onClicked: { root.controller.reviewMission(modelData.task_id); root.hide() } }
                                }
                                ScrollBar.vertical: ScrollBar { }
                            }
                        }
                        MokaidLabel { visible: root.controller.busy; Layout.fillWidth: true; text: qsTr("Moked is preparing a reply…"); color: Theme.primary; font.pixelSize: 12; Accessible.role: Accessible.StatusBar }
                        Rectangle {
                            id: assignmentCard
                            objectName: "mokedAssignment"
                            Layout.fillWidth: true
                            implicitHeight: opacity > 0 ? assignmentBody.implicitHeight + 28 : 0
                            radius: 16; color: "#161226"; border.color: Theme.selectedBorder
                            opacity: root.assigning && !root.recording ? 1 : 0
                            visible: opacity > 0
                            Behavior on opacity { NumberAnimation { duration: root.reducedMotion ? 0 : 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] } }
                            ColumnLayout {
                                id: assignmentBody; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 14; spacing: 10
                                MokaidLabel {
                                    Layout.fillWidth: true; font.weight: Font.DemiBold; font.pixelSize: 12; color: Theme.primary
                                    text: root.assignmentTitle()
                                }
                                Row {
                                    id: headRow; Layout.fillWidth: true; spacing: 10
                                    property var heads: !root.assigning ? [] : ((root.controller.assignmentAgents || []).length > 0 ? root.controller.assignmentAgents : [{}, {}, {}, {}])
                                    Repeater {
                                        model: headRow.heads
                                        Item {
                                            id: head
                                            required property var modelData
                                            required property int index
                                            width: 48; height: 48
                                            readonly property bool ghost: !modelData || !modelData.id
                                            readonly property bool chosen: !ghost && modelData.id === root.controller.assignmentAgentId
                                            readonly property bool spotlight: root.controller.assignmentPhase === "unmatched" ? false
                                                : root.controller.assignmentPhase === "matching"
                                                ? (!root.reducedMotion && index === root.assignmentScan)
                                                : (chosen || (!root.controller.assignmentAgentId && modelData.recommended === true))
                                            opacity: ghost ? 0.4 : (root.controller.assignmentPhase === "matching" || spotlight ? 1 : 0.38)
                                            transform: Scale {
                                                origin.x: 24; origin.y: 24
                                                xScale: head.spotlight ? 1.08 : 0.96
                                                yScale: head.spotlight ? 1.08 : 0.96
                                                Behavior on xScale { NumberAnimation { duration: root.reducedMotion ? 0 : 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] } }
                                                Behavior on yScale { NumberAnimation { duration: root.reducedMotion ? 0 : 200; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] } }
                                            }
                                            Behavior on opacity {
                                                SequentialAnimation {
                                                    PauseAnimation { duration: root.reducedMotion ? 0 : Math.min(head.index * 28, 140) }
                                                    NumberAnimation { duration: root.reducedMotion ? 0 : 180; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }
                                                }
                                            }
                                            Rectangle {
                                                anchors.centerIn: parent; width: 52; height: 52; radius: 26; color: "transparent"
                                                border.color: Theme.primary; border.width: 1
                                                opacity: head.spotlight ? 0.95 : 0
                                                Behavior on opacity { NumberAnimation { duration: root.reducedMotion ? 0 : 180; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] } }
                                            }
                                            Rectangle {
                                                id: face; anchors.fill: parent; radius: width / 2; clip: true; color: "#241c38"
                                                border.width: head.spotlight ? 2 : 1
                                                border.color: head.spotlight ? Theme.focusBorder : "#4a3c70"
                                                Image {
                                                    id: faceImage; anchors.fill: parent; anchors.margins: 2
                                                    source: root.portraitSource(head.modelData)
                                                    fillMode: Image.PreserveAspectCrop; asynchronous: true
                                                    visible: status === Image.Ready
                                                }
                                                MokaidLabel {
                                                    anchors.centerIn: parent
                                                    visible: !head.ghost && faceImage.status !== Image.Ready
                                                    text: root.agentInitials(head.modelData)
                                                    font.pixelSize: 13; font.weight: Font.DemiBold; color: "#d8c9ff"
                                                }
                                            }
                                        }
                                    }
                                }
                                MokaidLabel {
                                    Layout.fillWidth: true; visible: text.length > 0
                                    text: root.selectedAgentLabel(); color: Theme.text; font.pixelSize: 12; elide: Text.ElideRight
                                }
                                MokaidButton {
                                    objectName: "mokedConfirmAssignment"
                                    visible: root.controller.assignmentPhase === "review"
                                    text: root.assignmentCopy("Assign", "Assigner", "הקצה"); iconName: "arrow-right"; highlighted: true; Layout.fillWidth: true
                                    enabled: root.controller.ready && !root.controller.busy
                                    onClicked: root.controller.confirmAssignment()
                                }
                                MokaidButton {
                                    visible: root.controller.assignmentPhase === "assigned" && !!root.controller.assignmentTaskId
                                    text: root.assignmentCopy("Open mission", "Open mission", "פתיחת המשימה"); iconName: "arrow-right"; Layout.fillWidth: true
                                    onClicked: { root.controller.reviewMission(root.controller.assignmentTaskId); root.hide() }
                                }
                            }
                        }
                        Rectangle {
                            visible: !!root.controller.pendingInstruction && !root.recording && !root.assigning
                            Layout.fillWidth: true; implicitHeight: proposal.implicitHeight + 24; radius: 12; color: Theme.selected
                            ColumnLayout {
                                id: proposal; anchors.fill: parent; anchors.margins: 12; spacing: 8
                                MokaidLabel { text: qsTr("Ready to assign to an agent"); font.weight: Font.DemiBold; font.pixelSize: 12; Layout.fillWidth: true }
                                MokaidLabel { text: root.controller.pendingInstruction; color: Theme.secondary; font.pixelSize: 12; maximumLineCount: 2; elide: Text.ElideRight; wrapMode: Text.Wrap; Layout.fillWidth: true }
                                MokaidButton { objectName: "mokedPrepareMission"; text: qsTr("Prepare mission"); iconName: "arrow-right"; highlighted: true; Layout.fillWidth: true; enabled: root.controller.ready && !root.controller.busy; onClicked: { root.controller.prepareMission(); root.hide(); root.missionPrepared() } }
                            }
                        }
                    }
                }
                Item {
                    ListView {
                        id: missionList; anchors.fill: parent; model: root.controller.missions; spacing: 10; clip: true; boundsBehavior: Flickable.StopAtBounds
                        delegate: Rectangle {
                            required property var modelData
                            width: missionList.width - 8; implicitHeight: missionBody.implicitHeight + 26; radius: 12; color: Theme.control; border.color: Theme.divider
                            ColumnLayout {
                                id: missionBody; anchors.fill: parent; anchors.margins: 13; spacing: 9
                                RowLayout {
                                    Layout.fillWidth: true
                                    Rectangle { width: 6; height: 6; radius: 3; color: modelData.status === "completed" ? Theme.success : modelData.status === "failed" || modelData.status === "blocked" ? Theme.warning : Theme.primary }
                                    MokaidLabel { text: root.missionStatus(modelData.status); font.pixelSize: 11; color: Theme.secondary; Layout.fillWidth: true }
                                    MokaidLabel { text: typeof modelData.progress_percent === "number" ? Math.round(modelData.progress_percent) + "%" : ""; color: Theme.muted; font.pixelSize: 11 }
                                }
                                MokaidLabel { Layout.fillWidth: true; text: modelData.title || qsTr("Mission"); font.weight: Font.DemiBold; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight }
                                MokaidLabel { Layout.fillWidth: true; visible: text.length > 0; text: modelData.assigned_agent_name || ""; color: Theme.secondary; font.pixelSize: 12; elide: Text.ElideRight }
                                RowLayout {
                                    Layout.fillWidth: true
                                    MokaidButton { text: (modelData.artifacts || []).length > 0 ? qsTr("View deliverable") : qsTr("View mission"); iconName: "arrow-right"; Layout.fillWidth: true; onClicked: { root.controller.reviewMission(modelData.id); root.hide() } }
                                    MokaidIconButton { visible: ["running", "in_progress"].indexOf(modelData.status) >= 0; iconName: "stop"; hint: qsTr("Stop mission"); enabled: root.controller.ready; onClicked: { stopMission.taskId = modelData.id; stopMission.open() } }
                                }
                            }
                        }
                        ScrollBar.vertical: ScrollBar { }
                    }
                    ColumnLayout {
                        visible: missionList.count === 0; anchors.centerIn: parent; width: parent.width - 32; spacing: 14
                        MokaidIcon { Layout.alignment: Qt.AlignHCenter; name: "tasks"; size: 36; color: Theme.primary }
                        MokaidLabel { text: root.controller.refreshing ? qsTr("Loading missions…") : qsTr("Your missions, in one place"); font.pixelSize: 20; font.weight: Font.DemiBold; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
                        MokaidLabel { text: qsTr("Missions in your workspace, their progress, and deliverables will show up here."); color: Theme.secondary; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
                        MokaidButton { text: qsTr("Let's talk about your goal"); Layout.alignment: Qt.AlignHCenter; onClicked: { root.currentTab = 0; composer.forceActiveFocus() } }
                    }
                }
            }
            MokaidLabel { objectName: "mokedError"; visible: text.length > 0; text: root.controller.error || root.voiceController.error; Layout.fillWidth: true; color: Theme.warning; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight; font.pixelSize: 12; Accessible.role: Accessible.AlertMessage }
            ColumnLayout {
                visible: root.currentTab === 0; Layout.fillWidth: true; spacing: 8
                Rectangle {
                    visible: root.recording || root.processingAudio
                    Layout.fillWidth: true; radius: 14
                    implicitHeight: listenRow.implicitHeight + 16
                    color: "#161226"; border.color: Theme.selectedBorder
                    RowLayout {
                        id: listenRow
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 8
                        spacing: 10
                        MokedMascot {
                            Layout.preferredWidth: 52; Layout.preferredHeight: 54
                            mode: root.recording ? "listening" : "thinking"
                            reducedMotion: root.reducedMotion; animated: root.animated && root.expanded
                            audioLevel: root.voiceController.level || 0
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 4
                            MokaidLabel { text: root.recording ? qsTr("Listening…") : qsTr("Transcribing your message…"); font.weight: Font.DemiBold; font.pixelSize: 13; color: Theme.success }
                            Row {
                                id: wave; visible: root.recording; spacing: 4; height: 16
                                property real phase: 0
                                NumberAnimation on phase { from: 0; to: Math.PI * 2; duration: 900; loops: Animation.Infinite; running: wave.visible && root.expanded && !root.reducedMotion }
                                Repeater {
                                    model: 5
                                    Rectangle {
                                        required property int index
                                        width: 3; radius: 1.5; color: Theme.primary
                                        height: 4 + 12 * (0.5 + 0.5 * Math.sin(wave.phase + index * 0.8))
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }
                            }
                            MokaidLabel { visible: root.processingAudio; text: qsTr("You can review the text before sending."); color: Theme.secondary; font.pixelSize: 11; wrapMode: Text.Wrap; Layout.fillWidth: true }
                        }
                        MokaidButton {
                            visible: root.recording
                            text: qsTr("Finish and transcribe"); iconName: "stop"
                            onClicked: root.voiceController.stopListening()
                        }
                    }
                }
                ScrollView {
                    Layout.fillWidth: true; Layout.preferredHeight: 88
                    MokaidTextArea {
                        id: composer; objectName: "mokedComposer"
                        text: root.controller.draft; placeholderText: root.signedIn ? qsTr("What do you want to accomplish?") : qsTr("Sign in to chat…")
                        enabled: root.signedIn && !root.recording && !root.processingAudio
                        wrapMode: TextEdit.Wrap; Accessible.name: qsTr("Message to Moked")
                        onTextChanged: if (root.controller.draft !== text) root.controller.draft = text
                        Keys.onPressed: function(event) {
                            if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) { root.send(); event.accepted = true }
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    MokaidIconButton { objectName: "mokedMicrophone"; iconName: root.recording ? "stop" : "microphone"; hint: root.recording ? qsTr("Finish dictation") : qsTr("Dictate a message"); enabled: root.signedIn && !root.controller.busy; onClicked: root.microphone() }
                    MokaidLabel { Layout.fillWidth: true; text: root.recording ? qsTr("Speak naturally. Review before sending.") : qsTr("Enter to send"); font.pixelSize: 10; color: Theme.muted; wrapMode: Text.Wrap }
                    MokaidButton { objectName: "mokedSend"; text: qsTr("Send"); iconName: "send"; highlighted: true; enabled: root.controller.ready && !root.controller.busy && !root.recording && !root.processingAudio && root.controller.draft.trim().length > 0; onClicked: root.send() }
                }
            }
            }
        }
    }

    Item {
        id: companion
        visible: !root.fullscreen
        anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.rightMargin: 24; anchors.bottomMargin: 18
        width: root.useOfficeSlot ? root.mascotWidth : 194
        height: root.useOfficeSlot ? root.mascotExtent : (root.expanded ? 54 : 192)
        states: State {
            name: "underAttention"
            when: root.useOfficeSlot
            AnchorChanges {
                target: companion
                anchors.right: undefined
                anchors.bottom: undefined
            }
            PropertyChanges {
                target: companion
                x: root.slotOrigin.x + (root.officeSlot.width - root.mascotWidth) / 2
                y: root.slotOrigin.y + (root.officeSlot.height - root.mascotExtent) / 2
            }
        }
        MokedMascot {
            id: mascot
            anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.rightMargin: 13; anchors.bottomMargin: 42
            width: root.mascotWidth; height: root.mascotExtent; visible: root.useOfficeSlot || !root.expanded
            mode: root.mascotMode; reducedMotion: root.reducedMotion; animated: root.animated
            states: State {
                when: root.useOfficeSlot
                AnchorChanges {
                    target: mascot
                    anchors.left: mascot.parent.left
                    anchors.right: mascot.parent.right
                    anchors.top: mascot.parent.top
                    anchors.bottom: mascot.parent.bottom
                }
                PropertyChanges {
                    target: mascot
                    anchors.leftMargin: 0
                    anchors.rightMargin: 0
                    anchors.topMargin: 0
                    anchors.bottomMargin: 0
                }
            }
            MouseArea {
                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                onClicked: root.useOfficeSlot && root.expanded ? root.hide() : root.show()
                Accessible.ignored: !root.useOfficeSlot
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("Open Moked, your orchestrator")
            }
        }
        Rectangle {
            visible: root.unread > 0 && !root.expanded && !root.useOfficeSlot
            anchors.right: parent.left; anchors.bottom: parent.bottom; anchors.bottomMargin: 68
            width: Math.min(230, Math.max(130, root.width - 240)); height: updateText.implicitHeight + 28; radius: 14; color: Theme.surface; border.color: Theme.selectedBorder
            MokaidLabel { id: updateText; anchors.fill: parent; anchors.margins: 14; text: root.announcement; maximumLineCount: 3; elide: Text.ElideRight; wrapMode: Text.Wrap; font.pixelSize: 12 }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.show() }
        }
        RowLayout {
            visible: !root.useOfficeSlot
            anchors.right: parent.right; anchors.bottom: parent.bottom; spacing: 8
            MokaidIconButton { iconName: root.recording ? "stop" : "microphone"; hint: qsTr("Talk to Moked"); enabled: root.signedIn && !root.controller.busy; onClicked: root.microphone() }
            AbstractButton {
                id: launcher; objectName: "mokedLauncher"
                implicitWidth: 130; implicitHeight: 46; hoverEnabled: true
                Accessible.name: root.expanded ? qsTr("Collapse Moked") : qsTr("Open Moked, your orchestrator")
                onClicked: root.expanded ? root.hide() : root.show()
                background: Rectangle { radius: 15; color: launcher.hovered ? "#302448" : "#1f1932"; border.color: launcher.visualFocus ? Theme.focusBorder : "#68528f" }
                contentItem: RowLayout {
                    spacing: 8
                    MokaidIcon { name: "moked"; size: 19; color: Theme.primary; Layout.leftMargin: 14 }
                    MokaidLabel { text: "Moked"; font.weight: Font.DemiBold; Layout.fillWidth: true }
                    MokaidIcon { name: root.expanded ? "chevron-down" : "chevron-up"; size: 14; Layout.rightMargin: 12 }
                }
            }
        }
    }
    MokaidDialog {
        id: voiceSettings; objectName: "mokedVoiceSettings"
        anchors.centerIn: parent; modal: true; width: Math.min(460, root.width - 40); title: qsTr("Moked's voice"); standardButtons: Dialog.Close
        ColumnLayout {
            width: parent.width; spacing: 16
            MokaidLabel { Layout.fillWidth: true; text: qsTr("Speak in your language."); font.pixelSize: 23; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
            MokaidLabel { Layout.fillWidth: true; text: qsTr("Speech recognition runs on this computer. The text is sent to your Mokaid workspace when you press Send."); color: Theme.secondary; wrapMode: Text.Wrap }
            MokaidLabel { Layout.fillWidth: true; text: root.voiceController.ready ? qsTr("Whisper multilingual and Kokoro are ready.") : root.voiceState === "preparing" ? qsTr("Checking the models included with the app…") : qsTr("The voice pack is missing or incomplete. Use a Mokaid build that includes the voice models."); wrapMode: Text.Wrap; color: root.voiceController.ready ? Theme.success : Theme.secondary }
            ProgressBar { Layout.fillWidth: true; visible: root.voiceState === "preparing"; indeterminate: true }
            MokaidButton { Layout.fillWidth: true; visible: !root.voiceController.ready; text: qsTr("Check local models"); highlighted: true; enabled: root.voiceState !== "preparing"; onClicked: root.voiceController.setup() }
            MokaidLabel { Layout.fillWidth: true; text: qsTr("Kokoro speaks supported languages. For others, Moked uses an installed system voice if one exists. Otherwise the reply stays written."); color: Theme.muted; wrapMode: Text.Wrap; font.pixelSize: 12 }
            MokaidLabel { Layout.fillWidth: true; text: root.voiceController.error; visible: text.length > 0; color: Theme.warning; wrapMode: Text.Wrap }
        }
    }
    MokaidDialog {
        id: stopMission; property string taskId: ""
        anchors.centerIn: parent; title: qsTr("Stop this mission?"); modal: true; width: 390; standardButtons: Dialog.Ok | Dialog.Cancel
        MokaidLabel { width: parent.width; text: qsTr("The agent's run will be interrupted. Deliverables already saved will stay available."); wrapMode: Text.Wrap }
        onAccepted: root.controller.cancelMission(taskId)
    }
}
