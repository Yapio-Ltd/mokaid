import QtQuick
import QtQuick.Controls
import QtWebEngine
import Mokaid.Native 1.0

ApplicationWindow {
    id: window
    width: 1240; height: 800; visible: true
    title: "Mokaid — native graphics integration probe (test only)"
    color: Theme.background
    property int phase: 0
    property bool pending: false
    property var browser: null
    property bool sceneShown: true
    property bool scenePaused: false
    property real pausedFrameStart: 0
    property real phaseStarted: Date.now()
    function next(value) { phase = value; phaseStarted = Date.now(); pending = false }
    function assertCheck(name, value) {
        if (!probe.check(name, value)) { steps.stop(); warmup.stop(); measurement.stop(); return false }
        return true
    }
    function evaluate(source, callback) {
        pending = true
        browser.runJavaScript(source, 0, function(value) { pending = false; callback(value) })
    }
    header: Rectangle {
        height: 62; color: Theme.surface
        Label { anchors.centerIn: parent; text: "GRAPHICS PROBE  •  real cooked scene + protected HTML fixture  •  not product acceptance"; color: Theme.text }
        Rectangle {
            anchors.bottom: parent.bottom; width: parent.width; height: 3; color: Theme.primary
            visible: window.phase === 4
            SequentialAnimation on opacity {
                running: window.phase === 4; loops: Animation.Infinite
                NumberAnimation { from: 0.2; to: 1; duration: 100 }
                NumberAnimation { from: 1; to: 0.2; duration: 100 }
            }
        }
    }
    NativeViewport {
        id: office; objectName: "probeNativeViewport"
        x: 0; y: 0; width: parent.width * 0.61; height: parent.height
        assetRoot: probe.assetRoot; agents: probe.fixtureAgents
        visible: window.sceneShown; paused: window.scenePaused || !window.sceneShown; quality: "auto"
        onErrorChanged: { if (error.length) probe.fail("Native renderer: " + error) }
    }
    Label {
        anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 16
        color: Theme.text; text: office.loading ? "Loading real office assets…" : "Phase " + window.phase + " · draws " + (office.diagnostics.drawCalls || 0)
    }
    DeliveryView {
        id: delivery; objectName: "probeProductionDelivery"
        x: parent.width * 0.61; y: 0; width: parent.width * 0.39; height: parent.height
        document: probe.document
        onFailureChanged: { if (failure.length) probe.fail("Production preview: " + failure) }
    }
    Timer {
        id: steps; interval: 100; repeat: true; running: true
        onTriggered: {
            if (window.pending) return
            if (!window.browser) {
                // Use the real WebEngineView's public automation API without
                // modifying DeliveryView or exposing a production native bridge.
                for (let child of delivery.children)
                    if (typeof child.runJavaScript === "function") { window.browser = child; break }
                if (!window.browser) return
            }
            if (window.browser.loading || office.loading) return
            if (window.phase === 0) {
                if (!(office.diagnostics.triangles > 0)) return
                window.evaluate("JSON.stringify(globalThis.__probeState || {})", function(value) {
                    const state = JSON.parse(value || "{}")
                    if (!state.ready || state.fileBlocked === null || state.apiBlocked === null) return
                    if (!window.assertCheck("native-scene-has-triangles", office.diagnostics.triangles > 0)
                        || !window.assertCheck("html-javascript-executes", state.ready === true)
                        || !window.assertCheck("html-file-fetch-denied", state.fileBlocked === true)
                        || !window.assertCheck("html-api-fetch-denied", state.apiBlocked === true)
                        || !window.assertCheck("html-api-blocked-by-csp-not-dns", state.apiCspBlocked === true)
                        || !window.assertCheck("preview-is-off-the-record", probe.document.profile.offTheRecord)) return
                    window.next(1)
                })
            } else if (window.phase === 1) {
                window.pending = true
                delivery.inspectActivity(function(dirty) {
                    if (window.assertCheck("untouched-document-is-clean", dirty === false)) window.next(2)
                })
            } else if (window.phase === 2) {
                window.evaluate("document.querySelector('#draft').value='Persistent probe draft'; document.querySelector('#draft').dispatchEvent(new Event('input',{bubbles:true})); document.querySelector('#action').click(); globalThis.__mokaidActivity={dirty:false}; JSON.stringify(globalThis.__probeState)", function(value) {
                    if (window.assertCheck("html-button-handler-executes", JSON.parse(value).clicks === 1)) window.next(3)
                })
            } else if (window.phase === 3) {
                window.pending = true
                delivery.inspectActivity(function(dirty) {
                    if (!window.assertCheck("isolated-dirty-guard-resists-main-world-reset", dirty === true)) return
                    delivery.active = false; window.scenePaused = true
                    window.pausedFrameStart = probe.composedFrames()
                    window.next(4)
                })
            } else if (window.phase === 4 && Date.now() - window.phaseStarted > 750) {
                if (!window.assertCheck("hidden-dirty-preview-remains-active", delivery.dirty && window.browser.lifecycleState === WebEngineView.LifecycleState.Active)) return
                if (!window.assertCheck("paused-image-composes-with-qml-animation", office.paused && office.visible && probe.composedFrames() - window.pausedFrameStart >= 3)) return
                window.sceneShown = false; window.width = 980; window.height = 680
                window.next(5)
            } else if (window.phase === 5 && Date.now() - window.phaseStarted > 750) {
                window.sceneShown = true; window.scenePaused = false; delivery.active = true
                window.width = 1320; window.height = 840
                window.next(6)
            } else if (window.phase === 6 && Date.now() - window.phaseStarted > 1500) {
                window.evaluate("document.querySelector('#draft').value", function(value) {
                    if (!window.assertCheck("draft-survives-hide-show-and-resize", value === "Persistent probe draft")) return
                    window.next(7); steps.stop(); warmup.start()
                })
            }
        }
    }
    Timer {
        id: warmup; interval: 5000
        onTriggered: {
            if (!window.assertCheck("native-renderer-recovers-after-resize", office.error === "" && office.diagnostics.drawCalls > 0)) return
            window.next(8); probe.beginMeasurements(); measurement.start()
        }
    }
    Timer {
        id: measurement; interval: 10000
        onTriggered: {
            window.next(9)
            probe.finish(office.diagnostics)
        }
    }
}
