pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "FeatureLogic.js" as Logic

ColumnLayout {
    id: root
    required property var rows
    property bool searching: false
    signal selected(string recordId)
    property date month: new Date(new Date().getFullYear(),new Date().getMonth(),1)
    property date selectedDay: new Date()
    readonly property int firstWeekday: (new Date(month.getFullYear(),month.getMonth(),1).getDay()+6)%7
    readonly property var selectedEvents: searching ? rows.slice().sort(function(a,b){return new Date(a.start_at)-new Date(b.start_at);}) : eventsFor(selectedDay)
    spacing: 12
    function key(d) { return d.getFullYear()+"-"+d.getMonth()+"-"+d.getDate(); }
    function dayAt(index) { return new Date(month.getFullYear(),month.getMonth(),index-root.firstWeekday+1); }
    function eventsFor(day) {
        var beginning = new Date(day.getFullYear(),day.getMonth(),day.getDate());
        var ending = new Date(day.getFullYear(),day.getMonth(),day.getDate()+1);
        return rows.filter(function(r) {
            var start = new Date(r.start_at), end = new Date(r.end_at || r.start_at);
            if (isNaN(start.getTime())) return false;
            if (isNaN(end.getTime()) || end<=start) return start>=beginning && start<ending;
            return start<ending && end>beginning;
        }).sort(function(a,b) { return new Date(a.start_at)-new Date(b.start_at); });
    }
    function shiftMonth(amount) { month=new Date(month.getFullYear(),month.getMonth()+amount,1); selectedDay=month; }
    RowLayout {
        Layout.fillWidth: true; spacing: 8
        MokaidLabel { text: Qt.formatDate(root.month,"MMMM yyyy"); font.pixelSize: 20; font.weight: Font.DemiBold; Layout.fillWidth: true }
        MokaidButton { text: "Today"; quiet: true; onClicked: { root.month=new Date(new Date().getFullYear(),new Date().getMonth(),1); root.selectedDay=new Date(); } }
        MokaidButton { iconName: "chevron-left"; quiet: true; Accessible.name: "Previous month"; onClicked: root.shiftMonth(-1) }
        MokaidButton { iconName: "chevron-right"; quiet: true; Accessible.name: "Next month"; onClicked: root.shiftMonth(1) }
    }
    Rectangle {
        visible: !root.searching
        Layout.fillWidth: true; Layout.preferredHeight: Math.max(200,Math.min(340,root.height*0.54))
        color: Theme.surface; radius: 14; border.color: Theme.border
        ColumnLayout {
            anchors.fill: parent; anchors.margins: 10; spacing: 4
            RowLayout {
                Layout.fillWidth: true; spacing: 3
                Repeater { model: ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]; MokaidLabel { required property string modelData; Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.preferredHeight: 28; horizontalAlignment: Text.AlignHCenter; text: modelData; font.pixelSize: 11; color: Theme.muted } }
            }
            GridLayout {
                Layout.fillWidth: true; Layout.fillHeight: true; columns: 7; rowSpacing: 3; columnSpacing: 3
                Repeater {
                    model: 42
                    ItemDelegate {
                        id: day
                        required property int index
                        readonly property date dayDate: root.dayAt(index)
                        readonly property var dayEvents: root.eventsFor(dayDate)
                        readonly property bool inMonth: dayDate.getMonth()===root.month.getMonth()
                        readonly property bool today: root.key(dayDate)===root.key(new Date())
                        readonly property bool chosen: root.key(dayDate)===root.key(root.selectedDay)
                        Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: 1; Layout.preferredHeight: 1
                        padding: 5
                        Accessible.name: Qt.formatDate(dayDate,"dddd, MMMM d, yyyy")+", "+dayEvents.length+" events"
                        background: Rectangle { radius: 8; color: day.chosen ? Theme.selected : day.hovered ? Theme.hover : "transparent"; border.width: day.chosen || day.visualFocus || day.today ? 1 : 0; border.color: day.visualFocus ? Theme.focusBorder : day.chosen ? Theme.selectedBorder : Theme.border }
                        contentItem: ColumnLayout {
                            spacing: 3
                            MokaidLabel { Layout.alignment: Qt.AlignHCenter; text: day.dayDate.getDate(); font.pixelSize: 12; font.weight: day.today ? Font.Bold : Font.Normal; color: day.today ? Theme.primary : day.inMonth ? Theme.text : Theme.muted; opacity: day.inMonth ? 1 : 0.6 }
                            Row { Layout.alignment: Qt.AlignHCenter; spacing: 3; Repeater { model: Math.min(3,day.dayEvents.length); Rectangle { width: 4; height: 4; radius: 2; color: Theme.primary } } }
                        }
                        onClicked: root.selectedDay=dayDate
                    }
                }
            }
        }
    }
    RowLayout {
        MokaidLabel { Layout.fillWidth: true; text: root.searching ? "Matching events" : Qt.formatDate(root.selectedDay,"dddd, MMMM d"); font.pixelSize: 15; font.weight: Font.DemiBold }
        MokaidLabel { text: root.selectedEvents.length+" events"; color: Theme.muted; font.pixelSize: 12 }
    }
    ListView {
        id: agenda
        Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 72
        clip: true; model: root.selectedEvents; spacing: 6
        delegate: ItemDelegate {
            id: eventItem
            required property var modelData
            width: agenda.width; height: 72; padding: 12
            background: Rectangle { radius: 10; color: eventItem.hovered ? Theme.hover : Theme.surface; border.width: eventItem.visualFocus ? 1 : 0; border.color: Theme.focusBorder }
            contentItem: RowLayout {
                spacing: 16
                MokaidLabel { text: (root.searching ? Logic.shortDate(eventItem.modelData.start_at)+"\n" : "")+(eventItem.modelData.all_day ? "All day" : Qt.formatDateTime(new Date(eventItem.modelData.start_at),"hh:mm")); color: Theme.primary; Layout.preferredWidth: root.searching ? 76 : 54; font.pixelSize: 12 }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 5
                    MokaidLabel { Layout.fillWidth: true; text: Logic.title(eventItem.modelData,"calendar"); elide: Text.ElideRight; font.weight: Font.DemiBold }
                    MokaidLabel { Layout.fillWidth: true; text: [Logic.human(eventItem.modelData.kind),eventItem.modelData.project_name].filter(Boolean).join(" · "); color: Theme.secondary; font.pixelSize: 12; elide: Text.ElideRight }
                }
                MokaidIcon { name: "chevron-right"; size: 16; color: Theme.muted }
            }
            onClicked: root.selected(Logic.id(modelData))
        }
        MokaidLabel { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.topMargin: 12; visible: root.selectedEvents.length===0; text: root.searching ? "No matching events. Try another search." : "No events scheduled. A little room to focus."; color: Theme.secondary; wrapMode: Text.Wrap }
        ScrollBar.vertical: ScrollBar {}
    }
}
