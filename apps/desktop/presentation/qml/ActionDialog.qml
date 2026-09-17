import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

Dialog {
    id: dialog
    anchors.centerIn: parent; width: Math.min(parent.width - 48, agentCreation ? 720 : 660); height: Math.min(parent.height - 48, content.implicitHeight + (agentCreation ? 200 : 150))
    modal: true; closePolicy: Popup.NoAutoClose
    title: agentCreation ? "Make it yours" : action.title || "Action"
    padding: 24
    background: Rectangle {
        radius: Theme.radiusDialog; border.color: Theme.selectedBorder
        gradient: Gradient { GradientStop { position: 0; color: Theme.panelTop } GradientStop { position: 1; color: Theme.panelBottom } }
    }
    header: ColumnLayout {
        spacing: 5
        MokaidLabel { Layout.fillWidth: true; text: dialog.title; font.pixelSize: 21; font.weight: Font.DemiBold; leftPadding: 24; rightPadding: 24; topPadding: 20; bottomPadding: dialog.agentCreation ? 0 : 8; wrapMode: Text.Wrap }
        MokaidLabel { visible: dialog.agentCreation; Layout.fillWidth: true; text: "Step 2 of 2 · " + (dialog.action.specialization ? dialog.action.specialization.name : "Your new teammate"); color: Theme.secondary; font.pixelSize: 12; leftPadding: 24; rightPadding: 24; bottomPadding: 10; wrapMode: Text.Wrap }
    }
    property var action: ({})
    property var fields: []
    property var values: ({})
    property bool pending: false
    property string contextToken: ""
    property bool contextExpired: false
    property string contextError: ""
    property bool advancedExpanded: false
    readonly property bool agentCreation: action.id === "create" && fields.some(function(field) { return field.key === "archetype_key" })
    readonly property bool creationReady: !agentCreation || (String(values.display_name || "").trim().length > 0 && String(values.archetype_key || "").trim().length > 0)
    function advancedField(field) {
        if (agentCreation) return ["display_name", "instructions", "autonomy_mode", "model_quality"].indexOf(field.key) < 0 && !(field.required && (values[field.key] === undefined || values[field.key] === null || values[field.key] === ""))
        const keys = ["avatar_asset_id", "archetype_key", "boost_key", "linked_user_id", "linked_member_id", "assigned_agent_id", "agent_id", "project_id", "parent_id", "role_id", "team_id", "settings", "feature_toggles", "usage_limits", "tool_preferences"]
        // Required values without a preset stay visible and cannot be missed.
        return keys.indexOf(field.key) >= 0 && !(field.required && (field.value === undefined || field.value === null || field.value === ""))
    }
    readonly property bool hasAdvancedFields: fields.some(function(field) { return dialog.advancedField(field) })
    function fieldHint(key) {
        if (key === "instructions") return "Describe its responsibilities, the result you expect, and any boundaries."
        if (key === "autonomy_mode") return agentCreation ? (values.autonomy_mode === "supervised" ? "Checks with you before taking action." : values.autonomy_mode === "autonomous" ? "Works independently within its permissions." : "Works independently with safeguards for sensitive actions.") : "Supervised asks for approval. Balanced uses safeguards. Autonomous works independently."
        if (key === "model_quality") return "Smart prioritizes complex reasoning; Fast prioritizes quick responses."
        if (key === "knowledge_brief") return "Add useful context: your business, audience, terminology or preferred approach."
        if (key === "due_at") return "Include a time zone, for example 2026-09-17T09:00:00+03:00."
        return ""
    }
    function fieldLabel(field) {
        if (!agentCreation) return field.label
        const labels = { display_name: "Agent name", instructions: "What should this teammate help you with?", autonomy_mode: "Working style", model_quality: "Thinking style", kind: "Agent type", knowledge_brief: "Background knowledge" }
        return labels[field.key] || field.label
    }
    function choiceLabel(key, value) {
        const labels = { supervised: "Check with me", balanced: "Balanced", autonomous: "Independent", fast: "Fast", smart: "Smart" }
        return labels[value] || value
    }
    onClosed: { fields = []; values = {}; contextToken = "" }
    function validateContext() {
        if (contextExpired) return false
        if (contextToken !== features.actionContext(action.id)) {
            contextExpired = true; pending = false
            contextError = "The account, workspace, folder or selection changed. This form can no longer be submitted. Close it and reopen the action."
            fields = []; values = {}; action = ({ title: "Action unavailable" })
            filePicker.close()
            return false
        }
        return true
    }
    function setValue(key, value) {
        if (values[key] === value) return
        const next = Object.assign({}, values); next[key] = value; values = next
    }
    function editorText(key, multiline) {
        const value = values[key]
        if (value === undefined || value === null) return ""
        return multiline && typeof value === "object" ? JSON.stringify(value, null, 2) : String(value)
    }
    function setEditorText(key, text, multiline) {
        // Accessibility value updates need not emit textEdited or take focus.
        // Ignore model-driven changes so prefilled JSON retains its typed value
        // and the text binding cannot feed back into itself.
        if (text !== editorText(key, multiline)) setValue(key, text)
    }
    function showAction(next) {
        if (!next.enabled) return
        action = next; fields = features.fieldsForAction(next.id); advancedExpanded = false
        contextToken = features.actionContext(next.id); contextExpired = false; contextError = ""
        if (fields.length === 0 && !next.destructive) { features.submit(next.id, { _context: contextToken }); return }
        const initial = {}
        for (const field of fields) {
            if (field.value !== undefined && field.value !== null) initial[field.key] = field.value
            else if (field.type === "bool") initial[field.key] = false
        }
        if (agentCreation) {
            initial.autonomy_mode = "balanced"; initial.model_quality = "smart"
            if (next.specialization) {
                if (next.specialization.role_title) initial.role_title = next.specialization.role_title
                if (next.specialization.department) initial.department = next.specialization.department
            }
        }
        values = initial; confirmation.checked = false; pending = false; open()
    }
    Connections {
        target: features
        function onChanged() {
            if (dialog.opened && !dialog.validateContext()) return
            if (dialog.pending && !features.busy) {
                dialog.pending = false
            }
        }
        function onActionSucceeded(context) {
            if (!dialog.contextExpired && dialog.contextToken === context) {
                const showTeam = dialog.agentCreation && features.currentPage === "agent-new"
                dialog.pending = false; dialog.close()
                if (showTeam) features.navigate("agents")
            }
        }
    }
    contentItem: ScrollView {
        contentWidth: availableWidth
        ColumnLayout {
            id: content; width: parent.width; spacing: dialog.agentCreation ? 16 : 20
            MokaidLabel { Layout.fillWidth: true; visible: dialog.action.destructive || false; text: dialog.action.confirmation || ""; wrapMode: Text.Wrap; color: Theme.warning }
            Repeater {
                model: dialog.fields
                ColumnLayout {
                    id: fieldRow
                    required property var modelData
                    visible: dialog.advancedExpanded || !dialog.advancedField(modelData)
                    Layout.fillWidth: true; spacing: 8
                    MokaidLabel { Layout.fillWidth: true; text: dialog.fieldLabel(fieldRow.modelData) + (fieldRow.modelData.required ? " *" : ""); color: Theme.secondary; font.pixelSize: 12; font.weight: Font.Medium; wrapMode: Text.Wrap }
                    Loader {
                        Layout.fillWidth: true
                        sourceComponent: dialog.agentCreation && ["autonomy_mode", "model_quality"].indexOf(fieldRow.modelData.key) >= 0 ? choiceEditor : fieldRow.modelData.type === "bool" ? boolEditor : fieldRow.modelData.type === "enum" ? enumEditor : fieldRow.modelData.type === "files" ? filesEditor : fieldRow.modelData.type === "multiline" || fieldRow.modelData.type === "json" ? multilineEditor : textEditor
                        Component {
                            id: textEditor
                            MokaidTextField {
                                objectName: dialog.agentCreation && fieldRow.modelData.key === "display_name" ? "creationNameField" : "actionField_" + fieldRow.modelData.key
                                text: dialog.editorText(fieldRow.modelData.key, false)
                                echoMode: fieldRow.modelData.type === "password" ? TextInput.Password : TextInput.Normal
                                placeholderText: fieldRow.modelData.type === "datetime" ? "2026-09-13T09:00:00Z" : dialog.agentCreation && fieldRow.modelData.key === "display_name" ? "Choose a name for your teammate" : ""
                                inputMethodHints: fieldRow.modelData.type === "password" ? Qt.ImhSensitiveData | Qt.ImhNoPredictiveText : Qt.ImhNone
                                Accessible.name: dialog.fieldLabel(fieldRow.modelData)
                                onTextChanged: dialog.setEditorText(fieldRow.modelData.key, text, false)
                                Component.onCompleted: if (dialog.agentCreation && fieldRow.modelData.key === "display_name") forceActiveFocus()
                            }
                        }
                        Component {
                            id: multilineEditor
                            ScrollView {
                                implicitHeight: dialog.agentCreation ? 88 : 128
                                MokaidTextArea {
                                    objectName: "actionField_" + fieldRow.modelData.key
                                    text: dialog.editorText(fieldRow.modelData.key, true)
                                    placeholderText: dialog.agentCreation && fieldRow.modelData.key === "instructions" ? "Give it a clear mission, such as preparing a weekly research brief…" : ""
                                    wrapMode: TextEdit.Wrap; selectByMouse: true; Accessible.name: dialog.fieldLabel(fieldRow.modelData)
                                    onTextChanged: dialog.setEditorText(fieldRow.modelData.key, text, true)
                                }
                            }
                        }
                        Component {
                            id: choiceEditor
                            RowLayout {
                                spacing: 8
                                Repeater {
                                    model: fieldRow.modelData.options
                                    MokaidButton {
                                        required property string modelData
                                        objectName: "creationChoice_" + fieldRow.modelData.key + "_" + modelData
                                        Layout.fillWidth: true; Layout.minimumWidth: 0
                                        text: dialog.choiceLabel(fieldRow.modelData.key, modelData)
                                        highlighted: dialog.values[fieldRow.modelData.key] === modelData
                                        Accessible.name: dialog.fieldLabel(fieldRow.modelData) + ": " + text
                                        Accessible.description: highlighted ? "Selected" : ""
                                        onClicked: dialog.setValue(fieldRow.modelData.key, modelData)
                                    }
                                }
                            }
                        }
                        Component {
                            id: boolEditor
                            CheckBox { checked: dialog.values[fieldRow.modelData.key] === true; text: fieldRow.modelData.label; font.family: Theme.fontFamily; font.pixelSize: 13; palette.windowText: Theme.text; palette.highlight: Theme.primary; onToggled: dialog.setValue(fieldRow.modelData.key, checked) }
                        }
                        Component {
                            id: enumEditor
                            MokaidComboBox {
                                model: fieldRow.modelData.options; currentIndex: model.indexOf(dialog.values[fieldRow.modelData.key])
                                displayText: currentIndex < 0 ? "Select…" : currentText
                                Accessible.name: fieldRow.modelData.label
                                onActivated: dialog.setValue(fieldRow.modelData.key, currentText)
                            }
                        }
                        Component {
                            id: filesEditor
                            MokaidButton {
                                iconName: "folder"
                                text: dialog.values[fieldRow.modelData.key] ? dialog.values[fieldRow.modelData.key].length + " file(s) selected" : "Choose files…"
                                onClicked: { filePicker.fieldKey = fieldRow.modelData.key; filePicker.open() }
                            }
                        }
                    }
                    MokaidLabel { Layout.fillWidth: true; visible: text.length > 0; text: dialog.fieldHint(fieldRow.modelData.key); color: Theme.muted; font.pixelSize: 11; wrapMode: Text.Wrap }
                }
            }
            MokaidButton {
                objectName: "actionOptionalSettings"
                visible: dialog.hasAdvancedFields
                text: dialog.advancedExpanded ? "Hide optional settings" : dialog.agentCreation ? "Optional settings" : "Advanced options"
                iconName: dialog.advancedExpanded ? "chevron-up" : "chevron-down"
                quiet: true
                onClicked: dialog.advancedExpanded = !dialog.advancedExpanded
            }
            CheckBox { id: confirmation; visible: dialog.action.destructive || false; text: "I confirm this action on the selected record."; font.family: Theme.fontFamily; font.pixelSize: 13; palette.windowText: Theme.text; palette.highlight: Theme.primary }
            MokaidLabel { Layout.fillWidth: true; visible: dialog.contextError.length > 0; text: dialog.contextError; color: Theme.danger; wrapMode: Text.Wrap }
            MokaidLabel { Layout.fillWidth: true; visible: features.error.length > 0; text: features.error; color: Theme.danger; wrapMode: Text.Wrap }
        }
    }
    footer: Item {
        implicitHeight: 80
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 24; anchors.rightMargin: 24; anchors.topMargin: 12; anchors.bottomMargin: 24; spacing: 10
            Item { Layout.fillWidth: true }
            MokaidButton { objectName: "actionCancel"; text: dialog.contextExpired ? "Close" : "Cancel"; enabled: dialog.contextExpired || !features.busy; onClicked: dialog.close() }
            MokaidButton {
                objectName: dialog.agentCreation ? "creationSubmit" : "actionSubmit"
                text: features.busy ? "Working…" : dialog.agentCreation ? "Add to my team" : dialog.action.title || "Save"; highlighted: true
                enabled: !dialog.contextExpired && !features.busy && dialog.creationReady && (!dialog.action.destructive || confirmation.checked)
                onClicked: {
                    if (!dialog.validateContext()) return
                    const payload = Object.assign({}, dialog.values)
                    payload._confirmed = confirmation.checked
                    payload._context = dialog.contextToken
                    dialog.pending = true; features.submit(dialog.action.id, payload)
                    if (!features.busy) dialog.pending = false
                }
            }
        }
    }
    FileDialog { id: filePicker; property string fieldKey; fileMode: FileDialog.OpenFiles; onAccepted: { if (dialog.validateContext()) dialog.setValue(fieldKey, selectedFiles) } }
}
