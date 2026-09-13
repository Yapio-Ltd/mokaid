import QtQuick
import QtQuick.Controls.Basic as Basic

Basic.Label {
    // Workspace content is text, never an implicitly trusted rich-text document.
    textFormat: Text.PlainText
}
