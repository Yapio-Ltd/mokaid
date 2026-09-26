pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore

Item {
    id: root
    objectName: "marketplacePage"
    signal actionRequested(var action)

    property string tab: "discover"
    property string modeFilter: "all"
    property string publishAgentId: ""
    property string publishMode: "sale"
    property string publishRentBilling: "subscription"
    property int publishFixedDays: 30
    property string publishPrice: "49"
    property string publishTitle: ""
    property string publishDescription: ""
    property string connectCountry: "US"
    property var mineRows: []
    property var earningsData: ({})
    property string selectedListingId: ""
    property string screen: "browse"
    property bool publishPending: false
    property bool publishSawBusy: false
    property string queuedOfferAgent: ""
    property string queuedOfferMode: ""
    property bool offerAwaitingRows: false
    property bool sawOfferBusy: false
    property bool mineRequested: false

    property string queryText: ""
    property string categoryFilter: "all"
    property real maxPrice: 500
    property int sortOrder: 0
    property bool listView: false
    property bool savedOnly: false
    property string detailTab: "Overview"
    property var chosenListing: ({})
    property string checkoutOrderId: ""
    property bool checkoutSubmitted: false
    property var purchasedOrder: ({})
    property string purchaseNote: ""
    readonly property var savedIds: {
        try { const ids = JSON.parse(savedSettings.favoriteIds); return Array.isArray(ids) ? ids : [] }
        catch (error) { return [] }
    }
    Settings {
        id: savedSettings
        category: "marketplace/" + session.workspaceId
        property string favoriteIds: "[]"
    }
    readonly property var categories: [
        { id: "productivity", label: "Productivity", icon: "bolt", accent: "#ffb72e" },
        { id: "marketing", label: "Sales & Marketing", icon: "analytics", accent: "#00dcaf" },
        { id: "development", label: "Development", icon: "code", accent: "#6da4ff" },
        { id: "design", label: "Design", icon: "pen", accent: "#fb6aca" },
        { id: "data", label: "Data & Analytics", icon: "database", accent: "#58adff" },
        { id: "support", label: "Customer Support", icon: "headphones", accent: "#2cdeed" },
        { id: "finance", label: "Finance", icon: "dollar", accent: "#03dbcb" },
        { id: "legal", label: "Legal", icon: "shield", accent: "#ffba48" },
        { id: "hr", label: "HR & Recruitment", icon: "members", accent: "#fa56cf" },
        { id: "operations", label: "Operations", icon: "settings", accent: "#4ebcff" },
        { id: "education", label: "Education", icon: "knowledge", accent: "#9d9bff" },
        { id: "health", label: "Health & Wellness", icon: "heart", accent: "#ed62ce" }
    ]
    readonly property var listings: {
        const needle = root.queryText.trim().toLowerCase()
        let rows = (features.allRecords || []).filter(function(row) {
            if (root.modeFilter !== "all" && row.mode !== root.modeFilter) return false
            if (root.categoryFilter !== "all" && root.categoryOf(row) !== root.categoryFilter) return false
            if (root.maxPrice < 500 && Number(row.price_cents || 0) > root.maxPrice * 100) return false
            if (root.savedOnly && root.savedIds.indexOf(row.id) < 0) return false
            const agent = row.agent || ({})
            const searchable = [root.agentName(row), row.description || "", agent.role_title || "", agent.department || "", root.skillNames(agent).join(" ")].join(" ").toLowerCase()
            return !needle || searchable.indexOf(needle) >= 0
        })
        if (root.sortOrder === 1) rows.sort(function(a,b) { return Number(a.price_cents) - Number(b.price_cents) })
        else if (root.sortOrder === 2) rows.sort(function(a,b) { return Number(b.price_cents) - Number(a.price_cents) })
        else if (root.sortOrder === 3) rows.sort(function(a,b) { return root.agentName(a).localeCompare(root.agentName(b)) })
        return rows
    }
    readonly property var selectedListing: (features.allRecords || []).find(function(row) { return row.id === root.selectedListingId }) || root.chosenListing

    function categoryOf(row) {
        const a = row.agent || ({})
        const text = [a.department || "", a.role_title || "", root.skillNames(a).join(" ")].join(" ").toLowerCase()
        const rules = [
            ["legal", /legal|law|contract|compliance/], ["finance", /financ|account|bookkeep|budget/],
            ["development", /develop|software|engineer|coding|program/], ["design", /design|creative|visual/],
            ["marketing", /market|sales|growth|brand|social/], ["support", /support|customer|service/],
            ["hr", /human resource|recruit|talent|hiring/], ["education", /educat|teach|tutor|learn/],
            ["health", /health|wellness|medical|fitness/], ["data", /data|analy|research/],
            ["operations", /operat|project|supply|logistic/]
        ]
        for (let i = 0; i < rules.length; ++i) if (rules[i][1].test(text)) return rules[i][0]
        return "productivity"
    }
    function categoryCount(id) { return (features.allRecords || []).filter(function(row) { return root.categoryOf(row) === id }).length }
    function categoryName(id) { const found = categories.find(function(c) { return c.id === id }); return found ? found.label : "All agents" }
    function clearFilters() { queryText = ""; categoryFilter = "all"; modeFilter = "all"; maxPrice = 500; savedOnly = false }
    function toggleSaved(id) {
        const next = savedIds.slice(); const i = next.indexOf(id)
        if (i >= 0) next.splice(i, 1); else next.push(id)
        savedSettings.favoriteIds = JSON.stringify(next)
    }
    function showListing(id) {
        selectedListingId = id
        chosenListing = (features.allRecords || []).find(function(row) { return row.id === id }) || ({})
        detailTab = "Overview"
        screen = "detail"
    }
    function beginCheckout() {
        checkoutOrderId = ""; checkoutSubmitted = false; purchaseNote = ""; purchasedOrder = ({})
        screen = "checkout"
    }
    function refreshPurchase() {
        if (!features.busy) { purchaseNote = "Checking your payment…"; features.submit("purchases", {}) }
    }
    function showBrowse(nextTab) { screen = "browse"; tab = nextTab || "discover" }
    readonly property var sortedMineRows: {
        const rows = (root.mineRows || []).slice()
        rows.sort(function(a, b) {
            function rank(row) {
                if (row && row.listing) return 0
                if (row && row.eligible) return 1
                return 2
            }
            const order = rank(a) - rank(b)
            if (order !== 0) return order
            return Number((b && b.level) || 0) - Number((a && a.level) || 0)
        })
        return rows
    }
    readonly property var mineSummary: {
        const rows = root.mineRows || []
        let ready = 0
        let training = 0
        let live = 0
        for (let i = 0; i < rows.length; ++i) {
            const row = rows[i]
            if (row.listing) live += 1
            else if (row.eligible) ready += 1
            else training += 1
        }
        return { ready: ready, training: training, live: live, total: rows.length }
    }
    readonly property string mineHint: {
        const summary = root.mineSummary
        if (!summary.total)
            return "Create an AI agent, then train them with missions. Level " + root.minLevel + " opens the marketplace."
        if (summary.ready > 0)
            return summary.ready + (summary.ready === 1 ? " agent is ready to list." : " agents are ready to list.") + " Open Sell copies or Rent out to review the terms, then publish."
        if (summary.live > 0 && summary.training === 0)
            return "Your listings are live. Pause one anytime if you want to stop new buyers."
        return "Level " + root.minLevel + " opens the marketplace. Missions move the bar — the faces below show who is closest."
    }
    readonly property var publishRow: {
        const id = root.publishAgentId
        const rows = root.mineRows || []
        for (let i = 0; i < rows.length; ++i) {
            const row = rows[i]
            if (row && row.agent && row.agent.id === id) return row
        }
        return ({})
    }
    readonly property var publishAgent: root.mineAgent(root.publishRow)
    readonly property int feePercent: {
        const meta = root.earningsData && root.earningsData.meta
        const value = Number((root.earningsData && root.earningsData.fee_percent) || (meta && meta.fee_percent) || 15)
        return isFinite(value) ? value : 15
    }
    readonly property bool priceValid: {
        const amount = Number(root.publishPrice)
        return isFinite(amount) && Math.round(amount * 100) >= 100
    }
    readonly property var payout: {
        if (!root.priceValid) return { gross: 0, fee: 0, net: 0 }
        const gross = Math.round(Number(root.publishPrice) * 100)
        const fee = Math.max(Math.floor(gross * root.feePercent / 100), 1)
        return { gross: gross, fee: fee, net: Math.max(gross - fee, 0) }
    }
    readonly property string offerTitle: root.publishMode === "rent" ? "Rent out" : "Sell copies"
    readonly property color panelBorder: "#302940"
    readonly property color panelSurface: "#11121e"
    readonly property color supportingText: "#adb6d4"
    readonly property int minLevel: 10

    function money(cents, currency) {
        const amount = Number(cents || 0) / 100
        const code = String(currency || "usd").toUpperCase()
        return code + " " + amount.toFixed(2)
    }
    function priceLabel(row) {
        if (!row) return ""
        const amount = Number(row.price_cents || 0) / 100
        const currency = String(row.currency || "usd").toUpperCase()
        const base = (currency === "USD" ? "$" : currency + " ") + (amount % 1 === 0 ? amount.toFixed(0) : amount.toFixed(2))
        if (row.mode === "sale") return base
        if (row.rent_billing === "subscription") return base + " / month"
        return base + " · " + (row.fixed_days || 30) + " days"
    }
    function agentName(row) {
        if (row.title) return row.title
        if (row.agent && row.agent.display_name) return row.agent.display_name
        if (row.agent && row.agent.display_name === undefined && row.agent.id) return "Agent"
        return "Listed agent"
    }
    function mineAgent(row) {
        return (row && row.agent) ? row.agent : ({})
    }
    function faceAgent(agent) {
        const source = agent || ({})
        return {
            kind: source.kind || "ai",
            display_name: source.display_name || source.name || "",
            avatar_cdn_path: source.avatar_cdn_path || "",
            avatar_asset_id: source.avatar_asset_id || ""
        }
    }
    function roleTitle(agent) {
        if (!agent) return ""
        return agent.role_title || agent.department || ""
    }
    function levelOf(row) {
        return Number((row && row.level) || (row && row.agent && row.agent.level) || 1)
    }
    function levelRatio(row) {
        if (!root.minLevel) return 0
        return Math.max(0, Math.min(1, root.levelOf(row) / root.minLevel))
    }
    function listingStatus(listing) {
        return (listing && listing.status) || "active"
    }
    function titleCase(value) {
        const text = String(value || "").trim()
        if (!text) return ""
        return text.charAt(0).toUpperCase() + text.slice(1)
    }
    function skillNames(agent) {
        return ((agent && agent.skills) || []).map(function(skill) {
            return typeof skill === "string" ? skill : String((skill && (skill.name || skill.label || skill.key)) || "")
        }).filter(function(skill) { return skill.length > 0 })
    }
    function openOffer(agentId, mode) {
        if (!agentId) return
        if (root.publishAgentId !== agentId) {
            const row = root.mineRows.find(function(item) { return item.agent && item.agent.id === agentId }) || ({})
            root.publishTitle = row.agent ? row.agent.display_name : ""
            root.publishDescription = row.listing ? (row.listing.description || "") : ""
        }
        root.publishAgentId = agentId
        root.publishMode = mode
        root.publishPending = false
        root.publishSawBusy = false
        root.screen = "publish"
    }
    function closeOffer(nextTab) {
        root.publishPending = false
        root.publishSawBusy = false
        root.screen = "browse"
        if (nextTab) root.tab = nextTab
    }
    function confirmPublish() {
        if (!root.priceValid || features.busy) return
        root.publishPending = true
        root.publishSawBusy = false
        root.publishListing()
    }
    function takeOffer() {
        const agentId = features.pendingOfferAgentId || ""
        const mode = features.pendingOfferMode || ""
        if (!agentId || (mode !== "rent" && mode !== "sale")) return
        root.queuedOfferAgent = agentId
        root.queuedOfferMode = mode
        root.offerAwaitingRows = true
        root.mineRequested = false
        root.sawOfferBusy = false
        features.consumeMarketplaceOffer()
        root.ensureMineRequest()
    }
    function ensureMineRequest() {
        if (!root.offerAwaitingRows || features.busy || root.mineRequested) return
        root.mineRequested = true
        root.sawOfferBusy = false
        if (root.tab !== "mine") root.tab = "mine"
        else features.submit("mine", {})
    }
    function finishQueuedOffer() {
        const id = root.queuedOfferAgent
        const mode = root.queuedOfferMode
        root.queuedOfferAgent = ""
        root.queuedOfferMode = ""
        root.offerAwaitingRows = false
        root.sawOfferBusy = false
        if (!id || features.error) return
        let match = null
        const rows = root.mineRows || []
        for (let i = 0; i < rows.length; ++i) {
            const row = rows[i]
            if (row && row.agent && row.agent.id === id) match = row
        }
        if (match && match.eligible && !match.listing) root.openOffer(id, mode)
    }
    function refreshTab() {
        if (root.tab === "discover" || root.tab === "categories" || root.tab === "search") features.refresh()
        else if (root.tab === "mine") features.submit("mine", {})
        else if (root.tab === "earnings") features.submit("earnings", {})
    }
    function openCheckout(listingId) {
        root.checkoutSubmitted = true
        root.purchaseNote = "Opening secure checkout…"
        features.submit("checkout", { listing_id: listingId, _id: listingId, _confirmed: true })
    }
    function publishListing() {
        const priceCents = Math.round(Number(root.publishPrice) * 100)
        const values = {
            agent_id: root.publishAgentId,
            mode: root.publishMode,
            price_cents: priceCents,
            title: root.publishTitle.trim(),
            description: root.publishDescription.trim(),
            _confirmed: true
        }
        if (root.publishMode === "rent") {
            values.rent_billing = root.publishRentBilling
            if (root.publishRentBilling === "fixed") values.fixed_days = String(root.publishFixedDays)
        }
        features.submit("publish", values)
    }
    function toggleListing(listing) {
        if (!listing || !listing.id) return
        const action = listing.status === "paused" ? "resume" : "pause"
        features.submit(action, { _id: listing.id, _confirmed: true })
    }
    function startConnect() {
        features.submit("connect-onboard", { country: root.connectCountry, _confirmed: true })
    }

    Connections {
        target: features
        function onActionResult(actionId, result) {
            if (actionId === "mine") {
                root.mineRows = result.items || []
                if (result.meta) root.earningsData = Object.assign({}, root.earningsData, {meta: result.meta})
            } else if (actionId === "earnings") {
                root.earningsData = result
            } else if (actionId === "pause" || actionId === "resume") {
                root.mineRows = root.mineRows.map(function(row) { return row.listing && row.listing.id === result.id ? Object.assign({}, row, {listing: result}) : row })
            } else if (actionId === "checkout") {
                root.checkoutOrderId = result.order_id || ""
                root.purchaseNote = "Complete the payment in your browser, then check your payment here."
            } else if (actionId === "purchases" && root.screen === "checkout") {
                const rows = result.items || []
                const order = rows.find(function(row) { return root.checkoutOrderId && row.id === root.checkoutOrderId })
                if (order && order.status === "fulfilled" && order.cloned_agent_id) {
                    root.purchasedOrder = order
                    root.screen = "success"
                    root.purchaseNote = ""
                } else root.purchaseNote = "Payment has not been confirmed yet. Finish checkout in your browser, then try again."
            }
        }
        function onChanged() {
            if (features.currentPage !== "marketplace") return
            if (root.publishPending) {
                if (features.busy) root.publishSawBusy = true
                else if (root.publishSawBusy || features.error) {
                    const failed = !!features.error
                    root.publishPending = false
                    root.publishSawBusy = false
                    if (!failed) {
                        root.screen = "browse"
                        root.tab = "mine"
                        features.submit("mine", {})
                    }
                }
            }
            if (root.offerAwaitingRows && !root.mineRequested && !features.busy) root.ensureMineRequest()
            if (root.offerAwaitingRows && features.busy) root.sawOfferBusy = true
            if (root.offerAwaitingRows && root.mineRequested && root.sawOfferBusy && !features.busy && root.tab === "mine")
                root.finishQueuedOffer()
        }
    }

    Timer {
        interval: 5000; repeat: true
        running: root.screen === "checkout" && !!root.checkoutOrderId && !features.offline
        onTriggered: root.refreshPurchase()
    }
    onTabChanged: refreshTab()
    Component.onCompleted: {
        root.takeOffer()
        if (!root.offerAwaitingRows) root.refreshTab()
    }


    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 4
        spacing: 18

        RowLayout {
            visible: root.screen === "browse" && (root.tab === "discover" || root.tab === "categories" || root.tab === "search")
            Layout.fillWidth: true
            ColumnLayout {
                spacing: 5; Layout.fillWidth: true
                MokaidLabel { text: "Marketplace"; font.pixelSize: 28; font.weight: Font.Bold }
                MokaidLabel {
                    text: root.tab === "categories" ? "Browse by category" : root.tab === "search" ? "Search and filter agents" : "Find, buy or rent AI agents to supercharge your productivity."
                    font.pixelSize: 13; color: Theme.secondary; Layout.fillWidth: true; wrapMode: Text.Wrap
                }
            }
            MokaidButton { iconName: "refresh"; quiet: true; implicitHeight: 34; enabled: !features.busy; Accessible.name: "Refresh marketplace"; onClicked: root.refreshTab() }
        }
        RowLayout {
            visible: root.screen === "browse"
            Layout.fillWidth: true
            spacing: 6
            Repeater {
                model: [{id:"discover",label:"Discover"},{id:"categories",label:"Categories"},{id:"search",label:"All agents"},{id:"mine",label:"My listings"},{id:"earnings",label:"Earnings"}]
                MokaidButton {
                    required property var modelData
                    objectName: "marketplaceNav-" + modelData.id
                    text: modelData.label; implicitHeight: 34; font.pixelSize: 12
                    highlighted: root.tab === modelData.id; quiet: !highlighted
                    onClicked: { root.screen = "browse"; root.tab = modelData.id }
                }
            }
            Item { Layout.fillWidth: true }
        }
        Rectangle {
            visible: features.error.length > 0 || features.offline
            Layout.fillWidth: true; implicitHeight: errorRow.implicitHeight + 22
            radius: 10; color: "#261a25"; border.color: "#744357"
            RowLayout {
                id: errorRow; anchors.fill: parent; anchors.margins: 11
                MokaidLabel { text: features.error || "You are offline. Showing the last available marketplace data."; color: Theme.danger; wrapMode: Text.Wrap; Layout.fillWidth: true }
                MokaidButton { text: "Retry"; implicitHeight: 32; enabled: !features.busy; onClicked: root.screen === "checkout" ? root.refreshPurchase() : root.refreshTab() }
            }
        }
        Loader {
            Layout.fillWidth: true; Layout.fillHeight: true
            sourceComponent: root.screen === "detail" || root.screen === "checkout" || root.screen === "success" ? detailComponent : root.tab === "mine" || root.tab === "earnings" || root.screen === "publish" ? sellerComponent : discoverComponent
        }
    }
    Component { id: discoverComponent; MarketplaceDiscover { controller: root } }
    Component { id: detailComponent; MarketplaceDetail { controller: root } }
    Component { id: sellerComponent; MarketplaceSeller { controller: root } }
}
