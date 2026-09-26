pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Flickable {
    id: root
    objectName: "marketplaceEarnings"
    required property var controller
    contentWidth: width
    contentHeight: column.implicitHeight + 20
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
    readonly property var earnings: controller.earningsData || ({})
    readonly property bool loaded: earnings.gross_cents !== undefined
    readonly property var orders: (earnings.orders || []).filter(function(order) { return order.status === "paid" || order.status === "fulfilled" })
    readonly property var listings: earnings.listings || []
    readonly property var leases: earnings.active_leases || []
    readonly property var chartMonths: {
        const now = new Date()
        const months = []
        for (let index = 5; index >= 0; --index) {
            const date = new Date(now.getFullYear(), now.getMonth() - index, 1)
            months.push({ year: date.getFullYear(), month: date.getMonth(), label: Qt.formatDate(date, "MMM"), gross: 0, count: 0 })
        }
        root.orders.forEach(function(order) {
            if (!order.paid_at) return
            const date = new Date(order.paid_at)
            if (!isFinite(date.getTime())) return
            const match = months.find(function(month) { return month.year === date.getFullYear() && month.month === date.getMonth() })
            if (match) { match.gross += Number(order.amount_cents || 0); match.count++ }
        })
        return months
    }
    readonly property bool hasChartData: chartMonths.some(function(month) { return month.count > 0 })
    readonly property var categories: {
        const grouped = {}
        root.orders.forEach(function(order) {
            const listing = root.listings.find(function(row) { return row.id === order.listing_id })
            const category = listing && listing.agent && listing.agent.department || "Other"
            grouped[category] = (grouped[category] || 0) + Number(order.amount_cents || 0)
        })
        const colors = ["#9450ff", "#6850fd", "#5265ef", "#ba57e8", "#e055b9", "#46bdc6"]
        let rows = Object.keys(grouped).map(function(name) { return { name: name, amount: grouped[name] } }).filter(function(row) { return row.amount > 0 }).sort(function(a,b) { return b.amount-a.amount })
        if (rows.length > 6) {
            const remainder = rows.slice(5).reduce(function(total,row) { return total + row.amount }, 0)
            rows = rows.slice(0,5)
            const other = rows.find(function(row) { return row.name === "Other" })
            if (other) other.amount += remainder
            else rows.push({name:"Other",amount:remainder})
        }
        return rows.map(function(row,index) { row.color=colors[index % colors.length]; return row })
    }
    readonly property real categoryTotal: categories.reduce(function(total,row) { return total + row.amount }, 0)
    readonly property bool connectReady: earnings.connect_ready !== undefined ? !!earnings.connect_ready : !!(earnings.meta && earnings.meta.connect_ready)
    property int selectedMonth: -1

    function dollar(cents) {
        const value = Number(cents || 0) / 100
        return "$" + value.toLocaleString(Qt.locale("en_US"), "f", value % 1 ? 2 : 0)
    }
    function compactDollar(cents) {
        const value = Number(cents || 0) / 100
        if (value >= 1000) return "$" + (value/1000).toFixed(value % 1000 ? 1 : 0) + "k"
        return "$" + Math.round(value)
    }
    function orderCount(listingId) { return orders.filter(function(order) { return order.listing_id === listingId }).length }
    function listingRevenue(listingId) { return orders.filter(function(order) { return order.listing_id === listingId }).reduce(function(total,order) { return total + Number(order.amount_cents || 0) }, 0) }
    onChartMonthsChanged: if (revenueCanvas) revenueCanvas.requestPaint()
    onCategoriesChanged: if (categoryCanvas) categoryCanvas.requestPaint()

    component Panel: Rectangle {
        color: "#11131e"
        border.color: "#25283d"
        radius: 10
    }
    component Metric: Panel {
        id: metric
        property string label: ""
        property string value: "—"
        property string caption: ""
        property string iconName: "analytics"
        property color accent: "#3ce7b4"
        property color iconBackground: "#0b2926"
        Layout.fillWidth: true
        implicitHeight: 104
        RowLayout {
            anchors.fill: parent; anchors.margins: 15; spacing: 7
            ColumnLayout {
                Layout.fillWidth: true; spacing: 5
                MokaidLabel { text: metric.value; Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: root.width > 850 ? 23 : 19; font.weight: Font.DemiBold }
                MokaidLabel { text: metric.label; color: Theme.secondary; font.pixelSize: 10 }
                MokaidLabel { text: metric.caption; color: Theme.muted; font.pixelSize: 9; Layout.fillWidth: true; elide: Text.ElideRight }
            }
            Rectangle {
                Layout.preferredWidth: 35; Layout.preferredHeight: 39; radius: 7; color: metric.iconBackground
                MokaidIcon { anchors.centerIn: parent; name: metric.iconName; size: 20; color: metric.accent }
            }
        }
    }

    ColumnLayout {
        id: column
        width: root.width
        spacing: 17
        RowLayout {
            Layout.fillWidth: true
            ColumnLayout {
                Layout.fillWidth: true; spacing: 3
                MokaidLabel { text: "Earnings"; font.pixelSize: 25; font.weight: Font.DemiBold }
                MokaidLabel { text: "Track your marketplace performance."; font.pixelSize: 12; color: Theme.secondary }
            }
            Item { Layout.fillWidth: true }
            Rectangle {
                implicitWidth: rangeLabel.implicitWidth + 24; implicitHeight: 31; radius: 7; color: "#10131e"; border.color: "#25283d"
                MokaidLabel { id: rangeLabel; anchors.centerIn: parent; text: "Latest 50 paid orders"; color: Theme.secondary; font.pixelSize: 10 }
            }
        }
        GridLayout {
            Layout.fillWidth: true
            columns: 4; columnSpacing: 10; rowSpacing: 10
            Metric { label: "Total revenue"; value: root.loaded ? root.dollar(root.earnings.gross_cents) : "—"; caption: "Before platform fees"; iconName: "billing" }
            Metric { label: "Net earnings"; value: root.loaded ? root.dollar(root.earnings.net_cents) : "—"; caption: "After " + root.controller.feePercent + "% fee"; iconName: "shield"; accent: "#6dbdff"; iconBackground: "#10233b" }
            Metric { label: "Paid orders"; value: root.loaded ? String(root.orders.length) : "—"; caption: "In the latest records"; iconName: "marketplace"; accent: "#c188ff"; iconBackground: "#261a40" }
            Metric { label: "Active rentals"; value: root.loaded ? String(root.leases.length) : "—"; caption: "Current active access"; iconName: "agents" }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 14
            Panel {
                Layout.fillWidth: true
                Layout.preferredHeight: 300
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 15; spacing: 12
                    RowLayout {
                        Layout.fillWidth: true
                        MokaidLabel { text: "Revenue overview"; font.pixelSize: 12; font.weight: Font.DemiBold }
                        Item { Layout.fillWidth: true }
                        MokaidLabel { text: "Last 6 months"; font.pixelSize: 9; color: Theme.muted }
                    }
                    Item {
                        id: plot
                        Layout.fillWidth: true; Layout.fillHeight: true
                        readonly property real peak: Math.max(100, Math.ceil(Math.max.apply(null, root.chartMonths.map(function(month) { return month.gross }))/100) * 100)
                        Item {
                            anchors.left: parent.left; anchors.top: revenueCanvas.top; height: revenueCanvas.height; width: 39
                            Repeater {
                                model: 5
                                MokaidLabel { required property int index; y: (revenueCanvas.height - 15) * index / 4; height: 16; text: root.hasChartData ? root.compactDollar(plot.peak * (1-index/4)) : "—"; font.pixelSize: 9; color: Theme.muted }
                            }
                        }
                        Canvas {
                            id: revenueCanvas
                            anchors.left: parent.left; anchors.leftMargin: 43; anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: labelsRow.top; anchors.bottomMargin: 8
                            onWidthChanged: requestPaint()
                            onHeightChanged: requestPaint()
                            onPaint: {
                                const ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                const top = 8, bottom = height - 7, left = 4, right = width - 5
                                ctx.lineWidth = 1
                                ctx.strokeStyle = "#24263b"
                                for (let index=0; index<5; ++index) {
                                    const y=top+(bottom-top)*index/4
                                    ctx.beginPath(); ctx.moveTo(left,y); ctx.lineTo(right,y); ctx.stroke()
                                }
                                if (!root.hasChartData) return
                                const values = root.chartMonths
                                const points=values.map(function(month,index) { return {x:left+(right-left)*index/5,y:bottom-(bottom-top)*month.gross/plot.peak} })
                                const fill=ctx.createLinearGradient(0,top,0,bottom)
                                fill.addColorStop(0,"rgba(151,70,238,0.3)"); fill.addColorStop(1,"rgba(151,70,238,0)")
                                ctx.beginPath(); ctx.moveTo(points[0].x,bottom)
                                points.forEach(function(point) { ctx.lineTo(point.x,point.y) })
                                ctx.lineTo(points[5].x,bottom); ctx.closePath(); ctx.fillStyle=fill; ctx.fill()
                                ctx.beginPath(); ctx.moveTo(points[0].x,points[0].y)
                                points.forEach(function(point) { ctx.lineTo(point.x,point.y) })
                                ctx.strokeStyle="#a45af5"; ctx.lineWidth=2; ctx.stroke()
                                points.forEach(function(point) { ctx.beginPath(); ctx.arc(point.x,point.y,3,0,Math.PI*2); ctx.fillStyle="#be83ff"; ctx.fill() })
                            }
                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onPositionChanged: function(mouse) { root.selectedMonth = Math.max(0,Math.min(5,Math.round((mouse.x-4)/(width-9)*5))) }
                                onExited: root.selectedMonth = -1
                            }
                        }
                        Item {
                            id: labelsRow
                            anchors.left: revenueCanvas.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                            height: 18
                            Repeater {
                                model: root.chartMonths
                                MokaidLabel { required property var modelData; required property int index; width: 38; x: 4 + (labelsRow.width - 9) * index / 5 - width / 2; text: modelData.label; font.pixelSize: 9; color: Theme.muted; horizontalAlignment: Text.AlignHCenter }
                            }
                        }
                        ColumnLayout {
                            anchors.centerIn: revenueCanvas
                            width: Math.min(revenueCanvas.width - 20,250)
                            visible: !root.hasChartData
                            spacing: 7
                            MokaidLabel { Layout.fillWidth: true; text: features.busy && !root.loaded ? "Loading revenue…" : "Your first sale starts the curve"; horizontalAlignment: Text.AlignHCenter; font.pixelSize: 12; font.weight: Font.DemiBold; wrapMode: Text.Wrap }
                            MokaidLabel { Layout.fillWidth: true; text: "Revenue appears here when paid orders are available."; horizontalAlignment: Text.AlignHCenter; font.pixelSize: 10; color: Theme.muted; wrapMode: Text.Wrap }
                        }
                        Rectangle {
                            visible: root.selectedMonth >= 0 && root.hasChartData
                            anchors.top: parent.top; anchors.right: parent.right
                            implicitWidth: tooltipColumn.implicitWidth + 24; implicitHeight: tooltipColumn.implicitHeight + 16
                            color: "#1c1831"; border.color: "#63418c"; radius: 6
                            ColumnLayout {
                                id: tooltipColumn
                                anchors.centerIn: parent; spacing: 3
                                MokaidLabel { text: root.selectedMonth >= 0 ? root.chartMonths[root.selectedMonth].label : ""; font.pixelSize: 10; color: Theme.secondary }
                                MokaidLabel { text: root.selectedMonth >= 0 ? root.dollar(root.chartMonths[root.selectedMonth].gross) : ""; font.pixelSize: 13; font.weight: Font.DemiBold }
                            }
                        }
                    }
                }
            }
            Panel {
                Layout.preferredWidth: Math.max(258, root.width * .38)
                Layout.preferredHeight: 300
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 15; spacing: 14
                    MokaidLabel { text: "Earnings by category"; font.pixelSize: 12; font.weight: Font.DemiBold }
                    Item {
                        Layout.fillWidth: true; Layout.fillHeight: true
                        RowLayout {
                            anchors.fill: parent; spacing: 15
                            Item {
                                Layout.preferredWidth: Math.min(160, parent.width * .48)
                                Layout.preferredHeight: width
                                Canvas {
                                    id: categoryCanvas
                                    anchors.fill: parent
                                    onWidthChanged: requestPaint()
                                    onHeightChanged: requestPaint()
                                    onPaint: {
                                        const ctx = getContext("2d")
                                        ctx.clearRect(0,0,width,height)
                                        const size=Math.min(width,height),radius=size*.39,thickness=size*.17
                                        ctx.lineWidth=thickness
                                        ctx.strokeStyle="#242239"; ctx.beginPath(); ctx.arc(width/2,height/2,radius,0,Math.PI*2); ctx.stroke()
                                        if (!root.categoryTotal) return
                                        let start=-Math.PI/2
                                        root.categories.forEach(function(category) { const end=start+Math.PI*2*category.amount/root.categoryTotal; ctx.beginPath(); ctx.strokeStyle=category.color; ctx.arc(width/2,height/2,radius,start+.012,end-.012); ctx.stroke(); start=end })
                                    }
                                }
                                ColumnLayout {
                                    anchors.centerIn: parent; spacing: 3; width: parent.width * .62
                                    MokaidLabel { Layout.fillWidth: true; text: root.loaded ? root.dollar(root.categoryTotal) : "—"; font.pixelSize: 15; font.weight: Font.DemiBold; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter }
                                    MokaidLabel { text: "Total"; color: Theme.muted; font.pixelSize: 9; Layout.alignment: Qt.AlignHCenter }
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 12
                                Repeater {
                                    model: root.categories
                                    RowLayout {
                                        required property var modelData
                                        Layout.fillWidth: true; spacing: 6
                                        Rectangle { implicitWidth: 7; implicitHeight: 7; radius: 4; color: modelData.color }
                                        MokaidLabel { Layout.fillWidth: true; text: root.controller.titleCase(modelData.name); color: Theme.secondary; font.pixelSize: 9; elide: Text.ElideRight }
                                        MokaidLabel { text: Math.round(modelData.amount/root.categoryTotal*100) + "%"; color: modelData.color; font.pixelSize: 9 }
                                    }
                                }
                                MokaidLabel { visible: !root.categories.length; Layout.fillWidth: true; text: "No paid orders yet"; font.pixelSize: 11; color: Theme.muted; wrapMode: Text.Wrap }
                            }
                        }
                    }
                    MokaidLabel { Layout.fillWidth: true; text: "Based on your latest paid orders."; color: Theme.muted; font.pixelSize: 9; wrapMode: Text.Wrap }
                }
            }
        }
        Panel {
            Layout.fillWidth: true
            implicitHeight: payoutRow.implicitHeight + 30
            RowLayout {
                id: payoutRow
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 15; spacing: 14
                Rectangle {
                    implicitWidth: 40; implicitHeight: 40; radius: 9; color: root.connectReady ? "#0c2c29" : "#261c3c"
                    MokaidIcon { anchors.centerIn: parent; name: "shield"; size: 21; color: root.connectReady ? "#47e5b3" : "#b18be9" }
                }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 4
                    MokaidLabel { text: root.connectReady ? "Your payouts are connected" : "Connect your payouts"; font.pixelSize: 13; font.weight: Font.DemiBold }
                    MokaidLabel { Layout.fillWidth: true; text: root.connectReady ? "Stripe Connect sends you " + (100-root.controller.feePercent) + "% of each payment." : "Set up Stripe Connect to publish listings and receive payments."; color: Theme.secondary; font.pixelSize: 11; wrapMode: Text.Wrap }
                }
                MokaidTextField {
                    visible: !root.connectReady
                    Layout.preferredWidth: 73; implicitHeight: 35; font.pixelSize: 11
                    text: root.controller.connectCountry
                    maximumLength: 2
                    validator: RegularExpressionValidator { regularExpression: /[a-zA-Z]{0,2}/ }
                    onTextEdited: root.controller.connectCountry = text.toUpperCase()
                    placeholderText: "US"
                    Accessible.name: "Payout country code"
                }
                MokaidButton {
                    visible: !root.connectReady
                    text: "Set up payouts"
                    highlighted: true; implicitHeight: 35; font.pixelSize: 11
                    enabled: !features.busy && /^[A-Z]{2}$/.test(root.controller.connectCountry)
                    onClicked: root.controller.startConnect()
                }
                Rectangle {
                    visible: root.connectReady
                    implicitWidth: 73; implicitHeight: 26; radius: 6; color: "#102c26"; border.color: "#256f56"
                    MokaidLabel { anchors.centerIn: parent; text: "Connected"; color: "#85edc7"; font.pixelSize: 10 }
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            MokaidLabel { text: "Listing performance"; font.pixelSize: 15; font.weight: Font.DemiBold }
            Item { Layout.fillWidth: true }
            MokaidButton { text: "Manage listings →"; implicitHeight: 30; quiet: true; font.pixelSize: 11; onClicked: root.controller.tab = "mine" }
        }
        Panel {
            Layout.fillWidth: true
            implicitHeight: performanceColumn.implicitHeight + 2
            ColumnLayout {
                id: performanceColumn
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 1
                spacing: 0
                RowLayout {
                    Layout.fillWidth: true; Layout.margins: 14; spacing: 12
                    MokaidLabel { text: "Agent"; Layout.fillWidth: true; color: Theme.muted; font.pixelSize: 10 }
                    MokaidLabel { text: "Orders"; Layout.preferredWidth: 60; color: Theme.muted; font.pixelSize: 10 }
                    MokaidLabel { text: "Revenue"; Layout.preferredWidth: 110; color: Theme.muted; font.pixelSize: 10 }
                    MokaidLabel { text: "Status"; Layout.preferredWidth: 80; color: Theme.muted; font.pixelSize: 10 }
                }
                Repeater {
                    model: root.listings
                    Rectangle {
                        id: perfRow
                        required property var modelData
                        Layout.fillWidth: true; implicitHeight: 60; color: "transparent"
                        Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: "#232639" }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 12
                            WorkforcePortrait { agent: root.controller.faceAgent(perfRow.modelData.agent); size: 33 }
                            MokaidLabel { text: perfRow.modelData.title || (perfRow.modelData.agent && perfRow.modelData.agent.display_name) || "Agent"; Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: 12; font.weight: Font.DemiBold }
                            MokaidLabel { text: String(root.orderCount(perfRow.modelData.id)); Layout.preferredWidth: 60; font.pixelSize: 11 }
                            MokaidLabel { text: root.dollar(root.listingRevenue(perfRow.modelData.id)); Layout.preferredWidth: 110; font.pixelSize: 11 }
                            MokaidLabel { text: perfRow.modelData.status === "paused" ? "Paused" : "Active"; Layout.preferredWidth: 80; font.pixelSize: 10; color: perfRow.modelData.status === "paused" ? "#c5afe9" : "#6be0b9" }
                        }
                    }
                }
                MokaidLabel { visible: root.listings.length === 0; Layout.fillWidth: true; Layout.margins: 28; text: features.busy && !root.loaded ? "Loading listings…" : "Your published agents will appear here."; color: Theme.muted; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
            }
        }
    }
}
