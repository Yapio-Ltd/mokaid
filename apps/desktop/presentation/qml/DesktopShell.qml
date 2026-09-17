import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    property bool adminMode: false
    property bool protectedWork: false
    property bool minimized: false
    readonly property var diagnostics: officeLoader.item ? officeLoader.item.diagnostics : ({})
    readonly property var secondaryPages: ["profile", "members", "integrations", "billing"]
    readonly property var primaryPages: features.pages.filter(function(page) {
        return !page.hidden && page.id !== "knowledge"
            && (page.section === "Administration") === root.adminMode
            && root.secondaryPages.indexOf(page.id) < 0
    })
    signal actionRequested(var action)
    signal searchRequested()
    signal notificationsRequested()
    signal preferencesRequested()
    signal accountMenuRequested(var anchor)
    signal createWorkspaceRequested()
    signal projectRequested()

    RowLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: root.width >= 1280 ? 24 : 18
        Rectangle {
            id: sidebar
            Layout.preferredWidth: root.width >= 1450 ? 267 : root.width >= 1200 ? 238 : 210
            Layout.fillHeight: true
            radius: 17
            border.color: "#302940"
            gradient: Gradient {
                GradientStop { position: 0; color: "#11111e" }
                GradientStop { position: .52; color: "#0c0e17" }
                GradientStop { position: 1; color: "#111120" }
            }
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 15
                spacing: 12
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 55
                    Layout.leftMargin: 12
                    spacing: 13
                    Image {
                        source: "qrc:/branding/logo-without-bg.png"
                        Layout.preferredWidth: 38; Layout.preferredHeight: 38
                        sourceSize.width: 96; sourceSize.height: 96
                        fillMode: Image.PreserveAspectFit
                    }
                    MokaidLabel { text: "mokaid"; font.pixelSize: 26; font.weight: Font.Bold; font.letterSpacing: -.65 }
                    Item { Layout.fillWidth: true }
                }
                MokaidComboBox {
                    id: workspacePicker
                    Layout.fillWidth: true; Layout.preferredHeight: 56
                    Layout.bottomMargin: 10
                    model: session.workspaces; textRole: "name"; valueRole: "id"
                    currentIndex: count > 0 ? indexOfValue(session.workspaceId) : -1
                    enabled: !root.protectedWork && !session.busy
                    onActivated: session.selectWorkspace(currentValue)
                    Accessible.name: "Workspace: " + displayText
                    contentItem: RowLayout {
                        spacing: 10
                        Rectangle {
                            Layout.preferredWidth: 31; Layout.preferredHeight: 31
                            radius: 10; color: "#202037"; border.color: "#3c3652"
                            MokaidIcon { anchors.centerIn: parent; name: "members"; size: 20; color: "#d4c8f0" }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 2
                            MokaidLabel { Layout.fillWidth: true; text: workspacePicker.displayText || "Choose workspace"; font.pixelSize: 12; font.weight: Font.DemiBold; elide: Text.ElideRight }
                            MokaidLabel { text: "Workspace"; font.pixelSize: 10; color: Theme.secondary }
                        }
                    }
                    ToolTip.visible: hovered && !enabled
                    ToolTip.text: "Save your work and close previews before changing workspace."
                }
                MokaidLabel {
                    visible: root.adminMode
                    Layout.fillWidth: true; Layout.leftMargin: 12
                    text: "Administration"; color: Theme.warning; font.pixelSize: 12; font.weight: Font.DemiBold
                }
                ListView {
                    id: navigation
                    Layout.fillWidth: true; Layout.fillHeight: true
                    model: root.primaryPages; clip: true; spacing: 4
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: AbstractButton {
                        id: navButton
                        required property var modelData
                        readonly property bool selected: features.currentPage === modelData.id
                        width: navigation.width; height: 44
                        hoverEnabled: true
                        Accessible.name: modelData.title
                        Accessible.role: Accessible.PageTab
                        Accessible.description: selected ? "Current page" : "Open " + modelData.title
                        onClicked: features.navigate(modelData.id)
                        background: Rectangle {
                            radius: 10
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0; color: navButton.selected ? "#392269" : navButton.hovered ? "#222036" : "transparent" }
                                GradientStop { position: .6; color: navButton.selected ? "#221c3e" : navButton.hovered ? "#191a2a" : "transparent" }
                                GradientStop { position: 1; color: navButton.selected ? "#252341" : navButton.hovered ? "#171a28" : "transparent" }
                            }
                            border.width: navButton.selected || navButton.visualFocus ? 1 : 0
                            border.color: navButton.visualFocus ? Theme.focusBorder : "#8b5ded"
                            Rectangle {
                                visible: navButton.selected
                                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                                anchors.leftMargin: 12; anchors.rightMargin: 12
                                height: 1; color: "#679f78ee"
                            }
                        }
                        contentItem: RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16
                            spacing: 17
                            MokaidIcon { name: navButton.modelData.id; size: 20; color: navButton.selected ? "#e2d4ff" : "#b4c1e2" }
                            MokaidLabel {
                                Layout.fillWidth: true
                                text: navButton.modelData.title; font.pixelSize: 13
                                font.weight: navButton.selected ? Font.DemiBold : Font.Normal
                                color: navButton.selected ? Theme.text : Theme.secondary
                                elide: Text.ElideRight
                            }
                            Rectangle {
                                visible: navButton.selected
                                Layout.preferredWidth: 6; Layout.preferredHeight: 6
                                radius: 3; color: "#dbc3ff"
                                Rectangle { anchors.centerIn: parent; width: 14; height: 14; radius: 7; color: "#249a7cff" }
                            }
                        }
                    }
                    ScrollBar.vertical: ScrollBar { width: 3; policy: ScrollBar.AsNeeded }
                }
                MokaidButton {
                    visible: session.administrator
                    Layout.fillWidth: true; quiet: true; iconName: "shield"
                    text: root.adminMode ? "Back to workspace" : "Administration"
                    font.pixelSize: 12
                    onClicked: features.navigate(root.adminMode ? "office" : "admin-overview")
                }
                AbstractButton {
                    id: teamPromo
                    visible: root.height >= 780 && !root.adminMode
                    Layout.fillWidth: true; Layout.preferredHeight: root.height >= 900 ? 136 : 112
                    Layout.topMargin: 6; Layout.bottomMargin: 6
                    hoverEnabled: true
                    Accessible.name: "Multiply your impact with AI agents. Open agents."
                    onClicked: features.navigate("agents")
                    background: Rectangle {
                        radius: 13; clip: true
                        color: "#0d0e1b"
                        border.color: teamPromo.visualFocus ? Theme.focusBorder : teamPromo.hovered ? "#8660c9" : "#443461"
                        Image {
                            anchors.right: parent.right; anchors.rightMargin: -60
                            anchors.verticalCenter: parent.verticalCenter
                            width: 220; height: 220
                            source: "qrc:/ui/workforce-energy-orb.png"
                            fillMode: Image.PreserveAspectFit; opacity: .88
                        }
                    }
                    contentItem: Item {
                        MokaidLabel {
                            anchors.left: parent.left; anchors.leftMargin: 20
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Multiply\nyour impact\nwith AI agents."
                            font.pixelSize: 15; font.weight: Font.Medium; lineHeight: 1.25
                        }
                        Rectangle {
                            anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 12
                            width: 33; height: 33; radius: 17
                            color: "#d20c0d19"; border.color: "#8460ce"
                            MokaidIcon { anchors.centerIn: parent; name: "arrow-right"; size: 16; color: Theme.text }
                        }
                    }
                }
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.divider }
                RowLayout {
                    Layout.fillWidth: true; Layout.preferredHeight: 58; Layout.maximumHeight: 58
                    spacing: 4
                    AbstractButton {
                        id: profileButton
                        Layout.fillWidth: true; Layout.fillHeight: true
                        hoverEnabled: true
                        Accessible.name: "Open your profile"
                        onClicked: features.navigate("profile")
                        background: Rectangle { radius: 10; color: profileButton.hovered ? Theme.hover : "transparent"; border.color: profileButton.visualFocus ? Theme.focusBorder : "transparent" }
                        contentItem: RowLayout {
                            spacing: 10
                            Rectangle {
                                Layout.preferredWidth: 38; Layout.preferredHeight: 38
                                radius: 19; color: "#27213c"; border.color: "#665187"
                                MokaidLabel { anchors.centerIn: parent; text: (session.user.full_name || session.user.email || "M").slice(0, 1).toUpperCase(); font.pixelSize: 16; font.weight: Font.DemiBold; color: "#e4d9ff" }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 3
                                MokaidLabel { Layout.fillWidth: true; text: session.user.full_name || session.user.email || "Your account"; font.pixelSize: 12; font.weight: Font.DemiBold; elide: Text.ElideRight }
                                MokaidLabel { text: "Your account"; color: Theme.secondary; font.pixelSize: 10 }
                            }
                        }
                    }
                    MokaidIconButton { objectName: "accountActionsButton"; implicitWidth: 36; implicitHeight: 44; subtle: true; iconName: "more"; hint: "Account and workspace menu"; onClicked: root.accountMenuRequested(this) }
                }
            }
        }
        ColumnLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.rightMargin: root.width >= 1280 ? 10 : 0
            spacing: 0
            RowLayout {
                Layout.fillWidth: true; Layout.preferredHeight: 54; Layout.bottomMargin: 12
                spacing: 12
                AbstractButton {
                    id: searchButton
                    Layout.preferredWidth: Math.max(210, Math.min(510, root.width * .315))
                    Layout.preferredHeight: 44
                    enabled: !!session.workspaceId; hoverEnabled: true
                    Accessible.name: "Search workspace"
                    onClicked: root.searchRequested()
                    background: Rectangle {
                        radius: 22
                        border.color: searchButton.visualFocus ? Theme.focusBorder : searchButton.hovered ? "#5d4b86" : "#343047"
                        gradient: Gradient {
                            GradientStop { position: 0; color: searchButton.hovered ? "#1c1b2f" : "#141522" }
                            GradientStop { position: 1; color: "#0e101b" }
                        }
                    }
                    contentItem: RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 17; anchors.rightMargin: 14
                        spacing: 12
                        MokaidIcon { name: "search"; size: 18; color: Theme.secondary }
                        MokaidLabel { Layout.fillWidth: true; text: "Search your workspace…"; color: Theme.secondary; font.pixelSize: 12; elide: Text.ElideRight }
                        Rectangle {
                            Layout.preferredWidth: 42; Layout.preferredHeight: 24; radius: 6
                            color: "#202139"; border.color: "#302e47"
                            MokaidLabel { anchors.centerIn: parent; text: Qt.platform.os === "osx" ? "⌘ K" : "Ctrl K"; color: Theme.secondary; font.pixelSize: 10 }
                        }
                    }
                }
                Item { Layout.fillWidth: true }
                MokaidIconButton { visible: root.width >= 1280; iconName: "projects"; hint: "Run a project locally"; subtle: true; onClicked: root.projectRequested() }
                MokaidIconButton { iconName: "sun"; hint: "Desktop preferences"; subtle: true; onClicked: root.preferencesRequested() }
                MokaidIconButton {
                    iconName: "bell"; subtle: true
                    hint: activity.unreadCount > 0 ? activity.unreadCount + " unread notifications" : "Notifications"
                    enabled: !!session.workspaceId
                    onClicked: root.notificationsRequested()
                    Rectangle {
                        visible: activity.unreadCount > 0
                        anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 5
                        width: 7; height: 7; radius: 4; color: Theme.primary
                        border.color: Theme.background
                    }
                }
                AbstractButton {
                    id: connectionButton
                    Layout.preferredWidth: session.online ? 132 : 160
                    Layout.preferredHeight: 44
                    hoverEnabled: true
                    Accessible.name: (session.online ? "Connected" : "Offline, read only") + ". Refresh connection and data."
                    onClicked: session.online ? features.refresh() : session.retry()
                    background: Rectangle { radius: 22; color: connectionButton.hovered ? Theme.hover : "#10111d"; border.color: connectionButton.visualFocus ? Theme.focusBorder : "#2b293e" }
                    contentItem: Item {
                        Row {
                            anchors.centerIn: parent; spacing: 10
                            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 8; height: 8; radius: 4; color: session.online ? Theme.success : Theme.warning }
                            MokaidLabel { text: session.online ? "Connected" : "Offline · read only"; color: Theme.text; font.pixelSize: 11; font.weight: Font.Medium }
                        }
                    }
                    ToolTip.visible: hovered; ToolTip.delay: 650; ToolTip.text: "Refresh connection and data"
                }
                AbstractButton {
                    id: accountButton
                    Layout.preferredWidth: 48; Layout.preferredHeight: 48
                    hoverEnabled: true
                    Accessible.name: "Account and workspace menu"
                    onClicked: root.accountMenuRequested(this)
                    background: Rectangle { radius: 24; color: "transparent"; border.color: accountButton.visualFocus ? Theme.focusBorder : "transparent" }
                    contentItem: Image { source: "qrc:/ui/workforce-energy-orb.png"; fillMode: Image.PreserveAspectFit; opacity: accountButton.hovered ? 1 : .88 }
                    ToolTip.visible: hovered; ToolTip.delay: 650; ToolTip.text: "Account and workspace menu"
                }
            }
            MokaidLabel {
                Layout.fillWidth: true; Layout.bottomMargin: visible ? 12 : 0
                visible: session.error.length > 0
                text: session.error; color: Theme.warning; padding: 12; wrapMode: Text.Wrap
                background: Rectangle { radius: 10; color: "#292416" }
            }
            Item {
                Layout.fillWidth: true; Layout.fillHeight: true
                Loader {
                    id: officeLoader; anchors.fill: parent
                    active: session.authenticated && !!session.workspaceId
                    visible: features.currentPage === "office"
                    sourceComponent: OfficePage { active: officeLoader.visible && !preview.visible && !root.minimized }
                }
                Loader {
                    id: agentsLoader; anchors.fill: parent
                    active: features.currentPage === "agents" && !!session.workspaceId
                    visible: active
                    sourceComponent: AgentsPage { onActionRequested: function(action) { root.actionRequested(action) } }
                }
                FeaturePage {
                    anchors.fill: parent
                    visible: features.currentPage !== "office" && features.currentPage !== "agents"
                    onActionRequested: function(action) { root.actionRequested(action) }
                }
                ColumnLayout {
                    anchors.centerIn: parent; width: Math.min(420, parent.width - 48); spacing: 20
                    visible: !session.workspaceId && !root.adminMode
                    MokaidLabel { text: "Welcome to Mokaid"; font.pixelSize: 30; font.weight: Font.DemiBold }
                    MokaidLabel { text: "Create your workspace to start building your AI team, or ask a workspace owner for an invitation."; color: Theme.secondary; Layout.fillWidth: true; wrapMode: Text.Wrap }
                    MokaidButton { text: "Create a workspace"; highlighted: true; enabled: session.online; onClicked: root.createWorkspaceRequested() }
                }
                PreviewPanel {
                    anchors.fill: parent; visible: preview.visible
                    onFilesRequested: { preview.visible = false; features.navigate("drive") }
                }
                MissionPanel { anchors.fill: parent; anchors.leftMargin: Math.max(0, parent.width - 720); z: 10 }
            }
        }
    }
}
