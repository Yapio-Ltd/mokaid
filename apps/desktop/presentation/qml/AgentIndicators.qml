pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls

Item {
    id: root

    property var model: null
    property string selectedAgentId: ""
    property bool reducedMotion: false
    signal agentSelected(string agentId)

    Repeater {
        model: root.model

        delegate: Item {
            id: indicator

            required property string agentId
            required property string agentName
            required property int agentLevel
            required property string activityText
            required property string activityDetail
            required property color activityTone
            required property real labelX
            required property real labelY
            required property real anchorX
            required property real anchorY
            required property real labelWidth
            required property real labelHeight
            required property bool tetherVisible
            required property bool onScreen

            width: root.width
            height: root.height
            visible: onScreen
            z: badge.hovered || badge.activeFocus ? 2 : 1

            readonly property real tetherX: Math.max(badge.x + 6, Math.min(anchorX, badge.x + badge.width - 6))
            readonly property real tetherY: Math.max(badge.y + 4, Math.min(anchorY, badge.y + badge.height - 4))
            readonly property string description: agentName
                + (agentLevel > 0 ? qsTr(", level %1").arg(agentLevel) : "")
                + ", " + activityDetail

            Rectangle {
                id: tether
                x: indicator.tetherX
                y: indicator.tetherY
                width: Math.hypot(indicator.anchorX - x, indicator.anchorY - y)
                height: 1
                color: "#667a718e"
                transformOrigin: Item.Left
                rotation: Math.atan2(indicator.anchorY - y, indicator.anchorX - x) * 180 / Math.PI
                visible: indicator.tetherVisible && width > 8
                antialiasing: true
            }

            Rectangle {
                x: indicator.anchorX - 1
                y: indicator.anchorY - 1
                width: 2
                height: 2
                radius: 1
                color: "#9cbbb0d1"
                visible: tether.visible
            }

            AbstractButton {
                id: badge
                // The model filters head motion and resolves the whole layout.
                // Per-label interpolation can cross another label during reflow.
                x: indicator.labelX
                y: indicator.labelY
                width: indicator.labelWidth
                height: indicator.labelHeight
                padding: 0
                hoverEnabled: true
                focusPolicy: Qt.StrongFocus
                Accessible.role: Accessible.Button
                Accessible.name: indicator.description
                Accessible.description: qsTr("Open conversation with %1").arg(indicator.agentName)
                onClicked: root.agentSelected(indicator.agentId)

                background: Rectangle {
                    radius: 6
                    color: badge.hovered || badge.down ? "#f0221d31" : "#ed14121e"
                    border.width: 1
                    border.color: badge.activeFocus ? "#c5b4ff"
                        : root.selectedAgentId === indicator.agentId ? "#9a82da"
                        : badge.hovered ? "#70665387" : "#544b425f"
                }

                contentItem: Item {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    anchors.topMargin: 4
                    anchors.bottomMargin: 4

                    MokaidLabel {
                        id: level
                        anchors.right: parent.right
                        y: 1
                        visible: indicator.agentLevel > 0
                        text: qsTr("Lv. %1").arg(indicator.agentLevel)
                        color: "#bcb2d0"
                        font.pixelSize: 9
                        font.weight: Font.Medium
                        height: 12
                        verticalAlignment: Text.AlignVCenter
                    }

                    MokaidLabel {
                        anchors.left: parent.left
                        anchors.right: level.visible ? level.left : parent.right
                        anchors.rightMargin: level.visible ? 6 : 0
                        height: 13
                        text: indicator.agentName
                        color: "#f2eef9"
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }

                    Rectangle {
                        id: activityDot
                        x: 0
                        y: 19
                        width: 3
                        height: 3
                        radius: 1.5
                        color: indicator.activityTone
                    }

                    MokaidLabel {
                        anchors.left: activityDot.right
                        anchors.leftMargin: 4
                        anchors.right: parent.right
                        y: 14
                        height: 12
                        text: indicator.activityText
                        color: "#b6aec8"
                        font.pixelSize: 9
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }
                }

                ToolTip {
                    visible: badge.hovered || badge.activeFocus
                    delay: 650
                    padding: 9
                    width: Math.min(280, implicitWidth)
                    contentItem: MokaidLabel {
                        text: indicator.description
                        color: "#f2eef9"
                        font.pixelSize: 11
                        wrapMode: Text.Wrap
                    }
                    background: Rectangle {
                        radius: 6
                        color: "#f51c172b"
                        border.color: "#675571"
                    }
                }
            }
        }
    }
}
