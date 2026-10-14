// Typing for the reply field, which is read-only to Qt (see Toast.qml: an
// editable TextInput reads every clipboard change to update canPaste). The
// field's own cursor movement and selection still work; this supplies the
// editing. `field` is any TextInput; returns true when the key was handled.
.pragma library

function stepBack(text, at) {
  var c = text.charCodeAt(at - 1)
  return at - (at > 1 && c >= 0xDC00 && c <= 0xDFFF ? 2 : 1)
}

function stepForward(text, at) {
  var c = text.charCodeAt(at)
  return at + (at < text.length - 1 && c >= 0xD800 && c <= 0xDBFF ? 2 : 1)
}

function wordBack(text, at) {
  var i = at
  while (i > 0 && /\s/.test(text.charAt(i - 1))) i--
  while (i > 0 && !/\s/.test(text.charAt(i - 1))) i--
  return i
}

function wordForward(text, at) {
  var i = at
  while (i < text.length && /\s/.test(text.charAt(i))) i++
  while (i < text.length && !/\s/.test(text.charAt(i))) i++
  return i
}

function cutSelection(field) {
  if (field.selectedText.length === 0) return false
  field.remove(field.selectionStart, field.selectionEnd)
  return true
}

// actions: { paste(), send(text), cancel() }
// std: { paste, selectAll, cut } - the StandardKey values, which a
// .pragma library cannot see, passed in from QML.
function key(field, event, actions, std) {
  var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
  var at = field.cursorPosition
  var text = field.text
  if (event.matches(std.paste)) {
    actions.paste()
  } else if (event.matches(std.selectAll)) {
    field.selectAll()
  } else if (event.matches(std.cut)) {
    field.copy()
    cutSelection(field)
  } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
    actions.send(text)
  } else if (event.key === Qt.Key_Escape) {
    actions.cancel()
  } else if (event.key === Qt.Key_Backspace) {
    if (!cutSelection(field) && at > 0)
      field.remove(ctrl ? wordBack(text, at) : stepBack(text, at), at)
  } else if (event.key === Qt.Key_Delete) {
    if (!cutSelection(field) && at < text.length)
      field.remove(at, ctrl ? wordForward(text, at) : stepForward(text, at))
  } else if (event.text.length > 0 && event.text.charCodeAt(0) >= 0x20
             && event.text.charCodeAt(0) !== 0x7F
             && (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) === 0) {
    cutSelection(field)
    field.insert(field.cursorPosition, event.text)
  } else {
    return false                     // movement, selection, copy: Qt's own
  }
  return true
}
