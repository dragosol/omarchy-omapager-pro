import QtQuick
import QtTest
import "../ReplyEdit.js" as ReplyEdit

// The reply field is read-only to Qt and typed into by ReplyEdit.key - so the
// field never watches the clipboard (QQuickTextInput::q_canPasteChanged reads
// it only when the field is editable).
Item {
  width: 400; height: 60
  property string sent: ""
  property int pastes: 0
  property int cancels: 0

  TextInput {
    id: field
    width: 400; height: 30
    readOnly: true
    focus: true
    Keys.onPressed: function(event) {
      event.accepted = ReplyEdit.key(field, event, {
        paste: function() { pastes += 1 },
        send: function(t) { sent = t; field.text = "" },
        cancel: function() { cancels += 1; field.text = "" }
      }, { paste: StandardKey.Paste, selectAll: StandardKey.SelectAll, cut: StandardKey.Cut })
    }
  }

  TestCase {
    name: "ReplyField"
    when: windowShown

    function init() { field.text = ""; field.forceActiveFocus(); sent = ""; pastes = 0; cancels = 0 }

    function test_typing_and_editing() {
      keyClick(Qt.Key_H, Qt.NoModifier); keyClick(Qt.Key_I, Qt.NoModifier)
      keyClick(Qt.Key_Space); keyClick(Qt.Key_T); keyClick(Qt.Key_H); keyClick(Qt.Key_E); keyClick(Qt.Key_R); keyClick(Qt.Key_E)
      compare(field.text, "hi there")
      keyClick(Qt.Key_Backspace)
      compare(field.text, "hi ther")
      keyClick(Qt.Key_Backspace, Qt.ControlModifier)
      compare(field.text, "hi ")
      keyClick(Qt.Key_Home)
      keyClick(Qt.Key_Delete)
      compare(field.text, "i ")
      keyClick(Qt.Key_A, Qt.ControlModifier)          // select all, then type over it
      keyClick(Qt.Key_X, Qt.NoModifier)
      compare(field.text, "x")
    }

    function test_surrogate_pair_is_one_step() {
      field.text = "a\u{1F600}"
      field.cursorPosition = field.text.length
      keyClick(Qt.Key_Backspace)
      compare(field.text, "a")
    }

    function test_enter_escape_paste() {
      keyClick(Qt.Key_O); keyClick(Qt.Key_K)
      keyClick(Qt.Key_Return)
      compare(sent, "ok")
      compare(field.text, "")
      keyClick(Qt.Key_V, Qt.ControlModifier)
      compare(pastes, 1)
      compare(field.text, "")                          // Qt's own paste never ran
      keyClick(Qt.Key_Escape)
      compare(cancels, 1)
    }

    function test_never_offers_paste() {
      verify(field.readOnly)
      verify(!field.canPaste)
    }
  }
}
