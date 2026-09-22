import QtQuick
import QtQuick.Controls.Basic as Basic

Basic.Label {
    // Workspace content is text, never an implicitly trusted rich-text document.
    textFormat: Text.PlainText
    color: Theme.text
    font.family: Theme.fontFamily
    font.pixelSize: 13
    // Controls size the label to the button. Keep the glyphs in the middle of that box.
    verticalAlignment: Text.AlignVCenter
}
