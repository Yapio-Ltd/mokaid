import QtQuick
import QtQuick.Controls
import QtWebEngine

Item {
    id: root
    required property var document
    property bool active: true
    property bool dirty: false
    property bool probing: false
    property string failure: ""
    readonly property bool canGoBack: web.canGoBack
    function goBack() { web.goBack() }
    function reload() { root.failure = ""; web.reload() }
    function inspectActivity(callback) {
        if (root.failure || web.loading || web.recentlyAudible) { callback(true); return }
        root.probing = true
        web.runJavaScript("globalThis.__mokaidActivity ? globalThis.__mokaidActivity.dirty : true", 1, function(value) {
            root.dirty = value !== false
            root.probing = false
            callback(root.dirty || web.recentlyAudible)
        })
    }
    onActiveChanged: {
        if (!active) inspectActivity(function(protectedWork) { root.dirty = protectedWork })
    }
    WebEngineView {
        id: web; anchors.fill: parent
        profile: root.document.profile
        Component.onCompleted: { userScripts.collection = root.document.scripts; url = root.document.url }
        visible: root.active; backgroundColor: "white"
        lifecycleState: root.active || root.dirty || root.probing || recentlyAudible ? WebEngineView.LifecycleState.Active : recommendedState === WebEngineView.LifecycleState.Discarded ? WebEngineView.LifecycleState.Frozen : recommendedState
        settings.localContentCanAccessFileUrls: false
        settings.localContentCanAccessRemoteUrls: false
        settings.allowRunningInsecureContent: false
        settings.javascriptCanAccessClipboard: false
        settings.javascriptCanPaste: false
        settings.screenCaptureEnabled: false
        settings.fullScreenSupportEnabled: false
        settings.errorPageEnabled: false
        onPermissionRequested: function(permission) { permission.deny() }
        onFileDialogRequested: function(request) { request.accepted = true; request.dialogReject() }
        onAuthenticationDialogRequested: function(request) { request.accepted = true; request.dialogReject() }
        onRegisterProtocolHandlerRequested: function(request) { request.reject() }
        onCertificateError: function(error) { error.rejectCertificate() }
        onFullScreenRequested: function(request) { request.reject() }
        onNewWindowRequested: function(request) {
            if (request.userInitiated) preview.openExternal(request.requestedUrl)
        }
        onNavigationRequested: function(request) {
            if (root.document.internal(request.url)) { request.accept(); return }
            request.reject()
            if (request.isMainFrame && request.navigationType === WebEngineNavigationRequest.LinkClickedNavigation)
                preview.openExternal(request.url)
        }
        onLoadingChanged: function(info) {
            if (info.status === WebEngineView.LoadFailedStatus) root.failure = "The deliverable could not be loaded."
            if (info.status === WebEngineView.LoadSucceededStatus) root.failure = ""
        }
        onRenderProcessTerminated: function(status, exitCode) {
            root.failure = "The HTML renderer stopped. Reload to recover. Unsaved entries in this view may have been lost."
        }
        onJavaScriptConsoleMessage: function(level, message, lineNumber, sourceID) {
            // Untrusted document contents and URLs are intentionally not sent to application logs.
        }
        Accessible.name: root.document.title
    }
    BusyIndicator { anchors.centerIn: parent; running: web.loading && root.active; visible: running }
    Rectangle {
        anchors.fill: parent; color: Theme.surface; visible: root.failure.length > 0
        Column {
            anchors.centerIn: parent; width: Math.min(parent.width - 60, 440); spacing: 16
            MokaidLabel { width: parent.width; text: root.failure; color: Theme.secondary; wrapMode: Text.Wrap }
            MokaidButton { text: "Reload deliverable"; onClicked: root.reload() }
        }
    }
}
