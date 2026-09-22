import QtQuick
import QtQuick.Shapes

Item {
    id: root
    property string name: "office"
    property color color: Theme.secondary
    property real size: 20
    implicitWidth: size; implicitHeight: size
    readonly property var paths: ({
        "moked": "M5 16V8Q5 4 9 5L12 8L15 5Q19 4 19 8V16Q19 20 15 19L12 16L9 19Q5 20 5 16M8 10V14M16 10V14",
        "microphone": "M9 5C9 1 15 1 15 5V11C15 15 9 15 9 11V5M5 10V11C5 20 19 20 19 11V10M12 18V22M8 22H16",
        "speaker": "M3 9H7L13 4V20L7 15H3V9M17 8C20 10 20 14 17 16M20 5C25 9 25 15 20 19",
        "speaker-off": "M3 9H7L13 4V20L7 15H3V9M17 9L23 15M23 9L17 15",
        "stop": "M6 6H18V18H6V6",
        "office": "M3 21V9L12 3L21 9V21H3M9 21V14H15V21M7 10H7.01M17 10H17.01",
        "agents": "M8 21V17M16 21V17M5 21V11C5 6 8 3 12 3C16 3 19 6 19 11V21M8 11C8 8 9.5 6 12 6C14.5 6 16 8 16 11C16 14 14.5 16 12 16C9.5 16 8 14 8 11",
        "marketplace": "M4 7H20L18 21H6L4 7M9 7V5C9 2 15 2 15 5V7M10 12V16M14 12V16",
        "tasks": "M21 12A9 9 0 1 1 3 12A9 9 0 1 1 21 12M8 12L11 15L17 8",
        "projects": "M3 7Q3 5 5 5H9L11 7H19Q21 7 21 9V19Q21 21 19 21H5Q3 21 3 19V7M8 4V2H16V4",
        "knowledge": "M12 5L4 3V19L12 21L20 19V3L12 5V21",
        "drive": "M5 3H14L19 8V21H5V3M14 3V8H19",
        "image": "M3 3H21V21H3V3M3 16L9 10L15 17L18 13L21 16M17 7H17.01",
        "play": "M8 4L20 12L8 20V4",
        "headphones": "M4 14V11C4 1 20 1 20 11V14M4 12H7V21H3V13H4M20 12H17V21H21V13H20",
        "code": "M8 6L2 12L8 18M16 6L22 12L16 18M14 3L10 21",
        "table": "M3 3H21V21H3V3M3 9H21M3 15H21M10 3V21",
        "download": "M12 3V16M7 11L12 16L17 11M4 16V21H20V16",
        "minus": "M5 12H19",
        "fit": "M3 9V3H9M15 3H21V9M21 15V21H15M9 21H3V15",
        "zoom-in": "M17 10A7 7 0 1 1 3 10A7 7 0 1 1 17 10M15 15L21 21M7 10H13M10 7V13",
        "zoom-out": "M17 10A7 7 0 1 1 3 10A7 7 0 1 1 17 10M15 15L21 21M7 10H13",
        "file": "M5 3H14L19 8V21H5V3M14 3V8H19",
        "folder": "M3 6H9L11 8H21V20H3V6",
        "calendar": "M4 5H20V21H4V5M8 2V8M16 2V8M4 11H20M8 15H8.01M12 15H12.01M16 15H16.01",
        "mail": "M3 5H21V19H3V5M3 6L12 13L21 6",
        "analytics": "M3 20V4H21V20H3M6 16L10 11L14 13L18 8",
        "settings": "M9 3H15L16 6L19 7L21 12L19 17L16 18L15 21H9L8 18L5 17L3 12L5 7L8 6L9 3M16 12A4 4 0 1 1 8 12A4 4 0 1 1 16 12",
        "profile": "M16 7A4 4 0 1 1 8 7A4 4 0 1 1 16 7M4 22V19C4 15 20 15 20 19V22",
        "members": "M14 7A4 4 0 1 1 6 7A4 4 0 1 1 14 7M2 21V18C2 14 18 14 18 18V21M17 4C22 4 22 11 17 11M20 15C23 16 23 19 23 21",
        "integrations": "M8 3V8M16 3V8M6 8H18V11C18 16 6 16 6 11V8M12 15V21",
        "billing": "M3 5H21V19H3V5M3 10H21M7 15H11",
        "search": "M17 10A7 7 0 1 1 3 10A7 7 0 1 1 17 10M15 15L21 21",
        "bell": "M5 17H19L17 14V9C17 3 7 3 7 9V14L5 17M10 21H14M12 2V4",
        "sun": "M16 12A4 4 0 1 1 8 12A4 4 0 1 1 16 12M12 2V4M12 20V22M2 12H4M20 12H22M5 5L6.5 6.5M17.5 17.5L19 19M5 19L6.5 17.5M17.5 6.5L19 5",
        "refresh": "M20 8A8 8 0 1 0 21 15M20 3V8H15",
        "arrow-right": "M4 12H20M14 6L20 12L14 18",
        "chevron-right": "M9 5L16 12L9 19",
        "chevron-left": "M15 5L8 12L15 19",
        "chevron-down": "M5 9L12 16L19 9",
        "chevron-up": "M5 15L12 8L19 15",
        "close": "M6 6L18 18M18 6L6 18",
        "plus": "M12 5V19M5 12H19",
        "more": "M12 5H12.01M12 12H12.01M12 19H12.01",
        "external-link": "M14 3H21V10M21 3L11 13M10 5H4V21H20V15",
        "send": "M3 3L22 12L3 21L6 12L3 3M6 12H15",
        "pulse": "M2 12H6L9 4L14 20L17 12H22",
        "bolt": "M14 2L5 14H11L10 22L20 9H13L14 2",
        "shield": "M12 2L21 6V12C21 17 17 21 12 23C7 21 3 17 3 12V6L12 2M8 12L11 15L17 9"
    })
    Shape {
        anchors.centerIn: parent
        width: 24; height: 24
        scale: root.size / 24
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: root.color; strokeWidth: 1.55
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
            PathSvg { path: root.paths[root.name] || root.paths.office }
        }
    }
}
