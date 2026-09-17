pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "FeatureLogic.js" as Logic

ScrollView {
    id: root
    required property string page
    required property var overview
    required property var actions
    signal actionRequested(var action)
    signal inspectRequested()
    contentWidth: availableWidth; clip: true
    readonly property var groups: Logic.summaryGroups(page,overview)
    readonly property var metrics: Logic.metricEntries(page,overview)
    readonly property bool analytics: page === "analytics" || page === "admin-overview" || page === "admin-costs"
    function request(id) { var found=actions.find(function(a){return a.id===id;}); if(found && found.enabled) actionRequested(found); }
    function actionEnabled(id) { var found=actions.find(function(a){return a.id===id;}); return !!found && found.enabled; }
    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
    ColumnLayout {
        width: root.availableWidth; spacing: 16
        Flow {
            id: metricFlow
            readonly property int columns: Math.max(1,Math.floor(width/215))
            Layout.fillWidth: true; spacing: 12; visible: root.analytics && root.metrics.length > 0
            Repeater {
                model: root.metrics
                Rectangle {
                    id: metric
                    required property var modelData
                    width: (metricFlow.width-(metricFlow.columns-1)*12)/metricFlow.columns; height: 88; radius: 14; color: Theme.surface; border.color: Theme.border
                    ColumnLayout { anchors.fill: parent; anchors.margins: 12; spacing: 4; MokaidLabel { Layout.fillWidth: true; text: metric.modelData.label; font.pixelSize: 12; color: Theme.secondary; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight } MokaidLabel { Layout.fillWidth: true; text: metric.modelData.value; font.pixelSize: 24; font.weight: Font.DemiBold; elide: Text.ElideRight } }
                }
            }
        }
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: chartContent.implicitHeight+40
            visible: root.page === "analytics"; radius: 14; color: Theme.surface; border.color: Theme.border
            ColumnLayout {
                id: chartContent
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 20; spacing: 20
                MokaidLabel { text: "Work by status"; font.pixelSize: 17; font.weight: Font.DemiBold }
                Repeater {
                    model: root.overview.tasks_by_status || []
                    RowLayout {
                        id: bar
                        required property var modelData
                        Layout.fillWidth: true; spacing: 16
                        MokaidLabel { text: Logic.human(bar.modelData.status); color: Theme.secondary; Layout.preferredWidth: 108; font.pixelSize: 12; elide: Text.ElideRight }
                        Rectangle {
                            Layout.fillWidth: true; height: 8; radius: 4; color: Theme.raised
                            Rectangle { width: parent.width * Math.min(1,Number(bar.modelData.count) / Math.max(1,Number((root.overview.overview || {}).total_tasks || 0))); height: parent.height; radius: 4; color: Theme[Logic.tone(bar.modelData.status)] }
                        }
                        MokaidLabel { text: bar.modelData.count; Layout.preferredWidth: 36; horizontalAlignment: Text.AlignRight; font.pixelSize: 12 }
                    }
                }
                MokaidLabel { visible: !(root.overview.tasks_by_status || []).length; text: "Task activity will appear as your workspace gets to work."; color: Theme.secondary; Layout.fillWidth: true; wrapMode: Text.Wrap }
            }
        }
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: dailyContent.implicitHeight+40
            visible: root.page === "analytics"; radius: 14; color: Theme.surface; border.color: Theme.border
            ColumnLayout {
                id: dailyContent
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 20; spacing: 18
                RowLayout { MokaidLabel { text: "Completed work"; font.pixelSize: 17; font.weight: Font.DemiBold; Layout.fillWidth: true } MokaidLabel { text: "Last 14 days"; color: Theme.muted; font.pixelSize: 12 } }
                MokaidLabel { visible: !(root.overview.tasks_completed_daily || []).length; text: "No completed tasks have been recorded in this period."; Layout.fillWidth: true; wrapMode: Text.Wrap; color: Theme.secondary }
                Repeater {
                    model: root.overview.tasks_completed_daily || []
                    RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        MokaidLabel { text: Logic.date(parent.modelData.day); Layout.fillWidth: true; color: Theme.secondary; font.pixelSize: 12 }
                        MokaidLabel { text: parent.modelData.count+" completed"; font.pixelSize: 12 }
                    }
                }
            }
        }
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: contributors.implicitHeight+40
            visible: root.page === "analytics" && (root.overview.top_agents || []).length > 0; radius: 14; color: Theme.surface; border.color: Theme.border
            ColumnLayout {
                id: contributors
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 20; spacing: 18
                MokaidLabel { text: "Team contribution"; font.pixelSize: 17; font.weight: Font.DemiBold }
                Repeater {
                    model: root.overview.top_agents || []
                    RowLayout {
                        id: contributor
                        required property var modelData
                        Layout.fillWidth: true
                        ColumnLayout { Layout.fillWidth: true; spacing: 4; MokaidLabel { text: contributor.modelData.display_name; font.weight: Font.Medium } MokaidLabel { text: contributor.modelData.role_title || Logic.human(contributor.modelData.kind); color: Theme.secondary; font.pixelSize: 12 } }
                        MokaidLabel { text: contributor.modelData.tasks_done+" tasks"; color: Theme.primary; font.pixelSize: 12 }
                    }
                }
            }
        }
        Repeater {
            model: root.groups
            Rectangle {
                id: group
                required property var modelData
                Layout.fillWidth: true; Layout.preferredHeight: groupContent.implicitHeight+40
                radius: 14; color: Theme.surface; border.color: Theme.border
                ColumnLayout {
                    id: groupContent
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 20; spacing: 18
                    MokaidLabel { text: group.modelData.title; font.pixelSize: 17; font.weight: Font.DemiBold }
                    Repeater {
                        model: group.modelData.rows
                        ColumnLayout {
                            id: setting
                            required property var modelData
                            Layout.fillWidth: true; spacing: 7
                            MokaidLabel { text: setting.modelData.label; color: Theme.muted; font.pixelSize: 12 }
                            MokaidLabel { Layout.fillWidth: true; text: setting.modelData.value; wrapMode: Text.Wrap; font.pixelSize: 14 }
                        }
                    }
                }
            }
        }
        Flow {
            Layout.fillWidth: true; spacing: 10
            Repeater {
                model: root.actions
                MokaidButton {
                    required property var modelData
                    visible: !modelData.selection && modelData.id!==Logic.meta(root.page).primary
                    text: modelData.title; enabled: modelData.enabled
                    width: Math.min(implicitWidth,parent.width)
                    onClicked: root.actionRequested(modelData)
                }
            }
        }
        MokaidLabel { visible: root.analytics && root.metrics.length===0; Layout.fillWidth: true; text: "No metrics are available yet. Refresh when your workspace has synchronized."; color: Theme.secondary; wrapMode: Text.Wrap }
        MokaidButton { text: root.analytics ? "Explore report details" : "Advanced details"; quiet: true; iconName: "chevron-right"; onClicked: root.inspectRequested() }
        Item { Layout.preferredHeight: 12 }
    }
}
