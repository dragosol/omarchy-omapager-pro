// The sole external-navigation policy. QML JS has no WHATWG URL constructor;
// accept a deliberately narrow ASCII grammar, not every browser URL spelling.
.pragma library
var MAX_APP_NAME=256, MAX_SUMMARY=2048, MAX_BODY=32768, MAX_RAW_BODY=32768
var MAX_ACTIONS=16, MAX_ACTION_LABEL=256, MAX_ACTION_ID=256, MAX_SOURCE=253
var MAX_URL=4096, MAX_CODES=8, MAX_PHONE=64, MAX_HISTORY_ENTRY_BYTES=65536
function bounded(value, max) { return typeof value === 'string' ? value.slice(0,max) : '' }
function containsControlChars(s) { return /[\x00-\x20\x7f-\x9f\\]/.test(s) }
function canonicalHostname(raw) {
  if (typeof raw !== 'string' || raw.length > MAX_SOURCE) return ''
  var h=raw.toLowerCase().replace(/\.$/,'')
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/.test(h)) return ''
  // WHATWG host parsing treats a URL as a numeric (IPv4) address whenever its
  // last label "looks like a number" - not only plain decimal ("127.0.0.1"),
  // but also 0x-prefixed hex ("0x7f.0x0.0x0.0x1" -> 127.0.0.1) and
  // leading-zero octal ("0177.0.0.1"), which a browser's URL parser (and any
  // library replicating it) will canonicalise to a numeric/private address
  // even though this label-shape check alone would pass it through as an
  // ordinary hostname. Octal is already all-decimal-digit and so already
  // matched by the plain digit alternative; hex needs its own alternative.
  if (/^(?:0x[0-9a-f]*|[0-9]+)$/i.test(h.split('.').pop())) return ''
  return h
}
function urlHasUserInfo(s) { return /^[a-z]+:\/\/[^/?#]*@/i.test(s) }
function safeHttpUrl(raw) {
  if (typeof raw !== 'string' || raw.length > MAX_URL || containsControlChars(raw)) return ''
  // Reject nested escapes and encoded controls; never decode and re-authorize.
  if (/%(?:0[0-9a-f]|1[0-9a-f]|7f|25|5c)/i.test(raw) || /[<>"']/.test(raw)) return ''
  var m=raw.match(/^(https?):\/\/([^/?#]+)([^]*)$/i)
  if (!m || urlHasUserInfo(raw)) return ''
  var a=m[2].match(/^([^:%@]+)(?::([0-9]{1,5}))?$/)
  if (!a) return ''
  var h=canonicalHostname(a[1])
  if (!h || (a[2] && (+a[2]<1 || +a[2]>65535))) return ''
  // Invalid escapes can acquire different meaning in different URL handlers.
  if (/%(?![0-9a-f]{2})/i.test(m[3])) return ''
  return m[1].toLowerCase()+'://'+h+(a[2]?':'+String(+a[2]):'')+(m[3]||'/')
}
function safeMailtoUrl(raw) {
  if (typeof raw !== 'string' || raw.length > MAX_URL || containsControlChars(raw)) return ''
  // One address only: no headers, attachments, percent encoding or URI queries.
  var m=raw.match(/^mailto:([a-z0-9.!#$&'*+\/=?^_`{|}~-]{1,64})@([^?\/#]+)$/i)
  if (!m || /[?#]/.test(m[1])) return ''
  var h=canonicalHostname(m[2]); return h ? 'mailto:'+m[1]+'@'+h : ''
}
function safeExternalUrl(raw) { return /^mailto:/i.test(raw) ? safeMailtoUrl(raw) : safeHttpUrl(raw) }
function isAllowedScheme(raw) { return !!safeExternalUrl(raw) }
function hostOf(raw) {
  var u=safeHttpUrl(raw), m=u.match(/^https?:\/\/([^/:?#]+)/)
  return m ? m[1] : ''
}
// Opened by a detached xdg-open, never Qt.openUrlExternally. From Qt 6.12 that
// asks xdg-desktop-portal first, on the GUI thread, and waits up to 25 seconds
// for an answer before falling back to xdg-open - so with a portal that is not
// answering, every click on a link froze the whole shell, notifications and
// bar included, for 25 seconds. `spawn` is the caller's detached launcher
// (Quickshell.execDetached); the URL is already validated and starts with
// http:, https: or mailto:, so it can never read as an option.
var OPEN_URL_COMMAND='/usr/bin/xdg-open'
function openUrlArgv(raw) {
  var safe=safeExternalUrl(raw)
  return safe ? [OPEN_URL_COMMAND, safe] : null
}
function openExternalUrl(raw, spawn) {
  var argv=openUrlArgv(raw)
  if (!argv || typeof spawn !== 'function') return false
  spawn(argv)
  return true
}

// App names are claims, not authentication: any program can send a
// notification as "omarchy-action". So every command here is held to an exact
// shape that is safe whoever sent it. Screenshot editors open one image
// (parseEditorArgv); first-party file/crash actions have their own argument
// rules and go through the activation helper rather than running the hint.
function parseOmarchyExecArgv(value) {
  if (Array.isArray(value)) {
    try { value = JSON.stringify(value) } catch (e) { return null }
  }
  var text = String(value || "")
  if (!text || text.length > MAX_BODY) return null

  var parsed
  try { parsed = JSON.parse(text) } catch (e) { return null }
  if (!Array.isArray(parsed) || parsed.length === 0 || parsed.length > 32) return null
  for (var i = 0; i < parsed.length; i++) {
    if (typeof parsed[i] !== "string" || parsed[i].length > MAX_URL) return null
  }

  var prog = parsed[0]
  if (!prog || prog.charAt(0) === "-") return null
  var base = prog.substring(prog.lastIndexOf("/") + 1)
  if (base === "xdg-open" || base === "omarchy-agent-crash") {
    if (prog !== base && prog !== "/usr/bin/" + base) return null
    if (base === "xdg-open") {
      if (parsed.length !== 2 || !safeLocalFilePath(parsed[1])) return null
      return [base, parsed[1]]
    }
    if (parsed.length < 2 || parsed.length > 5 || !/^[1-9][0-9]{0,9}$/.test(parsed[1])
        || Number(parsed[1]) > 2147483647) return null
    // The stock command supports PID-only diagnosis. Do not let notification
    // metadata become instructions in its agent prompt.
    return [base, parsed[1]]
  }
  return parseEditorArgv(parsed)
}

// A screenshot editor opens one image, and nothing else gets through: no
// option, no second file, no output path. Satty, for one, takes a copy
// command, so an editor allowed any arguments was a way to run a program the
// notification's sender chose. These are exactly the two shapes Omarchy ever
// sent:
//   [editor, /path/to/shot.png]        omarchy-capture-screenshot, Aug 2026
//                                      ($SCREENSHOT_EDITOR "$FILEPATH")
//   [omasnap, file:///path/to/shot.png] omasnap's own "Click to edit"
var EDITORS = /^(?:tensaku-edit|tensaku|satty|swappy|omasnap)$/
var IMAGE_FILE = /\.(?:png|jpe?g|webp)$/i
function parseEditorArgv(parsed) {
  if (!Array.isArray(parsed) || parsed.length !== 2) return null
  var prog = parsed[0], target = parsed[1]
  if (typeof prog !== "string" || typeof target !== "string") return null
  var base = prog.substring(prog.lastIndexOf("/") + 1)
  if (!EDITORS.test(base)) return null
  if (prog !== base && prog !== "/usr/bin/" + base && prog !== "/usr/local/bin/" + base) return null
  if (safeLocalFilePath(target)) return IMAGE_FILE.test(target) ? [prog, target] : null
  // omasnap's form: a file URL, percent-encoded, with nothing after the path.
  if (base !== "omasnap" || !/^file:\/\/\/[A-Za-z0-9%._~!$&'()*+,;=:@\/-]+$/.test(target)) return null
  var path
  try { path = decodeURIComponent(target.substring(7)) } catch (e) { return null }
  return safeLocalFilePath(path) && IMAGE_FILE.test(path) ? [prog, target] : null
}

// Omamail's new-mail notification carries the message a click opens:
// exactly `omarchy-shell shell summon omamail {"accountId","messageId"}`.
// Nothing else from an "Omamail" sender runs - the payload is rebuilt from
// the two ids, so no other summon option (a mailto draft, say) gets through.
function parseOmamailOpenArgv(value) {
  var text = String(value || "")
  if (!text || text.length > MAX_URL) return null
  var parsed
  try { parsed = JSON.parse(text) } catch (e) { return null }
  if (!Array.isArray(parsed) || parsed.length !== 5) return null
  if (parsed[0] !== "omarchy-shell" || parsed[1] !== "shell" || parsed[2] !== "summon"
      || parsed[3] !== "omamail" || typeof parsed[4] !== "string") return null
  var payload
  try { payload = JSON.parse(parsed[4]) } catch (e) { return null }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return null
  var account = payload.accountId, message = payload.messageId
  if (typeof account !== "string" || typeof message !== "string") return null
  if (!account || !message || account.length > 512 || message.length > 2048) return null
  if ((account + message).indexOf(String.fromCharCode(0)) >= 0) return null
  return ["omarchy-shell", "shell", "summon", "omamail",
    JSON.stringify({ accountId: account, messageId: message })]
}

function safeLocalFilePath(path) {
  return typeof path === "string" && path.length <= MAX_URL
      && /^\/[^/]/.test(path) && !/[\x00-\x1f\x7f-\x9f\\]/.test(path)
      && !/\/(?:\.|\.\.)(?:\/|$)/.test(path) && !/\/\//.test(path)
      && path.charAt(path.length - 1) !== "/" && !/\.desktop$/i.test(path)
}
