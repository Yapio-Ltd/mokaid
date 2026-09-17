pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "FeatureLogic.js" as Logic

Item {
    id: root
    signal actionRequested(var action)
    readonly property var roles: features.currentPage === "agent-new" ? features.visibleRecords : []
    readonly property var selectedRole: features.currentPage === "agent-new" ? (features.allRecords.find(function(role) { return Logic.id(role) === features.selectedId }) || ({})) : ({})
    readonly property bool hasSelection: !!selectedRole.key
    readonly property var createAction: features.actions.find(function(action) { return action.id === "create" }) || ({ enabled: false })
    readonly property bool wide: width >= 980
    property string query: ""
    function roleIcon(role) {
        const icons = { developer: "code", data_scientist: "analytics", research: "search", researcher: "search", finance: "billing", marketing: "pulse", sales: "members", sciences: "sun", legal: "shield", ops_hr: "members", product: "projects", design: "image", writer_content: "file", media_video: "play" }
        return icons[role.key] || "agents"
    }
    function skills(role) { return (role.skills || []).map(function(skill) { return String(typeof skill === "string" ? skill : skill.name || "").replace(/[-_]/g, " ") }).filter(function(name) { return name.length > 0 }) }
    function continueCreation() {
        if (hasSelection && createAction.enabled)
            actionRequested(Object.assign({}, createAction, { specialization: selectedRole }))
    }
    onVisibleChanged: if (visible) query = ""

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: 8
        anchors.bottomMargin: 12
        spacing: 16
        RowLayout {
            Layout.fillWidth: true
            spacing: 12
            MokaidButton { iconName: "chevron-left"; quiet: true; implicitWidth: 36; Accessible.name: "Back to agents"; onClicked: features.navigate("agents") }
            ColumnLayout {
                Layout.fillWidth: true; spacing: 4
                MokaidLabel { text: "Build your next teammate"; font.pixelSize: 26; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                MokaidLabel { text: "Pick a specialty. Give it a name and a mission."; font.pixelSize: 12; color: Theme.secondary; Layout.fillWidth: true; wrapMode: Text.Wrap }
            }
            MokaidButton { iconName: "refresh"; quiet: true; enabled: !features.busy; Accessible.name: "Refresh specializations"; onClicked: features.refresh() }
        }
        RowLayout {
            Layout.fillWidth: true; spacing: 10
            Rectangle { Layout.preferredWidth: 25; Layout.preferredHeight: 25; radius: 12.5; color: Theme.selected; border.color: Theme.selectedBorder; MokaidLabel { anchors.centerIn: parent; text: "1"; color: Theme.primary; font.weight: Font.Bold; font.pixelSize: 12 } }
            MokaidLabel { text: "Choose a specialty"; font.weight: Font.DemiBold; font.pixelSize: 12 }
            Rectangle { Layout.preferredWidth: 28; Layout.preferredHeight: 1; color: Theme.border }
            Rectangle { Layout.preferredWidth: 25; Layout.preferredHeight: 25; radius: 12.5; color: Theme.surface; MokaidLabel { anchors.centerIn: parent; text: "2"; color: Theme.secondary; font.pixelSize: 12 } }
            MokaidLabel { text: "Make it yours"; color: Theme.secondary; font.pixelSize: 12 }
            Item { Layout.fillWidth: true }
            MokaidLabel { visible: features.offline; text: "Saved catalog · Offline"; color: Theme.warning; font.pixelSize: 11 }
        }
        Rectangle {
            visible: features.error.length > 0
            Layout.fillWidth: true; Layout.preferredHeight: errorText.implicitHeight + 20; radius: 10; color: Theme.surface
            MokaidLabel { id: errorText; anchors.fill: parent; anchors.margins: 10; text: features.error; color: Theme.warning; font.pixelSize: 12; wrapMode: Text.Wrap }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 18
            ColumnLayout {
                Layout.fillWidth: true; Layout.fillHeight: true; spacing: 12
                RowLayout {
                    Layout.fillWidth: true; spacing: 12
                    MokaidTextField {
                        objectName: "agentCreationSearch"
                        Layout.fillWidth: true; Layout.maximumWidth: 360
                        placeholderText: "Find a specialty or skill…"
                        text: root.query; Accessible.name: "Search agent specialties"
                        onTextEdited: { root.query = text; features.search(text) }
                    }
                    Item { Layout.fillWidth: true }
                    MokaidLabel { text: root.roles.length + " specialties"; color: Theme.muted; font.pixelSize: 11 }
                }
                Item {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    GridView {
                        id: roleGrid
                        objectName: "agentSpecialtyGrid"
                        anchors.fill: parent; clip: true
                        readonly property int columns: width >= 850 ? 3 : width >= 480 ? 2 : 1
                        cellWidth: width / columns; cellHeight: 162
                        model: root.roles
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                        delegate: Item {
                            id: roleCell
                            required property var modelData
                            width: roleGrid.cellWidth; height: roleGrid.cellHeight
                            Button {
                                id: roleButton
                                objectName: "roleCard_" + roleCell.modelData.key
                                anchors.fill: parent; anchors.rightMargin: 10; anchors.bottomMargin: 10
                                padding: 14; hoverEnabled: true
                                readonly property bool selected: Logic.id(roleCell.modelData) === features.selectedId
                                Accessible.name: String(roleCell.modelData.name || "Specialty") + ". " + String(roleCell.modelData.description || "")
                                Accessible.description: selected ? "Selected specialty" : "Select this specialty"
                                onClicked: features.select(Logic.id(roleCell.modelData))
                                background: Rectangle {
                                    radius: 13; color: roleButton.selected ? Theme.selected : roleButton.down || roleButton.hovered ? Theme.hover : Theme.surface
                                    border.color: roleButton.visualFocus ? Theme.focusBorder : roleButton.selected ? Theme.primary : roleButton.hovered ? Theme.selectedBorder : Theme.border
                                    border.width: 1
                                }
                                contentItem: ColumnLayout {
                                    spacing: 9
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 10
                                        MokaidIcon { name: root.roleIcon(roleCell.modelData); size: 25; color: roleButton.selected ? Theme.primary : Theme.secondary }
                                        MokaidLabel { Layout.fillWidth: true; text: roleCell.modelData.name || "Specialty"; font.pixelSize: 14; font.weight: Font.DemiBold; elide: Text.ElideRight }
                                        MokaidIcon { visible: roleButton.selected; name: "tasks"; color: Theme.primary; size: 17 }
                                    }
                                    MokaidLabel { Layout.fillWidth: true; text: roleCell.modelData.description || ""; font.pixelSize: 11; color: Theme.secondary; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight }
                                    Item { Layout.fillHeight: true }
                                    MokaidLabel { Layout.fillWidth: true; text: root.skills(roleCell.modelData).slice(0, 3).join(" · "); color: roleButton.selected ? Theme.primary : Theme.muted; font.pixelSize: 10; elide: Text.ElideRight }
                                }
                            }
                        }
                    }
                    ColumnLayout {
                        anchors.centerIn: parent; width: Math.min(parent.width - 32, 340)
                        visible: root.roles.length === 0; spacing: 12
                        MokaidIcon { Layout.alignment: Qt.AlignHCenter; name: features.busy ? "refresh" : "search"; size: 32; color: Theme.primary }
                        MokaidLabel { Layout.fillWidth: true; text: features.busy ? "Loading specialties…" : root.query ? "No matching specialty" : "The catalog is unavailable"; font.pixelSize: 18; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
                        MokaidLabel { Layout.fillWidth: true; text: features.busy ? "Your team starts here." : root.query ? "Try another role or skill." : "Refresh to load the available roles."; color: Theme.secondary; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
                        MokaidButton { visible: !features.busy; Layout.alignment: Qt.AlignHCenter; text: root.query ? "Clear search" : "Refresh catalog"; onClicked: { if (root.query) { root.query = ""; features.search("") } else features.refresh() } }
                    }
                }
            }
            Rectangle {
                visible: root.wide
                Layout.preferredWidth: 288; Layout.alignment: Qt.AlignTop
                Layout.preferredHeight: Math.min(parent.height, roleSummary.implicitHeight + roleSummaryFooter.implicitHeight + 56)
                radius: Theme.radiusPanel; color: Theme.surface; border.color: root.hasSelection ? Theme.selectedBorder : Theme.border
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 20; spacing: 16
                    ScrollView {
                        id: roleSummaryScroll
                        Layout.fillWidth: true; Layout.fillHeight: true
                        contentWidth: availableWidth; clip: true
                        ColumnLayout {
                            id: roleSummary
                            width: roleSummaryScroll.availableWidth; spacing: 12
                            MokaidIcon { Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 4; name: root.roleIcon(root.selectedRole); size: 52; color: Theme.primary }
                            MokaidLabel { Layout.fillWidth: true; text: root.hasSelection ? root.selectedRole.name : "A place on your team"; font.pixelSize: 21; font.weight: Font.DemiBold; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter }
                            MokaidLabel { Layout.fillWidth: true; text: root.hasSelection ? root.selectedRole.description || "" : "Choose a specialty to explore what your new agent can do."; font.pixelSize: 12; color: Theme.secondary; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter }
                            Rectangle { visible: root.skills(root.selectedRole).length > 0; Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.divider }
                            MokaidLabel { visible: root.skills(root.selectedRole).length > 0; text: "Starting skills"; font.pixelSize: 12; font.weight: Font.DemiBold }
                            Flow {
                                visible: root.skills(root.selectedRole).length > 0
                                Layout.fillWidth: true; spacing: 6
                                Repeater {
                                    model: root.skills(root.selectedRole)
                                    Rectangle {
                                        id: skillChip
                                        required property string modelData
                                        width: Math.min(skillText.implicitWidth + 16, parent.width); height: 27; radius: 6; color: Theme.raised
                                        MokaidLabel { id: skillText; anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; text: skillChip.modelData; font.pixelSize: 11; color: Theme.secondary; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
                                    }
                                }
                            }
                        }
                    }
                    ColumnLayout {
                        id: roleSummaryFooter
                        Layout.fillWidth: true; spacing: 12
                        MokaidLabel { Layout.fillWidth: true; text: root.hasSelection ? "Next: name your agent and set its working style." : "Select any specialty to continue."; color: Theme.muted; font.pixelSize: 11; wrapMode: Text.Wrap }
                        MokaidButton { objectName: root.wide ? "agentCreationContinue" : "agentCreationContinueHidden"; Layout.fillWidth: true; text: "Make it yours"; iconName: "arrow-right"; highlighted: true; enabled: root.hasSelection && root.createAction.enabled; onClicked: root.continueCreation() }
                    }
                }
            }
        }
        Rectangle {
            visible: !root.wide
            Layout.fillWidth: true; Layout.preferredHeight: 72
            radius: 12; color: Theme.surface; border.color: root.hasSelection ? Theme.selectedBorder : Theme.border
            RowLayout {
                anchors.fill: parent; anchors.margins: 12; spacing: 12
                MokaidIcon { name: root.roleIcon(root.selectedRole); size: 30; color: Theme.primary }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 3
                    MokaidLabel { Layout.fillWidth: true; text: root.hasSelection ? root.selectedRole.name : "Choose your specialty"; font.weight: Font.DemiBold; elide: Text.ElideRight }
                    MokaidLabel { Layout.fillWidth: true; text: root.hasSelection ? "Ready to personalize" : "Select a role above to get started"; color: Theme.secondary; font.pixelSize: 11; elide: Text.ElideRight }
                }
                MokaidButton { objectName: !root.wide ? "agentCreationContinue" : "agentCreationContinueHidden"; text: "Make it yours"; iconName: "arrow-right"; highlighted: true; enabled: root.hasSelection && root.createAction.enabled; onClicked: root.continueCreation() }
            }
        }
    }
}
