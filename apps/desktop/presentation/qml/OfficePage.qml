import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Mokaid.Native 1.0

Item {
    id: root
    property bool active: true
    readonly property var diagnostics: viewport.diagnostics
    readonly property var team: office.agents.filter(function(agent) { return agent.status !== "archived" })
    readonly property int workingCount: team.filter(function(agent) { return agent.status === "working" || agent.status === "busy" }).length
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
            readonly property bool showStats: width >= 1050 && height >= 620
            ColumnLayout {
                id: officeHeading
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                spacing: 9
                RowLayout {
                    Layout.fillWidth: true; spacing: 14
                    MokaidLabel {
                        Layout.fillWidth: true
                        text: "Your office"
                        font.pixelSize: officeArea.width < 600 ? 29 : 34
                        font.weight: Font.Bold; font.letterSpacing: -.55
                    }
                    MokaidButton {
                        objectName: "officeNewMission"
                        iconName: "plus"; text: missions.hasDraft ? "Resume mission" : "New mission"
                        highlighted: true; enabled: !!session.workspaceId
                        onClicked: missions.begin()
                    }
                }
                MokaidLabel {
                    Layout.fillWidth: true
                    text: "Your team, together. Drop files into the office to start a mission."
                    color: Theme.secondary; font.pixelSize: 13; wrapMode: Text.Wrap
                }
            }
            NativeViewport {
                id: viewport
                anchors.left: parent.left; anchors.right: parent.right
                anchors.top: officeHeading.bottom; anchors.bottom: teamStrip.top
                anchors.topMargin: 16; anchors.bottomMargin: 16
                anchors.rightMargin: officeArea.showStats ? 146 : 0
                assetRoot: system.assetRoot; agents: office.agents; quality: system.quality
                paused: !root.active
                onAgentSelected: function(id) { office.selectAgent(id) }
                Accessible.role: Accessible.Pane
                Accessible.name: "Interactive office. Select an agent from the list for keyboard access."
            }
            AgentIndicators {
                anchors.fill: viewport
                visible: !viewport.loading && viewport.error.length === 0
                model: viewport.actorIndicators
                selectedAgentId: office.selectedAgent.id || ""
                reducedMotion: system.reducedMotion
                onAgentSelected: function(agentId) { office.selectAgent(agentId) }
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
                            onClicked: office.selectAgent(modelData.id)
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
            width: chatDrawer.open ? 16 : 0
            height: officeRow.height
            Behavior on width { NumberAnimation { duration: root.chatMotion; easing.type: Easing.OutCubic } }
        }
        Item {
            id: chatDrawer
            objectName: "officeChatDrawer"
            readonly property bool open: !!office.selectedAgent.id
            readonly property real panelWidth: Math.min(410, Math.max(320, root.width * .34))
            width: open ? panelWidth : 0
            height: officeRow.height
            clip: true
            Behavior on width { NumberAnimation { duration: root.chatMotion; easing.type: Easing.OutCubic } }
            ChatPanel {
                width: chatDrawer.panelWidth
                height: parent.height
                x: chatDrawer.width - width
                enabled: chatDrawer.open
            }
        }
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
