pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "FeatureLogic.js" as Logic

MokaidDialog {
    id: root
    objectName: "taskCompletionDialog"
    required property var controller
    property var files: []
    property var downloadManager: null
    property bool reducedMotion: false
    signal taskRequested(string taskId)
    signal previewRequested(int index)
    signal downloadRequested(var file)
    signal resultAcknowledged()
    readonly property var task: controller.completionTask || ({})
    readonly property var notification: controller.completionNotification || ({})
    readonly property bool loading: controller.completionLoading
    readonly property string failure: controller.completionError || ""
    readonly property string response: {
        const output = (task.latest_run || {}).output || {}
        if (typeof output === "string") return output
        return Logic.first(output, ["response", "text", "content", "summary"], "")
    }
    readonly property var agent: ({
        id: task.assigned_agent_id || "",
        display_name: task.assigned_agent_name || "Agent",
        kind: task.assigned_agent_avatar_cdn_path || task.assigned_agent_avatar_portrait_url || task.assigned_agent_avatar_thumbnail_url ? task.assigned_agent_kind || "ai" : "unknown",
        avatar_cdn_path: task.assigned_agent_avatar_cdn_path || "",
        avatar_portrait_url: task.assigned_agent_avatar_portrait_url || "",
        avatar_thumbnail_url: task.assigned_agent_avatar_thumbnail_url || ""
    })
    readonly property bool hasFiles: files.length > 0
    readonly property bool columns: width >= 820
    readonly property string completedTime: Logic.date((task.latest_run || {}).completed_at || task.completed_at || notification.inserted_at, true)

    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(1040, parent ? parent.width - 64 : 1040)
    height: Math.min(740, parent ? parent.height - 64 : 740)
    padding: 0
    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    title: "Task result"
    header: null
    footer: null
    background: Rectangle { color: Theme.surface; radius: 16; border.color: Theme.border }
    Overlay.modal: Rectangle { color: "#b3090b13" }
    enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: root.reducedMotion ? 0 : 180; easing.type: Easing.OutCubic } }
    exit: Transition { NumberAnimation { property: "opacity"; from: 1; to: 0; duration: root.reducedMotion ? 0 : 100 } }
    onOpened: closeButton.forceActiveFocus()
    onRejected: controller.dismissAllCompletions()
    onTaskChanged: {
        responseScroll.contentItem.contentY = 0
        filesScroll.contentItem.contentY = 0
    }

    function dismiss() { controller.dismissAllCompletions(); close() }

    contentItem: ColumnLayout {
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 28
            Layout.bottomMargin: 24
            spacing: 20
            WorkforcePortrait {
                objectName: "completionPortrait"
                agent: root.agent; size: 80
                Layout.preferredWidth: size; Layout.preferredHeight: size
                visible: !!root.task.assigned_agent_name
            }
            ColumnLayout {
                Layout.fillWidth: true; Layout.minimumWidth: 0; spacing: 9
                MokaidLabel {
                    objectName: "completionTitle"
                    Layout.fillWidth: true
                    text: root.task.title || root.notification.title || "Task complete"
                    font.pixelSize: 24; font.weight: Font.DemiBold
                    wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
                    Accessible.role: Accessible.Heading
                }
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    MokaidLabel { text: root.task.assigned_agent_name || ""; visible: text.length > 0; font.weight: Font.DemiBold; font.pixelSize: 13; elide: Text.ElideRight; Layout.maximumWidth: 220 }
                    MokaidIcon { name: "check"; color: Theme.success; size: 15; visible: !root.loading && !root.failure }
                    MokaidLabel { text: root.loading ? "Opening result…" : root.failure ? "Result unavailable" : "Work delivered"; color: root.failure ? Theme.warning : root.loading ? Theme.secondary : Theme.success; font.pixelSize: 12 }
                    Item { Layout.fillWidth: true }
                }
                MokaidLabel {
                    Layout.fillWidth: true
                    text: [root.task.project_name || "", root.completedTime].filter(function(value) { return !!value }).join(" · ")
                    visible: text.length > 0; color: Theme.muted; font.pixelSize: 11; elide: Text.ElideRight
                }
            }
            MokaidIconButton {
                id: closeButton
                objectName: "completionClose"
                Layout.alignment: Qt.AlignTop
                iconName: "close"; hint: "Close results · Esc"; subtle: true
                onClicked: root.dismiss()
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.divider }
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true
            BusyIndicator { anchors.centerIn: parent; running: root.loading; visible: running }
            ColumnLayout {
                anchors.centerIn: parent; width: Math.min(parent.width - 64, 420); spacing: 18
                visible: !root.loading && !!root.failure
                MokaidLabel { Layout.fillWidth: true; text: "The result couldn’t be loaded"; font.pixelSize: 20; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
                MokaidLabel { Layout.fillWidth: true; text: root.failure; color: Theme.secondary; wrapMode: Text.Wrap }
                MokaidButton { objectName: "completionRetry"; text: "Try again"; iconName: "refresh"; highlighted: true; onClicked: root.controller.retryCompletion() }
            }
            GridLayout {
                anchors.fill: parent
                visible: !root.loading && !root.failure
                columns: root.columns || !root.hasFiles ? 2 : 1
                columnSpacing: 0; rowSpacing: 0
                ColumnLayout {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    Layout.preferredWidth: 580
                    Layout.minimumWidth: 0
                    Layout.margins: 28
                    Layout.rightMargin: root.hasFiles && root.columns ? 24 : 28
                    spacing: 16
                    RowLayout {
                        Layout.fillWidth: true
                        MokaidLabel { text: "Agent response"; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.fillWidth: true }
                        MokaidButton {
                            objectName: "completionCopy"
                            text: "Copy"; quiet: true; implicitHeight: 32; implicitWidth: 70
                            leftPadding: 10; rightPadding: 10
                            visible: !!root.response
                            Accessible.name: "Copy agent response"
                            onClicked: { responseText.selectAll(); responseText.copy(); responseText.deselect() }
                        }
                    }
                    ScrollView {
                        id: responseScroll
                        objectName: "completionResponseScroll"
                        Layout.fillWidth: true; Layout.fillHeight: true
                        clip: true
                        contentWidth: availableWidth
                        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                        TextArea {
                            id: responseText
                            objectName: "completionResponse"
                            text: root.response || (root.hasFiles ? "The files are ready to review. This task has no written response." : "This task finished without a written response or attached files. Open the task to review its activity.")
                            textFormat: TextEdit.PlainText
                            readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap
                            padding: 0; rightPadding: 12
                            font.family: Theme.fontFamily; font.pixelSize: 14
                            color: root.response ? Theme.text : Theme.secondary
                            selectionColor: Theme.selection; selectedTextColor: Theme.text
                            background: Item {}
                            Accessible.name: "Agent response"
                        }
                    }
                }
                Rectangle {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    Layout.preferredWidth: root.columns ? 360 : 580
                    Layout.minimumWidth: 0
                    visible: root.hasFiles
                    color: Theme.deep
                    Rectangle { width: root.columns ? 1 : parent.width; height: root.columns ? parent.height : 1; color: Theme.divider }
                    ColumnLayout {
                        anchors.fill: parent; anchors.margins: 24; spacing: 18
                        RowLayout {
                            Layout.fillWidth: true
                            MokaidLabel { text: "Deliverables"; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.fillWidth: true }
                            MokaidLabel { text: root.files.length; color: Theme.secondary; font.pixelSize: 12 }
                        }
                        ScrollView {
                            id: filesScroll
                            objectName: "completionFilesScroll"
                            Layout.fillWidth: true; Layout.fillHeight: true
                            clip: true; contentWidth: availableWidth
                            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                            ColumnLayout {
                                width: filesScroll.availableWidth; spacing: 18
                                Repeater {
                                    model: root.files
                                    ColumnLayout {
                                        id: fileRow
                                        required property var modelData
                                        required property int index
                                        Layout.fillWidth: true; spacing: 8
                                        DeliveryCard {
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: imageFile ? 188 : 68
                                            file: fileRow.modelData
                                            onClicked: root.previewRequested(fileRow.index)
                                        }
                                        RowLayout {
                                            Layout.fillWidth: true; spacing: 8
                                            MokaidButton {
                                                objectName: "completionPreview_" + fileRow.index
                                                Layout.fillWidth: true
                                                text: "View"; iconName: "external-link"; implicitHeight: 38
                                                Accessible.name: "Preview " + (fileRow.modelData.name || "file")
                                                onClicked: root.previewRequested(fileRow.index)
                                            }
                                            MokaidButton {
                                                objectName: "completionDownload_" + fileRow.index
                                                Layout.fillWidth: true
                                                text: "Download"; iconName: "download"; implicitHeight: 38
                                                enabled: !root.downloadManager || (!root.downloadManager.busy && !root.downloadManager.pendingTransaction)
                                                Accessible.name: "Download " + (fileRow.modelData.name || "file")
                                                onClicked: root.downloadRequested(fileRow.modelData)
                                            }
                                        }
                                        Rectangle { Layout.fillWidth: true; Layout.topMargin: 10; implicitHeight: 1; color: Theme.divider; visible: fileRow.index < root.files.length - 1 }
                                    }
                                }
                            }
                        }
                        MokaidLabel {
                            Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 11
                            visible: text.length > 0
                            text: root.downloadManager ? root.downloadManager.error || root.downloadManager.status || "" : ""
                            color: root.downloadManager && root.downloadManager.error ? Theme.warning : Theme.secondary
                        }
                    }
                }
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.divider }
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 24; Layout.leftMargin: 28; Layout.rightMargin: 28
            spacing: 12
            MokaidLabel {
                Layout.fillWidth: true; color: Theme.muted; font.pixelSize: 11; wrapMode: Text.Wrap
                text: root.controller.pendingCompletionCount > 0 ? root.controller.pendingCompletionCount + (root.controller.pendingCompletionCount === 1 ? " more result is ready" : " more results are ready") : "Saved in your task. Come back anytime."
            }
            MokaidButton {
                objectName: "completionTask"
                text: "Open task"; iconName: "arrow-right"
                enabled: !!(root.task.id || root.notification.resource_id)
                onClicked: root.taskRequested(root.task.id || root.notification.resource_id)
            }
            MokaidButton {
                objectName: "completionNext"
                text: root.controller.pendingCompletionCount > 0 ? "Next result" : "Done"
                highlighted: true
                onClicked: { root.resultAcknowledged(); root.controller.dismissCompletion() }
            }
        }
    }
}
