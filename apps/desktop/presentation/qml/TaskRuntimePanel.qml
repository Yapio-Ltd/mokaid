pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "FeatureLogic.js" as Logic

Rectangle {
    id: root
    property var runtime: ({})
    property int fileCount: 0
    property bool canExtendBudget: false
    property bool extendingBudget: false
    property bool budgetIncreased: false
    property int budgetRetryCredits: 0
    property string budgetError: ""
    signal filesRequested()
    signal extendBudgetRequested(int credits)
    readonly property var participants: sequence(runtime.participants)
    readonly property var checks: sequence((runtime.verification || {}).checks)
    readonly property var limitations: sequence(runtime.limitations)
    readonly property bool budgetPaused: ["waiting_for_budget", "budget_exhausted"].indexOf(runtime.status) >= 0
    visible: runtime.engine === "openai_agents"
    implicitHeight: content.implicitHeight + 24
    radius: 10; color: "#171927"; border.color: "#2b2c42"
    function sequence(value) {
        const rows = []
        if (value && typeof value !== "string" && typeof value.length === "number")
            for (let i = 0; i < value.length; ++i) rows.push(value[i])
        return rows
    }
    ColumnLayout {
        id: content
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 12
        spacing: 10
        MokaidLabel { text: "Team execution"; font.pixelSize: 12; font.weight: Font.DemiBold }
        MokaidLabel { objectName: "taskRuntimeStatus"; Layout.fillWidth: true; text: Logic.runtimeStatus(root.runtime.status); textFormat: Text.PlainText; font.pixelSize: 11; wrapMode: Text.Wrap; color: root.budgetPaused ? Theme.warning : Theme.secondary }
        MokaidLabel { Layout.fillWidth: true; visible: root.budgetPaused; text: "The mission reached its credit allowance. Review the available results before continuing."; wrapMode: Text.Wrap; font.pixelSize: 11; color: Theme.secondary }
        ColumnLayout {
            Layout.fillWidth: true; spacing: 6; visible: root.budgetPaused
            MokaidLabel { Layout.fillWidth: true; text: "Reserve more workspace credits to continue with the same team."; wrapMode: Text.Wrap; font.pixelSize: 10; color: Theme.secondary }
            RowLayout {
                Layout.fillWidth: true; spacing: 6
                MokaidButton { objectName: "runtimeBudget500"; Layout.fillWidth: true; implicitHeight: 32; font.pixelSize: 10; text: (root.budgetError && root.budgetRetryCredits === 500 ? "Retry " : "") + "+500 credits"; enabled: root.canExtendBudget && !root.extendingBudget && !root.budgetIncreased && (root.budgetRetryCredits === 0 || root.budgetRetryCredits === 500); onClicked: root.extendBudgetRequested(500) }
                MokaidButton { objectName: "runtimeBudget2000"; Layout.fillWidth: true; implicitHeight: 32; font.pixelSize: 10; text: (root.budgetError && root.budgetRetryCredits === 2000 ? "Retry " : "") + "+2,000 credits"; enabled: root.canExtendBudget && !root.extendingBudget && !root.budgetIncreased && (root.budgetRetryCredits === 0 || root.budgetRetryCredits === 2000); onClicked: root.extendBudgetRequested(2000) }
            }
            MokaidLabel { Layout.fillWidth: true; visible: root.extendingBudget || root.budgetIncreased; text: root.budgetIncreased ? "Budget increased. The mission is resuming." : "Updating the mission budget…"; wrapMode: Text.Wrap; font.pixelSize: 10; color: Theme.secondary }
            MokaidLabel { Layout.fillWidth: true; visible: root.budgetError.length > 0; text: root.budgetError + " Retry the same amount to check this request without reserving it twice."; textFormat: Text.PlainText; wrapMode: Text.Wrap; font.pixelSize: 10; color: Theme.danger }
        }
        Repeater {
            model: root.participants
            ColumnLayout {
                id: participant
                required property var modelData
                Layout.fillWidth: true; spacing: 4
                RowLayout {
                    Layout.fillWidth: true
                    MokaidLabel { Layout.fillWidth: true; text: participant.modelData.name || "Teammate"; textFormat: Text.PlainText; font.pixelSize: 11; font.weight: Font.DemiBold; elide: Text.ElideRight }
                    MokaidLabel { text: Logic.runtimeStatus(participant.modelData.status); textFormat: Text.PlainText; font.pixelSize: 10; color: Theme.muted }
                }
                MokaidLabel { visible: !!participant.modelData.assignment; Layout.fillWidth: true; text: participant.modelData.assignment || ""; textFormat: Text.PlainText; font.pixelSize: 11; color: Theme.secondary; wrapMode: Text.Wrap }
                MokaidLabel { readonly property int count: root.sequence(participant.modelData.artifacts).length; visible: count > 0; text: count + (count === 1 ? " deliverable" : " deliverables"); font.pixelSize: 10; color: Theme.muted }
            }
        }
        ColumnLayout {
            visible: !!root.runtime.budget; Layout.fillWidth: true; spacing: 4
            MokaidLabel { text: "Mission credits"; font.pixelSize: 11; font.weight: Font.DemiBold }
            Repeater {
                model: [{label:"Allowance", key:"limit_credits"}, {label:"Reserved", key:"reserved_credits"}, {label:(root.runtime.budget || {}).estimated ? "Estimated used" : "Used", key:"used_credits"}, {label:"Remaining", key:"remaining_credits"}]
                RowLayout {
                    id: budgetRow
                    required property var modelData
                    Layout.fillWidth: true
                    MokaidLabel { Layout.fillWidth: true; text: budgetRow.modelData.label; font.pixelSize: 10; color: Theme.muted }
                    MokaidLabel { objectName: "taskRuntimeCredit_" + budgetRow.modelData.key; text: Logic.runtimeCredits((root.runtime.budget || {})[budgetRow.modelData.key]); font.pixelSize: 10; color: Theme.secondary }
                }
            }
        }
        ColumnLayout {
            visible: !!root.runtime.verification; Layout.fillWidth: true; spacing: 4
            MokaidLabel { Layout.fillWidth: true; wrapMode: Text.Wrap; text: root.checks.length > 0 && (root.runtime.verification || {}).passed === true ? "Delivery checks passed" : (root.runtime.verification || {}).passed === false ? "Delivery needs checking" : "Delivery checks pending"; font.pixelSize: 11; font.weight: Font.DemiBold }
            Repeater {
                model: root.checks
                MokaidLabel {
                    required property var modelData
                    Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 10; color: Theme.secondary; textFormat: Text.PlainText
                    text: typeof modelData === "string" ? modelData : (modelData.passed === true ? "✓ " : "○ ") + (modelData.name || "Check") + (modelData.message ? " — " + modelData.message : "")
                }
            }
        }
        ColumnLayout {
            visible: root.limitations.length > 0; Layout.fillWidth: true; spacing: 4
            MokaidLabel { text: "Limitations"; font.pixelSize: 11; font.weight: Font.DemiBold; color: Theme.warning }
            Repeater { model: root.limitations; MokaidLabel { required property var modelData; Layout.fillWidth: true; text: String(modelData); textFormat: Text.PlainText; wrapMode: Text.Wrap; font.pixelSize: 10; color: Theme.secondary } }
        }
        MokaidButton { visible: root.fileCount > 0; Layout.fillWidth: true; text: "Consolidated deliverables · " + root.fileCount; implicitHeight: 32; font.pixelSize: 10; onClicked: root.filesRequested() }
    }
}
