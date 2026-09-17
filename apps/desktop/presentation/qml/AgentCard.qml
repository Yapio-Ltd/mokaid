import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

AbstractButton {
    id: root
    property var agent: ({})
    property bool selected: false
    property bool online: true
    readonly property string agentName: agent.display_name || agent.name || "Agent"
    readonly property string missionStatus: agent.status === "busy" || agent.status === "working" ? "Working" : agent.status === "waiting" ? "Needs you" : agent.status === "blocked" ? "Blocked" : agent.status === "active" ? "Active" : agent.status === "idle" ? "Idle" : agent.status === "training" ? "Training" : agent.status || "Status unavailable"
    readonly property color statusColor: ["busy", "working", "active"].indexOf(agent.status) >= 0 ? Theme.success : ["waiting", "training"].indexOf(agent.status) >= 0 ? Theme.warning : agent.status === "blocked" ? Theme.danger : Theme.accentBlue
    readonly property real progress: Number(agent.xp_for_next_level) > 0 ? Math.max(0, Math.min(1, Number(agent.xp || 0) / Number(agent.xp_for_next_level))) : -1
    implicitWidth: 192; implicitHeight: 112
    hoverEnabled: true; padding: 13
    Accessible.name: agentName + ", " + (agent.role_title || "Agent") + ", " + missionStatus + (agent.level ? ", level " + agent.level : "")
    Accessible.description: "Open conversation"
    background: Rectangle {
        radius: 12
        border.color: root.visualFocus ? Theme.focusBorder : root.selected ? "#8b65cb" : root.hovered ? "#58466f" : Theme.border
        gradient: Gradient {
            GradientStop { position: 0; color: root.selected ? "#24213a" : root.hovered ? "#1c1d2f" : "#171925" }
            GradientStop { position: 1; color: root.selected ? "#161827" : "#10121d" }
        }
    }
    contentItem: Item {
        RowLayout {
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            spacing: 10
            AgentPortrait { kind: root.agent.asset_type || "male"; online: root.online; size: 44 }
            ColumnLayout {
                Layout.fillWidth: true; spacing: 5
                MokaidLabel { Layout.fillWidth: true; text: root.agentName; font.pixelSize: 12; font.weight: Font.DemiBold; elide: Text.ElideRight }
                MokaidLabel { Layout.fillWidth: true; text: root.agent.role_title || "AI agent"; color: Theme.secondary; font.pixelSize: 10; elide: Text.ElideRight }
            }
        }
        RowLayout {
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            anchors.bottomMargin: root.progress >= 0 ? 11 : 2
            spacing: 6
            Rectangle { Layout.preferredWidth: 5; Layout.preferredHeight: 5; radius: 3; color: root.statusColor }
            MokaidLabel { Layout.fillWidth: true; text: root.missionStatus; color: root.statusColor; font.pixelSize: 10; elide: Text.ElideRight }
            MokaidLabel { visible: Number(root.agent.level) > 0; text: "Lv. " + root.agent.level; font.pixelSize: 10; color: Theme.secondary }
        }
        Rectangle {
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            height: 3; radius: 2; color: "#2d2941"; visible: root.progress >= 0
            Rectangle { width: parent.width * root.progress; height: parent.height; radius: 2; color: "#a17ae8" }
        }
    }
    ToolTip.visible: hovered; ToolTip.delay: 750
    ToolTip.text: agentName + " · " + (agent.role_title || "Agent") + " · " + missionStatus
}
