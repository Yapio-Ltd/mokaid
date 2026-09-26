import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Mokaid.Native 1.0

Item {
    id: root
    property bool active: true
    readonly property bool hasDrafts: agentDetail.hasDrafts
    signal actionRequested(var action)
    property string detailAgentRequested: ""
    function syncAgentDetail() {
        if (!office.selectedAgent.id) { detailAgentRequested = ""; return }
        if (root.active && features.currentPage === "office" && detailAgentRequested !== office.selectedAgent.id) {
            detailAgentRequested = office.selectedAgent.id
            features.select(office.selectedAgent.id)
        }
    }
    Connections { target: office; function onChanged() { root.syncAgentDetail() } }
    Connections { target: features; function onChanged() { root.syncAgentDetail() } }
    readonly property bool immersive: viewport.immersive
    property string overviewAgentId: ""
    property bool returningFromTour: false
    property string approachingAgentId: ""
    property string approachingStopId: ""
    property bool startingApproach: false
    property bool facingConversation: false
    function finishApproach() {
        if (!approachingAgentId || startingApproach) return
        if (viewport.tourDestination !== approachingStopId) {
            approachingAgentId = ""; approachingStopId = ""; return
        }
        if (viewport.tourMoving) return
        if (viewport.tourCurrentStop !== approachingStopId) {
            approachingAgentId = ""; approachingStopId = ""; return
        }
        if (!facingConversation) {
            facingConversation = true
            viewport.faceCurrentStop()
            if (!approachingAgentId) return
        }
        if (viewport.tourSettling) return
        const id = approachingAgentId
        approachingAgentId = ""; approachingStopId = ""
        if (root.immersive) office.selectAgent(id)
    }
    onImmersiveChanged: {
        if (!immersive) { approachingAgentId = ""; approachingStopId = "" }
        if (immersive) {
            overviewAgentId = office.selectedAgent.id || ""
            returningFromTour = true
        } else if (returningFromTour) {
            returningFromTour = false
            if (overviewAgentId && root.team.some(function(agent) { return agent.id === overviewAgentId })) {
                if (office.selectedAgent.id !== overviewAgentId) office.selectAgent(overviewAgentId)
            } else if (office.selectedAgent.id) office.closeChat()
        }
    }
    function selectAgent(id) {
        viewport.stopWalking()
        if (root.immersive) {
            const agent = root.team.find(function(member) { return member.id === id })
            if (agent && agent.seat_index >= 0 && agent.seat_index < 9) {
                const stop = "desk_" + agent.seat_index
                {
                    if (office.selectedAgent.id === id && viewport.tourCurrentStop === stop) return
                    if (office.selectedAgent.id) office.closeChat()
                    approachingAgentId = id; approachingStopId = stop; startingApproach = true; facingConversation = false
                    const started = viewport.travelTo(stop)
                    startingApproach = false
                    if (started) { finishApproach(); return }
                    approachingAgentId = ""; approachingStopId = ""
                }
            }
        }
        if (office.selectedAgent.id !== id) office.selectAgent(id)
    }
    onActiveChanged: {
        if (!active && immersive) viewport.leaveOffice()
        if (active) { detailAgentRequested = ""; root.syncAgentDetail() }
    }
    readonly property var diagnostics: viewport.diagnostics
    readonly property var team: office.agents.filter(function(agent) { return agent.status !== "archived" })
    readonly property int workingCount: team.filter(function(agent) { return !!agent.current_task_id && agent.screen_task && agent.screen_task.status === "in_progress" }).length
    readonly property int attentionCount: team.filter(function(agent) { return agent.status === "waiting" || agent.status === "blocked" }).length
    readonly property int chatMotion: system.reducedMotion ? 0 : 320
    Row {
        id: officeRow
        anchors.fill: parent
        spacing: 0
        Item {
            id: officeArea
            width: Math.max(0, officeRow.width - chatGap.width - chatDrawer.width)
            height: officeRow.height
            readonly property bool showStats: !root.immersive && width >= 1050 && height >= 620
            ColumnLayout {
                id: officeHeading
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                spacing: 9
                RowLayout {
                    Layout.fillWidth: true; spacing: 14
                    MokaidLabel {
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        elide: Text.ElideRight
                        text: root.immersive ? "Inside your office" : "Your office"
                        font.pixelSize: officeArea.width < 600 ? 29 : 34
                        font.weight: Font.Bold; font.letterSpacing: -.55
                    }
                    MokaidButton {
                        id: enterOffice
                        objectName: "officeEnter"
                        visible: !root.immersive
                        text: "Enter office"; iconName: "office"; highlighted: true
                        enabled: viewport.tourAvailable && !viewport.loading && !viewport.error.length
                        onClicked: viewport.enterOffice()
                        Accessible.description: "Explore at eye level along guided paths and talk to your agents."
                    }
                    MokaidButton {
                        objectName: "officeOverview"
                        visible: root.immersive
                        text: "Overview"; iconName: "grid"
                        onClicked: { viewport.leaveOffice(); enterOffice.forceActiveFocus() }
                        Accessible.description: "Return to the original office view. Escape also returns to overview."
                    }
                    MokaidButton {
                        objectName: "officeNewMission"
                        iconName: "plus"; text: officeArea.width < 600 ? "" : missions.hasDraft ? "Resume mission" : "New mission"
                        Accessible.name: missions.hasDraft ? "Resume mission" : "New mission"
                        visible: !root.immersive
                        highlighted: false; enabled: !!session.workspaceId
                        onClicked: missions.begin()
                    }
                }
                MokaidLabel {
                    Layout.fillWidth: true
                    text: root.immersive ? "Click a floor marker to walk there. Drag to look around. Click an agent to chat."
                        : "Your team, together. Enter the office to explore, or drop files to start a mission."
                    color: Theme.secondary; font.pixelSize: 13; wrapMode: Text.Wrap
                }
            }
            NativeViewport {
                id: viewport
                objectName: "officeViewport"
                anchors.left: parent.left; anchors.right: parent.right
                anchors.top: officeHeading.bottom; anchors.bottom: root.immersive ? parent.bottom : teamStrip.top
                anchors.topMargin: 16; anchors.bottomMargin: root.immersive ? 0 : 16
                anchors.rightMargin: officeArea.showStats ? 146 : 0
                assetRoot: system.assetRoot; agents: office.agents; quality: system.quality
                paused: !root.active
                reducedMotion: system.reducedMotion
                conversationAgentId: root.immersive ? (root.approachingAgentId || office.selectedAgent.id || "") : ""
                onAgentSelected: function(id) { root.selectAgent(id) }
                onTourStateChanged: root.finishApproach()
                onNavigationInterrupted: {
                    if (!root.startingApproach) {
                        root.approachingAgentId = ""; root.approachingStopId = ""
                        root.facingConversation = false
                    }
                }
                Accessible.role: Accessible.Pane
                Accessible.name: root.immersive ? "Inside the office. Drag to look, arrow keys to turn, Escape for overview. Choose a floor marker or a destination on the route map to walk."
                    : "Interactive office. Enter the office to explore at eye level, or select an agent to chat."
            }
            AgentIndicators {
                anchors.fill: viewport
                visible: !viewport.loading && viewport.error.length === 0
                model: viewport.actorIndicators
                agents: office.agents
                motionActive: root.active
                selectedAgentId: office.selectedAgent.id || ""
                reducedMotion: system.reducedMotion
                onAgentSelected: function(agentId) { root.selectAgent(agentId) }
            }
            OfficeNavigationAnchors {
                anchors.fill: viewport
                visible: root.immersive && !viewport.loading && !viewport.error.length
                sceneViewport: viewport
                agents: root.team
                onDestinationRequested: function(stopId) {
                    root.approachingAgentId = ""; root.approachingStopId = ""
                    if (office.selectedAgent.id) office.closeChat()
                    if (!viewport.immersive && !viewport.enterOffice()) return
                    viewport.travelTo(stopId)
                }
                reducedMotion: system.reducedMotion
            }
            OfficeTourControls {
                id: tourControls
                visible: root.immersive && !viewport.loading && !viewport.error.length
                anchors.left: viewport.left; anchors.bottom: viewport.bottom; anchors.margins: 12
                sceneViewport: viewport; agents: root.team
                mapExpanded: viewport.height >= 430 && !(office.selectedAgent.id && root.width < 850)
            }
            Rectangle {
                visible: root.immersive
                anchors.left: viewport.left; anchors.top: viewport.top; anchors.margins: 12
                width: lookControls.implicitWidth + 16; height: 48
                radius: Theme.radiusControl; color: "#ed111320"; border.color: Theme.border
                MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: function(wheel) { wheel.accepted = true } }
                RowLayout {
                    id: lookControls
                    anchors.centerIn: parent; spacing: 6
                    MokaidButton {
                        iconName: "chevron-left"; quiet: true; implicitWidth: 36; implicitHeight: 36
                        Accessible.name: "Look left"; onClicked: { viewport.lookAround(-.35, 0); viewport.forceActiveFocus() }
                    }
                    MokaidLabel { text: "Look around"; font.pixelSize: 11; color: Theme.secondary }
                    MokaidButton {
                        iconName: "chevron-right"; quiet: true; implicitWidth: 36; implicitHeight: 36
                        Accessible.name: "Look right"; onClicked: { viewport.lookAround(.35, 0); viewport.forceActiveFocus() }
                    }
                }
            }
            Column {
                id: statsColumn
                visible: officeArea.showStats
                width: 128
                anchors.right: parent.right
                anchors.verticalCenter: viewport.verticalCenter
                spacing: 12
                OfficeStat { iconName: "members"; value: String(root.team.length); label: "Team members" }
                OfficeStat { iconName: "bolt"; value: String(root.workingCount); label: "Working now"; accent: Theme.success }
                OfficeStat { iconName: "bell"; value: String(root.attentionCount); label: "Need attention"; accent: Theme.warning }
            }
            BusyIndicator { anchors.centerIn: viewport; running: viewport.loading; visible: running }
            Rectangle {
                visible: viewport.avatarError.length > 0 && !viewport.error.length
                anchors.left: viewport.left; anchors.top: viewport.top; anchors.margins: 12
                width: Math.min(viewport.width - 24, 430); height: avatarRecovery.implicitHeight + 24
                radius: Theme.radiusPanel; color: Theme.surface; border.color: Theme.border
                ColumnLayout {
                    id: avatarRecovery
                    anchors.fill: parent; anchors.margins: 12; spacing: 8
                    MokaidLabel { Layout.fillWidth: true; text: viewport.avatarError; wrapMode: Text.Wrap; color: Theme.warning }
                    MokaidButton { text: "Retry character"; onClicked: viewport.retryCustomAvatars() }
                }
            }
            Rectangle {
                visible: viewport.error.length > 0
                anchors.centerIn: viewport
                width: Math.min(parent.width - 40, 520); height: recovery.implicitHeight + 40
                radius: Theme.radiusPanel; color: Theme.surface; border.color: Theme.border
                ColumnLayout {
                    id: recovery
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: 20; spacing: 16
                    MokaidLabel { Layout.fillWidth: true; text: "The office renderer could not start.\n\n" + viewport.error; wrapMode: Text.Wrap; color: Theme.warning }
                    MokaidButton { text: "Retry renderer"; onClicked: viewport.retryRenderer() }
                }
            }
            ColumnLayout {
                id: teamStrip
                visible: !root.immersive
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                spacing: 10
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    MokaidLabel { text: "Your team"; font.pixelSize: 16; font.weight: Font.DemiBold }
                    MokaidLabel { text: String(root.team.length); color: Theme.secondary; font.pixelSize: 12 }
                    Item { Layout.fillWidth: true }
                    MokaidButton {
                        text: "View workforce"; iconName: "arrow-right"; quiet: true
                        font.pixelSize: 12; implicitHeight: 36
                        onClicked: features.navigate("agents")
                    }
                }
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    ListView {
                        id: agentDock
                        Layout.fillWidth: true; Layout.preferredHeight: 112
                        orientation: ListView.Horizontal; model: root.team; spacing: 10; clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        readonly property real cardWidth: Math.max(168, Math.min(222, (width - Math.max(0, count - 1) * spacing) / Math.max(1, count)))
                        delegate: AgentCard {
                            required property var modelData
                            width: agentDock.cardWidth; height: agentDock.height
                            agent: modelData; selected: office.selectedAgent.id === modelData.id
                            online: session.online && (modelData.kind === "human_linked" ? modelData.presence_status === "online" : ["active", "working", "busy"].indexOf(modelData.status) >= 0)
                            onClicked: root.selectAgent(modelData.id)
                        }
                        MokaidLabel {
                            anchors.centerIn: parent; visible: agentDock.count === 0; width: parent.width
                            text: "Your team starts here.\nAdd your first agent."
                            color: Theme.secondary; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
                        }
                        ScrollBar.horizontal: ScrollBar { height: 3; policy: ScrollBar.AsNeeded }
                    }
                    AbstractButton {
                        id: addAgent
                        Layout.preferredWidth: officeArea.width >= 900 ? 152 : 102
                        Layout.preferredHeight: 112
                        hoverEnabled: true; enabled: !!session.workspaceId
                        Accessible.name: "Add an agent. Open agents."
                        onClicked: features.navigate("agents")
                        background: Rectangle {
                            radius: 12
                            border.color: addAgent.visualFocus ? Theme.focusBorder : addAgent.hovered ? "#9670d7" : "#584278"
                            gradient: Gradient {
                                GradientStop { position: 0; color: addAgent.hovered ? "#27203d" : "#181528" }
                                GradientStop { position: 1; color: "#131420" }
                            }
                        }
                        contentItem: Item {
                            ColumnLayout {
                                anchors.centerIn: parent; spacing: 8
                                MokaidIcon { Layout.alignment: Qt.AlignHCenter; name: "plus"; size: 22; color: Theme.primary }
                                MokaidLabel { Layout.alignment: Qt.AlignHCenter; text: "Add agent"; font.pixelSize: 12; font.weight: Font.DemiBold }
                            }
                        }
                    }
                }
            }
        }
        Item {
            id: chatGap
            width: chatDrawer.open && !root.immersive ? 16 : 0
            height: officeRow.height
            Behavior on width { NumberAnimation { duration: root.chatMotion; easing.type: Easing.OutCubic } }
        }
        Item {
            id: chatDrawer
            objectName: "officeChatDrawer"
            readonly property bool open: !!office.selectedAgent.id
            readonly property real panelWidth: Math.min(450, Math.max(340, root.width * .36))
            width: open && !root.immersive ? panelWidth : 0
            height: officeRow.height
            clip: true
            Behavior on width { NumberAnimation { duration: root.chatMotion; easing.type: Easing.OutCubic } }
            AgentDetailPanel {
                id: agentDetail
                agent: {
                    const roster = office.agents.find(function(member) { return member.id === office.selectedAgent.id }) || office.selectedAgent
                    if (features.selectedId !== roster.id) return roster
                    const merged = Object.assign({}, roster, features.selectedRecord)
                    for (const key of ["current_task_id", "status", "presence_status", "screen_task", "screen_connection", "last_active_at"])
                        if (roster[key] !== undefined) merged[key] = roster[key]
                    return merged
                }
                onClosed: { office.closeChat(); features.clearSelection(); viewport.forceActiveFocus() }
                onActionRequested: function(action) { root.actionRequested(action) }
                width: chatDrawer.panelWidth
                height: parent.height
                x: chatDrawer.width - width
                visible: !root.immersive
                enabled: chatDrawer.open && !root.immersive
            }
        }
    }
    ChatPanel {
        objectName: "officeImmersiveChat"
        visible: root.immersive && !!office.selectedAgent.id
        enabled: visible
        compact: true
        width: Math.min(370, root.width - 24)
        height: Math.min(540, viewport.height - 24)
        anchors.right: parent.right; anchors.rightMargin: 12
        y: viewport.y + 12
        onClosed: viewport.forceActiveFocus()
        onOverviewRequested: { viewport.leaveOffice(); enterOffice.forceActiveFocus() }
    }
    Shortcut {
        sequence: "Escape"; enabled: root.active && root.immersive && !missions.opened
        onActivated: { viewport.leaveOffice(); enterOffice.forceActiveFocus() }
    }
    DropArea {
        id: officeDrop; anchors.fill: parent; enabled: !missions.opened && !!session.workspaceId
        onEntered: function(drag) { drag.accepted = drag.hasUrls }
        onDropped: function(event) {
            if (event.hasUrls) { missions.begin(); missions.addFiles(event.urls); event.acceptProposedAction() }
        }
        Rectangle {
            anchors.fill: parent; anchors.margins: 6; radius: Theme.radiusPanel
            visible: officeDrop.containsDrag; color: "#ed101426"; border.color: Theme.primary; border.width: 2
            ColumnLayout {
                anchors.centerIn: parent; width: Math.min(500, parent.width - 60); spacing: 20
                MokaidIcon { name: "file"; size: 46; color: Theme.primary; Layout.alignment: Qt.AlignHCenter }
                MokaidLabel { Layout.fillWidth: true; text: "Drop it. Delegate it."; font.pixelSize: 32; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter }
                MokaidLabel { Layout.fillWidth: true; text: "Add your files, describe the result,\nand find the right teammate."; color: Theme.secondary; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
            }
        }
    }
}
