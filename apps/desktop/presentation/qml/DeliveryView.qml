import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtWebEngine

Item {
    id: root
    required property var document
    property bool active: true
    property bool dirty: false
    property bool probing: false
    property string failure: ""
    readonly property string kind: document ? document.kind : "unsupported"
    readonly property bool canGoBack: !!webLoader.item && webLoader.item.canGoBack
    function goBack() { if (webLoader.item) webLoader.item.goBack() }
    function reload() {
        root.failure = ""
        if (webLoader.item) webLoader.item.reload()
    }
    function inspectActivity(callback) {
        if (!webLoader.item || kind !== "html") { callback(false); return }
        const web = webLoader.item
        if (web.loading || web.recentlyAudible) { callback(true); return }
        root.probing = true
        web.runJavaScript("globalThis.__mokaidActivity ? globalThis.__mokaidActivity.dirty : true", 1, function(value) {
            root.dirty = value !== false
            root.probing = false
            callback(root.dirty || web.recentlyAudible)
        })
    }
    onActiveChanged: if (!active) inspectActivity(function(protectedWork) { root.dirty = protectedWork })

    Rectangle { anchors.fill: parent; color: Theme.background }
    Item {
        id: imageStage
        anchors.fill: parent
        visible: root.kind === "image"
        property real zoom: 1
        function setZoom(value) {
            zoom = Math.max(1, Math.min(8, value))
            imageScroll.contentX = Math.max(0, (imageScroll.contentWidth - imageScroll.width) / 2)
            imageScroll.contentY = Math.max(0, (imageScroll.contentHeight - imageScroll.height) / 2)
        }
        Flickable {
            id: imageScroll
            anchors.fill: parent; anchors.margins: 24; anchors.bottomMargin: 86
            clip: true; boundsBehavior: Flickable.StopAtBounds
            contentWidth: width * imageStage.zoom; contentHeight: height * imageStage.zoom
            interactive: imageStage.zoom > 1
            Image {
                id: picture
                objectName: "deliverableImage"
                width: imageScroll.contentWidth; height: imageScroll.contentHeight
                source: root.kind === "image" ? root.document.imageSource : ""
                asynchronous: true; cache: false; fillMode: Image.PreserveAspectFit
                Accessible.role: Accessible.Graphic
                Accessible.name: root.document ? root.document.title : "Image"
            }
            ScrollBar.vertical: ScrollBar { policy: imageStage.zoom > 1 ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }
            ScrollBar.horizontal: ScrollBar { policy: imageStage.zoom > 1 ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }
            TapHandler { onDoubleTapped: imageStage.setZoom(imageStage.zoom > 1 ? 1 : 2) }
            WheelHandler {
                acceptedModifiers: Qt.ControlModifier
                onWheel: function(event) { imageStage.setZoom(imageStage.zoom * (event.angleDelta.y > 0 ? 1.2 : 1 / 1.2)) }
            }
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom; anchors.bottomMargin: 22
            width: imageControls.implicitWidth + 12; height: 48; radius: 14; color: Theme.surface; border.color: Theme.divider
            RowLayout {
                id: imageControls; anchors.centerIn: parent; spacing: 3
                MokaidButton { iconName: "minus"; quiet: true; enabled: imageStage.zoom > 1; Accessible.name: "Zoom out"; onClicked: imageStage.setZoom(imageStage.zoom / 1.5) }
                MokaidLabel { Layout.preferredWidth: 52; text: imageStage.zoom === 1 ? "Fit" : imageStage.zoom.toFixed(1) + "×"; horizontalAlignment: Text.AlignHCenter; font.pixelSize: 12; Accessible.name: "Image zoom " + text }
                MokaidButton { iconName: "plus"; quiet: true; enabled: imageStage.zoom < 8; Accessible.name: "Zoom in"; onClicked: imageStage.setZoom(imageStage.zoom * 1.5) }
                Rectangle { width: 1; height: 20; color: Theme.divider }
                MokaidButton { text: "Fit"; implicitWidth: 56; quiet: true; Accessible.name: "Fit image to window"; onClicked: imageStage.setZoom(1) }
            }
        }
        BusyIndicator { anchors.centerIn: parent; running: picture.status === Image.Loading; visible: running }
        MokaidLabel { anchors.centerIn: parent; visible: picture.status === Image.Error || picture.source.toString().length === 0; text: preview.nativePreviewAvailable ? "This image cannot be displayed here. Download the original or use Quick Look from the menu." : "This image cannot be displayed here. Download the original to open it."; width: Math.min(420, parent.width - 48); wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter; color: Theme.secondary }
    }
    Loader {
        id: webLoader
        anchors.fill: parent
        active: root.kind !== "image" && root.kind !== "unsupported"
        sourceComponent: WebEngineView {
            id: web
            objectName: "deliverableWeb"
            profile: root.document.profile
            Component.onCompleted: { userScripts.collection = root.document.scripts; url = root.document.url }
            visible: root.active
            backgroundColor: root.kind === "audio" || root.kind === "video" ? Theme.background : "white"
            lifecycleState: root.active || root.dirty || root.probing || recentlyAudible ? WebEngineView.LifecycleState.Active : recommendedState === WebEngineView.LifecycleState.Discarded ? WebEngineView.LifecycleState.Frozen : recommendedState
            settings.localContentCanAccessFileUrls: false
            settings.localContentCanAccessRemoteUrls: false
            settings.allowRunningInsecureContent: false
            settings.javascriptCanAccessClipboard: false
            settings.javascriptCanPaste: false
            settings.screenCaptureEnabled: false
            settings.fullScreenSupportEnabled: false
            settings.errorPageEnabled: false
            settings.pluginsEnabled: root.kind === "pdf"
            settings.pdfViewerEnabled: true
            onPermissionRequested: function(permission) { permission.deny() }
            onFileDialogRequested: function(request) { request.accepted = true; request.dialogReject() }
            onAuthenticationDialogRequested: function(request) { request.accepted = true; request.dialogReject() }
            onRegisterProtocolHandlerRequested: function(request) { request.reject() }
            onCertificateError: function(error) { error.rejectCertificate() }
            onFullScreenRequested: function(request) { request.reject() }
            onNewWindowRequested: function(request) { if (request.userInitiated) preview.openExternal(request.requestedUrl) }
            onNavigationRequested: function(request) {
                if (root.document.internal(request.url)) { request.accept(); return }
                request.reject()
                if (request.isMainFrame && request.navigationType === WebEngineNavigationRequest.LinkClickedNavigation)
                    preview.openExternal(request.url)
            }
            onLoadingChanged: function(info) {
                if (info.status === WebEngineView.LoadFailedStatus) root.failure = "The preview could not be loaded. Try again or download the original."
                if (info.status === WebEngineView.LoadSucceededStatus) root.failure = ""
            }
            onRenderProcessTerminated: function(status, exitCode) { root.failure = "The preview stopped. Reload it to continue. Unsaved entries may have been lost." }
            onJavaScriptConsoleMessage: function(level, message, lineNumber, sourceID) {
                // Never send untrusted document contents or URLs to application logs.
            }
            Accessible.name: root.document.title
        }
    }
    BusyIndicator { anchors.centerIn: parent; running: !!webLoader.item && webLoader.item.loading && root.active; visible: running }
    ColumnLayout {
        anchors.centerIn: parent; width: Math.min(parent.width - 64, 420); spacing: 18
        visible: root.kind === "unsupported"
        MokaidIcon { name: "file"; size: 42; color: Theme.secondary; Layout.alignment: Qt.AlignHCenter; Layout.bottomMargin: 6 }
        MokaidLabel { Layout.fillWidth: true; text: root.document ? root.document.title : "Deliverable"; horizontalAlignment: Text.AlignHCenter; font.pixelSize: 21; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
        MokaidLabel { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; text: preview.nativePreviewAvailable ? "Open a native preview to explore this file, or save the original." : "Save this file to open it with an app that supports its format."; color: Theme.secondary; wrapMode: Text.Wrap }
        RowLayout {
            Layout.alignment: Qt.AlignHCenter; spacing: 10
            MokaidButton { text: "Quick Look"; iconName: "external-link"; highlighted: true; visible: preview.nativePreviewAvailable; onClicked: preview.openNativePreview() }
            MokaidButton { text: "Download"; iconName: "download"; onClicked: preview.downloadCurrent() }
        }
    }
    Rectangle {
        anchors.fill: parent; visible: root.failure.length > 0; color: Theme.background
        ColumnLayout {
            anchors.centerIn: parent; width: Math.min(parent.width - 60, 440); spacing: 18
            MokaidLabel { Layout.fillWidth: true; text: "Preview unavailable"; font.pixelSize: 21; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
            MokaidLabel { Layout.fillWidth: true; text: root.failure; color: Theme.secondary; wrapMode: Text.Wrap }
            RowLayout {
                MokaidButton { iconName: "refresh"; text: "Try again"; highlighted: true; onClicked: root.reload() }
                MokaidButton { iconName: "download"; text: "Download"; onClicked: preview.downloadCurrent() }
            }
        }
    }
}
