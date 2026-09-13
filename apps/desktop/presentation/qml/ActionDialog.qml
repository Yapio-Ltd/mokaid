import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

Dialog {
    id: dialog
    anchors.centerIn: parent; width: Math.min(parent.width - 100, 610); height: Math.min(parent.height - 80, content.implicitHeight + 150)
    modal: true; closePolicy: Popup.NoAutoClose
    title: action.title || "Action"
    property var action: ({})
    property var fields: []
    property var values: ({})
    property bool pending: false
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
        action = next; fields = features.fieldsForAction(next.id)
        if (fields.length === 0 && !next.destructive) { features.submit(next.id, {}); return }
        const initial = {}
        for (const field of fields) {
            if (field.value !== undefined && field.value !== null) initial[field.key] = field.value
            else if (field.type === "bool") initial[field.key] = false
        }
        values = initial; confirmation.checked = false; pending = false; open()
    }
    Connections {
        target: features
        function onChanged() {
            if (dialog.pending && !features.busy) {
                dialog.pending = false
                if (!features.error) dialog.close()
            }
        }
    }
    contentItem: ScrollView {
        contentWidth: availableWidth
        ColumnLayout {
            id: content; width: parent.width; spacing: 16
            MokaidLabel { Layout.fillWidth: true; visible: dialog.action.destructive || false; text: dialog.action.confirmation || ""; wrapMode: Text.Wrap; color: Theme.warning }
            Repeater {
                model: dialog.fields
                ColumnLayout {
                    id: fieldRow
                    required property var modelData
                    Layout.fillWidth: true; spacing: 6
                    MokaidLabel { text: fieldRow.modelData.label + (fieldRow.modelData.required ? " *" : ""); color: Theme.secondary; font.pixelSize: 12 }
                    Loader {
                        Layout.fillWidth: true
                        sourceComponent: fieldRow.modelData.type === "bool" ? boolEditor : fieldRow.modelData.type === "enum" ? enumEditor : fieldRow.modelData.type === "files" ? filesEditor : fieldRow.modelData.type === "multiline" || fieldRow.modelData.type === "json" ? multilineEditor : textEditor
                        Component {
                            id: textEditor
                            MokaidTextField {
                                text: dialog.editorText(fieldRow.modelData.key, false)
                                echoMode: fieldRow.modelData.type === "password" ? TextInput.Password : TextInput.Normal
                                placeholderText: fieldRow.modelData.type === "datetime" ? "2026-09-13T09:00:00Z" : ""
                                inputMethodHints: fieldRow.modelData.type === "password" ? Qt.ImhSensitiveData | Qt.ImhNoPredictiveText : Qt.ImhNone
                                Accessible.name: fieldRow.modelData.label
                                onTextChanged: dialog.setEditorText(fieldRow.modelData.key, text, false)
                            }
                        }
                        Component {
                            id: multilineEditor
                            ScrollView {
                                implicitHeight: 110
                                MokaidTextArea {
                                    text: dialog.editorText(fieldRow.modelData.key, true)
                                    wrapMode: TextEdit.Wrap; selectByMouse: true; Accessible.name: fieldRow.modelData.label
                                    onTextChanged: dialog.setEditorText(fieldRow.modelData.key, text, true)
                                }
                            }
                        }
                        Component {
                            id: boolEditor
                            CheckBox { checked: dialog.values[fieldRow.modelData.key] === true; text: fieldRow.modelData.label; onToggled: dialog.setValue(fieldRow.modelData.key, checked) }
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
                                text: dialog.values[fieldRow.modelData.key] ? dialog.values[fieldRow.modelData.key].length + " file(s) selected" : "Choose files…"
                                onClicked: { filePicker.fieldKey = fieldRow.modelData.key; filePicker.open() }
                            }
                        }
                    }
                }
            }
            CheckBox { id: confirmation; visible: dialog.action.destructive || false; text: "I confirm this action on the selected record." }
            MokaidLabel { Layout.fillWidth: true; visible: features.error.length > 0; text: features.error; color: Theme.danger; wrapMode: Text.Wrap }
        }
    }
    footer: DialogButtonBox {
        MokaidButton { text: "Cancel"; DialogButtonBox.buttonRole: DialogButtonBox.RejectRole; enabled: !features.busy; onClicked: dialog.close() }
        MokaidButton {
            text: features.busy ? "Working…" : dialog.action.title || "Save"; highlighted: true
            enabled: !features.busy && (!dialog.action.destructive || confirmation.checked)
            onClicked: {
                const payload = Object.assign({}, dialog.values)
                payload._confirmed = confirmation.checked
                dialog.pending = true; features.submit(dialog.action.id, payload)
                if (!features.busy) dialog.pending = false
            }
        }
    }
    FileDialog { id: filePicker; property string fieldKey; fileMode: FileDialog.OpenFiles; onAccepted: dialog.setValue(fieldKey, selectedFiles) }
}
