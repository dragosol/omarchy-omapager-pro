// Omapager - notifications for Omarchy.
//
// This file IS the notification daemon: Quickshell's NotificationServer owns
// org.freedesktop.Notifications, so omarchy.notifications must be listed in
// shell.json's disabledPlugins or the two fight over the bus name.
//
// Stage 1 is deliberately plain: take the bus, hold the notifications, draw one
// card each, expire them, and lose nothing across a restart. The deck, the
// grouping build on the state kept here.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Notifications
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui

import "Store.js" as Store
import "Security.js" as Security
import "Layout.js" as Layout
import "Markup.js" as Markup
import "Gesture.js" as Gesture

Item {
  id: service

  // Injected by omarchy-shell's service loader.
  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string storeBin: Qt.resolvedUrl("bin/omapager-run-store").toString().replace(/^file:\/\//, "")
  readonly property string iconBin: Qt.resolvedUrl("bin/omapager-run-icon").toString().replace(/^file:\/\//, "")

  // Missing website icons are fetched automatically unless the user opts out.
  property bool fetchIcons: true
  property bool requireSandbox: false
  property bool helperSettingsReady: false
  readonly property var helperEnvironment: ({
    OMAPAGER_REQUIRE_SANDBOX: !helperSettingsReady || requireSandbox ? "1" : "0"
  })
  onRequireSandboxChanged: {
    sandboxStatus = ({ required: requireSandbox, sandboxOperational: false, mode: "pending" })
    if (helperSettingsReady) {
      sandboxProbe.running = false
      sandboxProbeDelay.restart()
    }
  }
  property bool allowDefaultActionOnCardClick: false
  property int clipboardTimeout: 60
  property var sandboxStatus: ({ required: false, sandboxOperational: false, mode: "pending" })
  readonly property string helperBin: Qt.resolvedUrl("bin/omapager-run-helper").toString().replace(/^file:\/\//, "")
  Process {
    id: sandboxProbe
    running: false
    environment: service.helperEnvironment
    command: [service.helperBin, "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var result = JSON.parse(text)
          if (service.helperSettingsReady && result.required === service.requireSandbox)
            service.sandboxStatus = result
        } catch (e) {}
      }
    }
  }
  Timer {
    id: sandboxProbeDelay
    interval: 1
    onTriggered: sandboxProbe.running = true
  }
  function setHistoryHours(hours) {
    Store.write(storeProc, storeBin, "policy", {historyHours: hours})
  }

  // Which variant of a site's icon to ask for. Derived from the theme's own
  // notification background rather than a setting: if the card is light, the
  // icon meant for light backgrounds is the one that will read on it.
  readonly property bool lightTheme: {
    var c = Color.notifications.background
    return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.5
  }

  // ------------------------------------------------------------- settings
  // Read from the plugin's shell.json entry once the settings plumbing lands;
  // until then these are the defaults the plan calls for.
  // source by default: a deck per sender, each expanding on its own. One pile
  // for everything is the simpler model but it stops telling you anything the
  // moment two apps are talking at once.
  property string stacking: "source"     // all | source

  // Which end of a card its buttons sit at. Settings plumbing has not landed
  // for plugins yet, so this is a property with an IPC verb, the same as
  // stacking above.
  property real fontScale: 1
  property string actionsAlign: "right"  // right | left

  // Chrome puts a "Settings" action on every web notification, which opens
  // its site-permissions page. It is the same button on every card, it is
  // never the thing you wanted, and it crowds out the ones that are - so it
  // is dropped by default and can be put back.
  property bool hideSettingsAction: true

  property string displayMode: "active"
  property string displayName: ""
  property string deckDisplayName: ""
  readonly property var displayNames: Quickshell.screens.map(function(screen) { return screen.name })
  readonly property string focusedDisplayName: {
    var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    return displayNames.indexOf(name) >= 0 ? name : (displayNames[0] || "")
  }
  readonly property string configuredDisplayName: displayMode === "specific" && displayNames.indexOf(displayName) >= 0
    ? displayName : focusedDisplayName
  readonly property string targetDisplayName: {
    if (displayMode === "specific" && displayNames.indexOf(displayName) >= 0) return configuredDisplayName
    if (displayNames.indexOf(deckDisplayName) >= 0) return deckDisplayName
    return focusedDisplayName
  }
  // A live deck stays put while focus moves. Losing that display moves it to
  // a usable one; a configured specific display remains selected for replug.
  onDisplayNamesChanged: {
    if (deckDisplayName && displayNames.indexOf(deckDisplayName) < 0)
      deckDisplayName = configuredDisplayName
  }
  onDisplayModeChanged: { if (toasts.count > 0) deckDisplayName = configuredDisplayName }
  onDisplayNameChanged: { if (displayMode === "specific" && toasts.count > 0) deckDisplayName = configuredDisplayName }
  function pinDeckDisplay() {
    if (toasts.count === 0) deckDisplayName = configuredDisplayName
  }

  // A verification code is the one thing quiet cannot afford to swallow: you
  // asked for it thirty seconds ago, it expires in five minutes, and no amount
  // of "I'll look later" applies. Codes are only ever detected from a keyword
  // sitting next to a plausible shape, so this is a narrow hole rather than an
  // exception anything can walk through - and it can be closed.
  property bool codesBypassQuiet: true
  function setCodesBypassQuiet(value) {
    if (!!value === codesBypassQuiet) return
    codesBypassQuiet = !!value
    saveQuiet()
  }

  property bool doNotDisturb: false
  property double silencedSince: 0
  function setDoNotDisturb(value) {
    var on = !!value
    if (on === doNotDisturb) return
    if (on) silencedSince = Date.now() / 1000
    doNotDisturb = on
    saveQuiet()
  }

  // The Hyprland portal names all its PipeWire video streams alike: monitor,
  // window and region. Observe their lifetime, not compositor frame activity,
  // which also includes screenshots and VNC and has no startup snapshot.
  property bool offerSnoozeWhenSharing: true
  readonly property var sharingCandidates: {
    var nodes = Pipewire.nodes.values, out = []
    for (var i = 0; i < nodes.length && out.length < 64; i++)
      if (nodes[i].type === PwNodeType.VideoSource) out.push(nodes[i])
    return out
  }
  PwObjectTracker { objects: service.sharingCandidates }
  readonly property int sharingStreams: {
    if (!Pipewire.ready) return 0
    var count = 0
    for (var i = 0; i < sharingCandidates.length; i++) {
      var node = sharingCandidates[i]
      if (!node.ready) continue
      var props = node.properties
      if (props["media.class"] === "Video/Source"
          && String(props["media.name"] || "").indexOf("xdph-streaming-") === 0) count++
    }
    return count
  }
  readonly property bool sharingActive: sharingStreams > 0
  property bool sharingOfferHandled: false
  readonly property bool sharingOfferPending: offerSnoozeWhenSharing && sharingActive
    && !sharingOfferHandled && !doNotDisturb && !globalSnoozeUntil
  readonly property string sharingDetectionStatus: !offerSnoozeWhenSharing ? "Screen-sharing suggestions disabled"
    : !Pipewire.ready ? "Sharing detection unavailable: PipeWire disconnected"
    : sharingActive ? "Screen sharing detected"
    : "No screen sharing detected"
  onSharingActiveChanged: {
    sharingOfferHandled = sharingActive && (doNotDisturb || globalSnoozeUntil > 0)
  }
  onDoNotDisturbChanged: { if (doNotDisturb && sharingActive) sharingOfferHandled = true }
  onGlobalSnoozeUntilChanged: { if (globalSnoozeUntil > 0 && sharingActive) sharingOfferHandled = true }
  function dismissSharingOffer() { if (sharingActive) sharingOfferHandled = true }
  function snoozeSharingOffer(seconds) {
    if (!sharingOfferPending || [1800, 3600, 14400].indexOf(seconds) < 0) return
    sharingOfferHandled = true
    snoozeSource(globalKey, "Everything", seconds, true)
  }
  readonly property int gap: Style.space(6)

  // ------------------------------------------------------------- bar room
  //
  // The deck hangs from the top right corner, so it has to keep clear of the
  // bar on exactly two of the four edges it could be on - and of neither if
  // it is hidden. This used to assume a bar across the top and nothing else:
  // a bar down the right ran straight through the cards, a bar at the bottom
  // pushed them a bar's height down from a top edge with nothing on it, and a
  // hidden bar still had room left for it.
  readonly property var barRef: shell && shell.bar ? shell.bar : null
  readonly property string barPosition: barRef ? String(barRef.position || "top") : "top"
  readonly property bool barVertical: barPosition === "left" || barPosition === "right"
  readonly property int barThickness: {
    if (!barRef || barRef.barHidden) return 0
    var size = Number(barRef.barSize || 0)
    if (size > 0) return size
    return barVertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
  }
  readonly property int notificationWidth: Style.space(380)
  property int edgeSpacing: 12
  property bool showCountdown: false

  // Clear the bar only on the edge it occupies; keep the configured gap on
  // both edges of the top-right notification deck.
  readonly property int barClearance: (barPosition === "top" ? barThickness : 0) + edgeSpacing
  readonly property int edgeClearance: (barPosition === "right" ? barThickness : 0) + edgeSpacing

  readonly property int lowDuration: 5000
  readonly property int normalDuration: 8000
  readonly property int maxDuration: 30000

  function durationFor(urgency, requested) {
    if (urgency === NotificationUrgency.Critical) return 0        // never expires
    var base = urgency === NotificationUrgency.Low ? lowDuration : normalDuration
    if (requested > 0) return Math.min(requested, maxDuration)
    return base
  }

  // ------------------------------------------------------------- snooze
  //
  // Silencing one source instead of the whole desktop. The key is the row's
  // group key, so it is per site for anything arriving through a browser
  // ("web:app.slack.com") and per app for everything else - which is what
  // "snooze Slack" has to mean on a desktop where Slack is a tab in Chrome.
  //
  // A snoozed notification is still recorded: it goes to history the way a
  // silenced one does, so "what did I miss" survives the decision to not be
  // interrupted by it.
  property var snoozes: ({})        // groupKey -> { until: epoch seconds, label }

  // How long "snooze" is allowed to mean. Minutes, or the literal "tomorrow",
  // which is the one choice that is not a duration at all - it is a time, and
  // what time depends on when you start work. Both come from the widget's
  // settings; these are the defaults.
  property var snoozeChoices: ["30", "60", "240", "tomorrow"]
  property int wakeHour: 8

  // "40 minutes", "An hour", "4 hours" - and a short form for somewhere that
  // only has room for a chip.
  function durationWords(minutes) {
    if (minutes < 60) return minutes + " minutes"
    var hours = minutes / 60
    if (hours === 1) return "an hour"
    return (Math.round(hours * 10) / 10) + " hours"
  }

  function shortWords(minutes) {
    return minutes < 60 ? (minutes + "m") : ((Math.round(minutes / 6) / 10) + "h").replace(".0h", "h")
  }

  // One choice, worked out against the clock as it is now: "tomorrow" is a
  // different number of seconds at every hour of the day.
  function snoozeOption(choice) {
    var value = String(choice || "")
    if (value === "tomorrow") {
      var wake = new Date()
      wake.setDate(wake.getDate() + 1)
      wake.setHours(Math.max(0, Math.min(23, wakeHour)), 0, 0, 0)
      return { short: "Tomorrow", menuLabel: "Snooze until tomorrow",
               seconds: Math.max(600, Math.round((wake.getTime() - Date.now()) / 1000)) }
    }
    var minutes = Number(value)
    if (!(minutes > 0)) return null
    return { short: shortWords(minutes), menuLabel: "Snooze for " + durationWords(minutes),
             seconds: Math.round(minutes * 60) }
  }

  readonly property var snoozeOptions: {
    var out = []
    for (var i = 0; i < snoozeChoices.length; i++) {
      var option = snoozeOption(snoozeChoices[i])
      if (option) out.push(option)
    }
    return out
  }
  // snoozes is a plain map, so nothing re-evaluates when it changes; this is
  // what the bar indicator and the panel are bound through.
  property int snoozeRevision: 0

  // Snoozing everything is the same mechanism under a key no source can have.
  // It persists, prunes and restores with the rest, and the panel only has to
  // know to leave it out of the source list.
  readonly property string globalKey: "*"
  readonly property double globalSnoozeUntil: { snoozeRevision; return snoozedUntil(globalKey) }

  function snoozedUntil(groupKey) {
    var entry = snoozes[String(groupKey || "")]
    var until = entry ? Number(entry.until || 0) : 0
    return until > Date.now() / 1000 ? until : 0
  }

  // Soonest to wake first, which is the order the panel lists them in.
  function liveSnoozes() {
    snoozeRevision
    var now = Date.now() / 1000, out = []
    for (var key in snoozes) {
      if (key === globalKey) continue
      var entry = snoozes[key]
      if (!entry || Number(entry.until || 0) <= now) continue
      out.push({ key: key, label: String(entry.label || key), until: Number(entry.until) })
    }
    out.sort(function(a, b) { return a.until - b.until })
    return out
  }

  readonly property int snoozeCount: { snoozeRevision; return liveSnoozes().length }

  // Including the global one, which liveSnoozes() deliberately leaves out -
  // the source list has no row for it. Anything that has to keep running while
  // something is asleep has to watch this rather than the count, or a snooze
  // of everything is a snooze nothing is ticking for.
  readonly property bool anySnooze: { snoozeRevision; return snoozeCount > 0 || globalSnoozeUntil > 0 }

  // `fromNow` re-snoozes rather than extends. Picking "4 hours" from the panel
  // means the source comes back in four hours - not four hours after whatever
  // was already left on it, which would make the number on the button a lie.
  function snoozeSource(groupKey, label, seconds, fromNow) {
    var key = String(groupKey || "")
    if (!key || !(seconds > 0)) return 0
    // Snoozing everything supersedes silencing it. It is the same quiet with
    // an end on it, and the end is the entire point - so it becomes the state,
    // rather than hiding behind a silence that outranks it in every place the
    // state is drawn. Leaving both on showed a red bell over a countdown
    // nobody could see.
    if (key === globalKey) setDoNotDisturb(false)
    var from = fromNow ? Date.now() / 1000
                       : Math.max(Date.now() / 1000, snoozedUntil(key))
    var next = {}
    for (var k in snoozes) next[k] = snoozes[k]
    // `since` is when this quiet period began. Without it the panel would
    // list everything the source has ever had held back, including what it
    // held during a snooze you ended last week.
    var since = (next[key] && snoozedUntil(key)) ? Number(next[key].since || 0)
                                                 : Date.now() / 1000
    next[key] = { until: from + seconds, label: String(label || key), since: since }
    snoozes = next
    snoozeRevision += 1
    saveQuiet()
    // Anything from that source already on screen goes now: leaving it there
    // is the opposite of what was just asked for.
    var keys = []
    for (var i = 0; i < toasts.count; i++) {
      var row = toasts.get(i)
      if (String(row.groupKey || "") === key) keys.push(row.key)
    }
    for (var j = 0; j < keys.length; j++) closeToast(keys[j], "snoozed")
    return next[key].until
  }

  function unsnooze(groupKey) {
    var next = {}
    for (var k in snoozes) if (k !== String(groupKey)) next[k] = snoozes[k]
    snoozes = next
    snoozeRevision += 1
    saveQuiet()
  }

  function unsnoozeAll() {
    snoozes = ({})
    snoozeRevision += 1
    saveQuiet()
  }

  // Silencing outlives a shell restart, the way the built-in service's does.
  // It has to: nothing on screen says the desktop is quiet, so a silence that
  // quietly lifts itself when the shell reloads is a silence you cannot rely
  // on - and one that stays on when you thought it had gone is worse.
  function saveQuiet() {
    Store.write(storeProc, storeBin, "quiet-save",
                { snoozes: snoozes, dnd: doNotDisturb, silencedSince: silencedSince,
                  codesBypassQuiet: codesBypassQuiet })
  }

  // A small session-only reading stack for notifications that were not quietened.
  // Keep text snapshots, never the live Notification objects or their actions.
  property var recentRows: []
  readonly property int recentLimit: 20

  function rememberRecent(row) {
    var key = String(row.key), rows = []
    if (!doNotDisturb && !globalSnoozeUntil && !snoozedUntil(row.groupKey)) {
      // Keep source matching separate from the redacted display text. A digest
      // avoids retaining a sender-supplied code in a raw source/group label.
      var sourceKey = Qt.md5(String(row.groupKey || ""))
      row = Store.sanitiseForPersistence(row)
      rows.push({
        key: key, sourceKey: sourceKey,
        source: String(row.source || row.app || "Notification").slice(0, 120),
        summary: String(row.summary || "").slice(0, 240),
        bodyLine: String(row.bodyLine || "").slice(0, 1000),
        ts: Number(row.ts)
      })
    }
    // A replacement may change to a snoozed source: remove its old entry even
    // when the new version belongs only in Held Back.
    for (var i = 0; i < recentRows.length && rows.length < recentLimit; i++) {
      if (recentRows[i].key !== key) rows.push(recentRows[i])
    }
    recentRows = rows
  }

  function recentForPanel(limit) {
    snoozeRevision
    if (doNotDisturb || globalSnoozeUntil) return []
    var excluded = Object.create(null), snoozed = liveSnoozes()
    for (var i = 0; i < snoozed.length; i++) excluded[Qt.md5(snoozed[i].key)] = true
    var rows = []
    for (var j = 0; j < recentRows.length && rows.length < limit; j++) {
      if (!excluded[recentRows[j].sourceKey]) rows.push(recentRows[j])
    }
    return rows
  }

  // ------------------------------------------------------- what was held
  //
  // A notification that never reached the screen is the one you most want to
  // be able to look at: "quiet" is only tolerable if you can see what it cost.
  // Read on demand rather than kept up to date - the panel is the only thing
  // that asks, and it asks when it opens.
  property var heldRows: []
  property int heldRevision: 0
  property int heldLimit: 80          // read from the store; the panel shows far fewer

  function refreshHeld() { if (helperSettingsReady && !heldProc.running) heldProc.running = true }

  Process {
    id: heldProc
    environment: service.helperEnvironment
    running: false
    command: [service.storeBin, "held", String(service.heldLimit)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        service.heldRows = Store.parseList(text)
        service.heldRevision += 1
      }
    }
  }

  // ---------------------------------------------------- notification history
  //
  // The full log on disk, not the session's memory of it (recentRows above):
  // every closed notification the store still has, newest first, redacted the
  // same way on the way in. Read on demand like Held - the panel is the only
  // thing that ever asks, and it asks when it opens. The store itself already
  // caps this at 100 and trims by historyHours, so this mirrors that ceiling
  // rather than inventing a second one.
  property var historyRows: []
  property int historyRevision: 0
  property int historyLimit: 100

  function refreshHistory() { if (helperSettingsReady && !historyProc.running) historyProc.running = true }

  Process {
    id: historyProc
    environment: service.helperEnvironment
    running: false
    command: [service.storeBin, "history", String(service.historyLimit)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        service.historyRows = Store.parseList(text)
        service.historyRevision += 1
      }
    }
  }

  // When the quiet that is holding this source began. Everything older than
  // that was held by some earlier decision and is not what you are asking
  // about now.
  function quietSince(groupKey) {
    var entry = snoozes[String(groupKey || "")]
    var mine = entry && snoozedUntil(groupKey) ? Number(entry.since || 0) : 0
    var global = globalSnoozeUntil ? Number((snoozes[globalKey] || {}).since || 0) : 0
    var silence = doNotDisturb ? silencedSince : 0
    // The earliest of the reasons currently in force: if the desktop has been
    // silent for an hour and this source was snoozed ten minutes ago, the hour
    // is the honest window.
    var starts = [mine, global, silence].filter(function(t) { return t > 0 })
    return starts.length ? Math.min.apply(null, starts) : 0
  }

  function heldFor(groupKey, limit) {
    heldRevision
    var since = quietSince(groupKey)
    var out = []
    for (var i = 0; i < heldRows.length && out.length < limit; i++) {
      var row = heldRows[i]
      if (String(row.groupKey || "") !== String(groupKey)) continue
      if (since && Number(row.ts || 0) < since) continue
      out.push(row)
    }
    return out
  }

  // Every source being kept quiet right now, with what it has held. Sources
  // that are snoozed by name come first and keep their own wake time; after
  // them come the ones that are only quiet because everything is, and they
  // are here because they actually held something.
  function quietSources(limit) {
    snoozeRevision; heldRevision
    var rows = [], seen = {}
    var snoozed = liveSnoozes()
    var i, key
    for (i = 0; i < snoozed.length && rows.length < limit; i++) {
      seen[snoozed[i].key] = true
      rows.push({ key: snoozed[i].key, label: snoozed[i].label, until: snoozed[i].until,
                  held: heldFor(snoozed[i].key, heldPerSource) })
    }
    if (!doNotDisturb && !globalSnoozeUntil) return rows
    for (i = 0; i < heldRows.length && rows.length < limit; i++) {
      key = String(heldRows[i].groupKey || "")
      if (!key || seen[key]) continue
      var held = heldFor(key, heldPerSource)
      if (!held.length) continue
      seen[key] = true
      rows.push({ key: key, label: String(heldRows[i].source || heldRows[i].app || key),
                  until: 0, held: held })
    }
    return rows
  }

  // Caps, so a fortnight of silence does not turn the panel into a log file.
  property int sourceLimit: 8
  property int heldPerSource: 10

  // Wakes the bindings so a snooze that has run out stops being counted, and
  // drops it from the map so the file does not collect the past. Only runs
  // while something is actually snoozed.
  Timer {
    interval: 20000
    repeat: true
    running: service.anySnooze
    onTriggered: {
      var now = Date.now() / 1000, next = {}, dropped = false
      for (var k in service.snoozes) {
        if (Number(service.snoozes[k].until || 0) > now) next[k] = service.snoozes[k]
        else dropped = true
      }
      if (dropped) { service.snoozes = next; service.saveQuiet() }
      service.snoozeRevision += 1
    }
  }

  // ------------------------------------------------------------- state
  //
  // The live Notification objects stay in a plain JS map, never in the model.
  // A QObject in a ListModel role becomes a dangling C++ pointer the moment
  // the server destroys it, and the next read of that role takes the shell
  // down inside QQmlListModel::data. A map only holds a wrapper, so a stale
  // entry throws where we can catch it.
  property var refs: ({})
  property int keySeed: 0

  ListModel {
    id: toasts
    onCountChanged: { if (count === 0) service.deckDisplayName = "" }
  }

  // ------------------------------------------------------ live capacity
  //
  // One reservation follows each row through held, deferred and visible states.
  // Its pending snapshot is replaced in place; callbacks retain the reservation
  // identity so closing a row cannot resurrect it, even if its key is reused.
  readonly property int maxLiveNotifications: 100
  property var liveKeys: Object.create(null)

  function liveCount() { return Object.keys(liveKeys).length }

  function reserveLive(key) {
    if (!key) return false
    if (liveKeys[key]) return true
    if (liveCount() >= maxLiveNotifications) return false
    liveKeys[key] = { originalId: 0, row: null, scheduled: false, held: false }
    return true
  }

  function releaseLive(key) {
    if (!liveKeys[key]) return
    delete liveKeys[key]
    held = held.filter(function(heldKey) { return heldKey !== key })
  }

  // ------------------------------------------------------------- icons
  //
  // Resolved once per source and remembered, so a chatty Slack does not spawn
  // a lookup per message. The answer is written back onto every row that
  // shares the source, and persisted, so history and restarts keep it.
  property var iconCache: ({})
  property var iconQueue: []
  property string iconWanted: ""

  function setFetchRemoteIcons(enabled) {
    if (fetchIcons === enabled) return
    fetchIcons = enabled
    // Cancelling the wrapper also stops its child. Do not accept a late result
    // from a request the user just disabled; retry that source without fetching.
    if (!enabled && iconProc.running && iconProc.fetchAllowed) {
      iconProc.cancelled = true
      iconProc.running = false
    }
    if (enabled) {
      // A local-only lookup may have cached the browser fallback. Resolve again
      // so enabling fetching can replace it with the website's own icon.
      iconCache = ({})
      for (var i = 0; i < toasts.count; i++) wantIcon(toasts.get(i))
    }
    pumpIcons()
  }

  function wantIcon(row) {
    // A file the sender handed over is an icon we can keep. A live handle is
    // not: "image://qsimage/12/1" is raw pixels held inside this shell, it
    // dies with it, and KDE Connect sends one for every notification it
    // forwards - 111 of 122 here. Skipping the lookup for those meant the
    // phone's apps never resolved an icon of their own, so anything the handle
    // could not draw fell back to a letter for good. Resolve one anyway; the
    // card prefers the sender's pixels while they work and keeps this in
    // reserve.
    if (String(row.image || "").indexOf("image://") !== 0 && String(row.image || "")) return
    var key = String(row.groupKey || row.source || row.app || "")
    if (!key) return
    if (iconWanted === key) return
    if (iconCache[key] !== undefined) {
      // Write it onto the row in hand as well as onto the model. This is
      // called before the row is inserted, so applyIcon - which walks the
      // model - cannot see it: the first notification from a source got its
      // icon (resolved after the insert, asynchronously) and every later one
      // from the same source fell back to a letter, because by then the answer
      // was cached and arrived too early.
      if (iconCache[key]) {
        row.stored_image = iconCache[key]
        applyIcon(key, iconCache[key])
      }
      return
    }
    for (var i = 0; i < iconQueue.length; i++) if (iconQueue[i].key === key) return
    if (iconQueue.length >= 100) return
    iconQueue.push({ key: key, app: String(row.app || ""),
                     appIcon: String(row.appIcon || ""),
                     source: String(row.source || "") })
    pumpIcons()
  }

  function pumpIcons() {
    if (!helperSettingsReady || iconProc.running || iconWanted !== "" || iconQueue.length === 0) return
    var job = iconQueue.shift()
    iconWanted = job.key
    iconProc.job = job
    iconProc.fetchAllowed = fetchIcons
    iconProc.cancelled = false
    var args = [iconBin, "--key=" + job.key, "--app=" + job.app,
                "--app-icon=" + job.appIcon, "--source=" + job.source,
                "--scheme", service.lightTheme ? "light" : "dark"]
    if (fetchIcons) args.push("--fetch")
    iconProc.command = args
    iconProc.running = true
  }

  function applyIcon(key, path) {
    for (var i = 0; i < toasts.count; i++) {
      var row = toasts.get(i)
      if (String(row.groupKey || row.source || row.app || "") !== key) continue
      if (row.stored_image === path) continue
      toasts.setProperty(i, "stored_image", path)
      var copy = {}
      for (var k in row) copy[k] = row[k]
      copy.stored_image = path
      Store.write(storeProc, storeBin, "put", copy)
    }
    // The missed panel's rows are history, not live: drawn with the icon,
    // never written back.
    for (var j = 0; j < missed.count; j++) {
      var old = missed.get(j)
      if (String(old.groupKey || old.source || old.app || "") === key && old.stored_image !== path)
        missed.setProperty(j, "stored_image", path)
    }
  }

  Process {
    id: iconProc
    environment: service.helperEnvironment
    property var job: null
    property bool fetchAllowed: false
    property bool cancelled: false
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var job = iconProc.job
        var path = iconProc.cancelled ? "" : String(text || "").trim()
        if (!iconProc.cancelled) {
          service.iconCache[service.iconWanted] = path
          if (path) service.applyIcon(service.iconWanted, path)
        }
        if (job && (iconProc.cancelled || (!iconProc.fetchAllowed && service.fetchIcons))) {
          if (service.iconQueue.length < 100) service.iconQueue.unshift(job)
        }
        service.iconWanted = ""
        iconProc.job = null
        iconProc.cancelled = false
        Qt.callLater(service.pumpIcons)
      }
    }
  }

  // Sender files are decoded outside the shell. Jobs belong to a particular
  // snapshot, not a source group: a replacement must not inherit a late image.
  property var senderImageQueue: []
  property int senderImageRevision: 0

  function wantSenderImage(row) {
    var reservation = liveKeys[row.key]
    if (!reservation) return
    var source = String(row.image || "")
    var job = source.indexOf("image://icon//") === 0
            ? { key: row.key, source: source, image: "" } : null
    if (!job && !reservation.senderImage) return
    reservation.senderImage = job
    senderImageRevision += 1
    senderImageQueue = senderImageQueue.filter(function(pending) {
      return liveKeys[pending.key] && liveKeys[pending.key].senderImage === pending
    })
    if (job && senderImageQueue.length < maxLiveNotifications) senderImageQueue.push(job)
    pumpSenderImages()
  }

  function senderImageFor(key, source, revision) {
    var job = liveKeys[key] && liveKeys[key].senderImage
    return job && job.source === source ? job.image : ""
  }

  function finishSenderImage(job, image) {
    if (!job || !liveKeys[job.key] || liveKeys[job.key].senderImage !== job) return
    if (image.length > 131072 || !/^data:image\/png;base64,[A-Za-z0-9+/]+={0,2}$/.test(image)) return
    job.image = image
    senderImageRevision += 1
  }

  function pumpSenderImages() {
    if (!helperSettingsReady || senderImageProc.running) return
    while (senderImageQueue.length) {
      var job = senderImageQueue.shift()
      if (!liveKeys[job.key] || liveKeys[job.key].senderImage !== job) continue
      senderImageProc.job = job
      senderImageProc.output = ""
      senderImageProc.overflow = false
      senderImageProc.stdinEnabled = true
      senderImageProc.running = true
      senderImageProc.write(job.source.substring("image://icon/".length))
      senderImageProc.stdinEnabled = false
      return
    }
  }

  Process {
    id: senderImageProc
    environment: service.helperEnvironment
    command: [service.iconBin, "--sender-image"]
    property var job: null
    property string output: ""
    property bool overflow: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (senderImageProc.overflow) return
        if (senderImageProc.output.length + chunk.length > 131072) {
          senderImageProc.overflow = true
          senderImageProc.output = ""
        } else senderImageProc.output += chunk
      }
    }
    onExited: function(code, status) {
      if (code === 0 && !overflow) service.finishSenderImage(job, output)
      job = null
      output = ""
      Qt.callLater(service.pumpSenderImages)
    }
  }

  // A single clock the cards' relative times hang off. Per-card timers would
  // be a dozen wakeups a minute to move the word "now" to "1m".
  property double nowTick: Date.now()
  Timer { interval: 20000; repeat: true; running: toasts.count > 0
          onTriggered: service.nowTick = Date.now() }

  // ------------------------------------------------------------- the deck
  //
  // Expansion is pointer containment, not a click, and it survives a short
  // trip outside: crossing a gap between two cards should not slam the deck
  // shut in your face.
  property bool pointerIn: false
  property bool expanded: false
  property string openDeck: ""
  property string hoverKey: ""     // the card under the pointer, when open
  property real hoverX: -1         // where it is, in the deck's coordinates
  property real hoverY: -1

  property var heights: ({})          // key -> measured card height
  property int layoutRevision: 0

  Timer {
    id: collapseGrace
    interval: 120
    onTriggered: {
      service.commit(function() { service.expanded = false; service.openDeck = "" })
      // Back to the top: the newest notification is the one a shut deck
      // shows, so a deck left scrolled would reopen somewhere in the middle.
      if (service.scrollY > 0) scrollHome.restart()
      service.releaseHeld()
    }
  }

  // Notifications that arrived while the deck was held. A card appearing
  // under the pointer moves everything below it by one place, which is
  // maddening when you are part-way through reading the card it lands on.
  property var held: []

  // Held only while the pointer is genuinely on the deck, or mid-drag. Keying
  // this off `expanded` alone was wrong: the deck can be expanded with no
  // pointer anywhere near it - the IPC verb does exactly that - and then
  // nothing ever "leaves", so arrivals queue up invisibly until the 30-second
  // safety valve fires. A notification held because of a pointer that is not
  // there is just a lost notification.
  // ...and while an answer is being typed. A card arriving above the one you
  // are replying to moves the field out from under the cursor mid-sentence.
  function holding() { return (pointerIn && expanded) || replyingKey !== "" }

  function releaseHeld() {
    if (!held.length) return
    var queue = held
    held = []
    for (var i = 0; i < queue.length; i++) {
      var pending = liveKeys[queue[i]]
      if (!pending || !pending.row) continue
      pending.held = false
      service.showRow(pending.row)
    }
  }

  // Nothing waits forever: a pointer parked over the deck should not silence
  // the machine.
  Timer {
    id: heldTooLong
    interval: 30000
    running: service.held.length > 0
    onTriggered: service.releaseHeld()
  }

  function pointerEntered(deckKey) {
    collapseGrace.stop()
    if (expanded && (deckKey === undefined || openDeck === deckKey)) return
    commit(function() {
      service.expanded = true
      if (deckKey !== undefined) service.openDeck = deckKey
    })
  }
  function pointerLeft() { collapseGrace.restart() }

  // ------------------------------------------------------------ gestures
  //
  // Two fingers across a card carry it towards the screen edge; let go past a
  // third of the way, or flick, and it is thrown. The card wearing a group's
  // count carries the whole group - the number is the handle, and a card
  // without one only ever takes itself. Two fingers up and down scroll a deck
  // taller than the screen, which is the only way to reach the bottom of one.
  //
  // What arrives is a stream of scroll deltas; Gesture.js decides what they
  // mean. The cards move on `swipeX` directly rather than on the scene clock:
  // this is the pointer's motion, one to one, and the clock is for things the
  // layout decides.
  property var gesture: null          // Gesture state while fingers are down
  property var swipeKeys: []          // the cards the fingers are carrying
  property real swipeX: 0             // how far, as drawn
  property int swipeRevision: 0       // swipeKeys and thrown are plain maps
  property var thrown: ({})           // key -> true: flung off, now leaving
  property var lastWheel: ({})        // the last event, for probe
  property var wheelLog: []           // the last few, for probe

  // Where a card is drawn sideways. A thrown card stays thrown until its row
  // is gone: snapping it back to the deck to fade out there would replay the
  // swipe in reverse.
  function swipeOffsetFor(key, revision) {
    if (thrown[key]) return notificationWidth + Style.space(24)
    return swipeKeys.indexOf(key) >= 0 ? swipeX : 0
  }

  // What a swipe starting on this card carries: the group, when this is the
  // card that wears its count; otherwise just the card.
  function swipeTargets(key) {
    var pl = placements[key]
    if (!pl || pl.hidden || leaving[key]) return []
    if ((pl.count || 1) < 2) return [key]
    var group = "", i, row
    for (i = 0; i < toasts.count; i++) {
      row = toasts.get(i)
      if (row.key === key) { group = Layout.groupKeyFor(row); break }
    }
    var out = []
    for (i = 0; i < toasts.count; i++) {
      row = toasts.get(i)
      if (leaving[row.key]) continue
      var at = layout.placements[row.key]
      if (!at || at.deck !== pl.deck) continue
      if (Layout.groupKeyFor(row) === group) out.push(row.key)
    }
    return out.length ? out : [key]
  }

  // How many live cards share this row's group, for the menu's wording.
  function groupSizeOf(key, revision) {
    var group = "", i, row, n = 0
    for (i = 0; i < toasts.count; i++) {
      row = toasts.get(i)
      if (row.key === key) { group = Layout.groupKeyFor(row); break }
    }
    for (i = 0; i < toasts.count; i++) {
      row = toasts.get(i)
      if (!leaving[row.key] && Layout.groupKeyFor(row) === group) n += 1
    }
    return n
  }

  function dismissGroup(key) {
    var group = "", i, row, keys = []
    for (i = 0; i < toasts.count; i++) {
      row = toasts.get(i)
      if (row.key === key) { group = Layout.groupKeyFor(row); break }
    }
    for (i = 0; i < toasts.count; i++) {
      row = toasts.get(i)
      if (Layout.groupKeyFor(row) === group) keys.push(row.key)
    }
    for (i = 0; i < keys.length; i++) closeToast(keys[i], "dismissed")
  }

  readonly property bool swipeBusy: throwRun.running || springRun.running

  // "Clear stack" and the menu's "Dismiss all": the same exit a swipe of the
  // stack's front card makes, so the stack is seen leaving rather than
  // vanishing.
  function throwGroup(key) {
    if (swipeBusy) return
    swipeKeys = swipeTargets(key)
    if (swipeKeys.length < 2) swipeKeys = allOfGroup(key)
    swipeRevision += 1
    swipeX = 0
    throwCarried({ x: 0, vx: 0, axis: "x" })
  }
  function allOfGroup(key) {
    var group = "", i, row, out = []
    for (i = 0; i < toasts.count; i++) {
      row = toasts.get(i)
      if (row.key === key) { group = Layout.groupKeyFor(row); break }
    }
    for (i = 0; i < toasts.count; i++) {
      row = toasts.get(i)
      if (!leaving[row.key] && Layout.groupKeyFor(row) === group) out.push(row.key)
    }
    return out
  }

  NumberAnimation {
    id: throwRun
    target: service; property: "swipeX"
    easing.type: Easing.OutCubic
    onFinished: service.landThrow()
  }

  NumberAnimation {
    id: springRun
    target: service; property: "swipeX"; to: 0
    duration: 260
    easing.type: Easing.OutBack
    easing.overshoot: 1.1
    onFinished: { service.swipeKeys = []; service.swipeRevision += 1 }
  }

  Timer {
    id: fingersUp
    interval: Gesture.IDLE
    onTriggered: service.endGesture()
  }

  function throwCarried(state) {
    throwRun.from = swipeX
    throwRun.to = notificationWidth + Style.space(24)
    throwRun.duration = Gesture.throwDuration(state, notificationWidth)
    throwRun.restart()
  }

  function landThrow() {
    var keys = swipeKeys
    var next = {}
    for (var k in thrown) next[k] = true
    for (var i = 0; i < keys.length; i++) next[keys[i]] = true
    thrown = next
    swipeKeys = []
    swipeX = 0
    swipeRevision += 1
    for (var j = 0; j < keys.length; j++) closeToast(keys[j], "dismissed")
  }

  function endGesture() {
    fingersUp.stop()
    var g = gesture
    gesture = null
    if (!g || g.axis !== "x" || !swipeKeys.length) {
      if (swipeKeys.length && !swipeBusy) { swipeKeys = []; swipeX = 0; swipeRevision += 1 }
      return
    }
    if (Gesture.throws(g, notificationWidth)) throwCarried(g)
    else springRun.restart()
  }

  // One wheel event from the deck. Returns whether it was used. `under` is
  // the card the pointer is on, in the deck's own coordinates.
  function wheel(ev, under) {
    var px = ev.pixelDelta, ang = ev.angleDelta
    var phase = ev.phase === undefined ? -1 : ev.phase
    lastWheel = { px: px.x, py: px.y, ax: ang.x, ay: ang.y, phase: phase,
                  inverted: !!ev.inverted, under: under || "" }
    var log = wheelLog.slice(-40)
    log.push([Math.round(px.x), Math.round(px.y), ang.x, ang.y, phase])
    wheelLog = log

    // Fingers up. Carries no travel of its own.
    if (phase === Qt.ScrollEnd) { endGesture(); return true }

    // A mouse wheel: clicks of rotation, no fingers. It can scroll a deck
    // that does not fit; it never carries a card, because a tilt-wheel
    // nudge throwing a notification away would be an accident every time.
    if (px.x === 0 && px.y === 0) {
      if (phase === Qt.ScrollBegin) return true
      return scrollBy(ang.y / 120 * Style.space(56))
    }

    if (swipeBusy || replyingKey !== "") return true
    if (!gesture) gesture = Gesture.start(Date.now())
    fingersUp.restart()

    // Carrying follows the fingers, whichever way scrolling is set to go -
    // the card is an object being pushed, not a page being scrolled. Qt
    // reports deltas in scroll terms, which natural scrolling has already
    // flipped once. `inverted` is meant to say whether it did, but on
    // Hyprland it is always false, natural or not - so ask Hyprland instead.
    var sign = (ev.inverted || naturalScroll) ? 1 : -1
    var before = gesture.axis
    gesture = Gesture.feed(gesture, px.x * sign, px.y * sign, Date.now())

    if (gesture.axis === "x") {
      if (before !== "x") {
        swipeKeys = swipeTargets(under || hoverKey)
        swipeRevision += 1
      }
      swipeX = swipeKeys.length ? Gesture.drawn(gesture.x) : 0
      return true
    }
    // Scrolling moves the deck the way every other scroll view on the desktop
    // moves, so it takes the delta as Qt reports it.
    if (gesture.axis === "y") return scrollBy(px.y) || true
    return true
  }

  // --------------------------------------------------------- what you missed
  //
  // Two fingers coming onto the touchpad over its right edge pull in what you
  // missed: every notification that left without you dealing with it -
  // timed out, or held back by a snooze or Do Not Disturb. It follows the
  // fingers the whole way in, as Notification Center does on a Mac; let go
  // past the middle, or with a flick, and it stays.
  //
  // Only the device knows where on the pad fingers started, so a small
  // helper reads it (bin/omapager-edge, sandboxed to that one device node)
  // and streams begin / move / end. Reading the touchpad needs a one-time
  // udev rule, install-touchpad-access.sh; without it this is simply off.
  property bool edgeSwipe: true
  property string edgeStatus: "off"     // off | starting | ready | no-access | no-touchpad | unavailable
  readonly property string edgeBin: Qt.resolvedUrl("bin/omapager-run-edge").toString().replace(/^file:\/\//, "")
  // How much of the pad's width pulls the panel fully in. A quarter of a
  // wide laptop pad is about a finger's comfortable sweep.
  readonly property real edgeFull: 0.22

  ListModel { id: missed }
  property int missedCount: 0
  property real missedShown: 0          // 0 away .. 1 fully in, as drawn
  property bool missedOpen: false       // settled in, not following fingers
  property bool missedFollowing: false  // fingers are on it right now
  property bool missedLoaded: false
  property bool missedPointerIn: false
  readonly property bool missedVisible: missedShown > 0.001 || missedOpen
  readonly property int missedLimit: 30

  Process {
    id: edgeProc
    environment: service.helperEnvironment
    running: false
    command: [service.edgeBin]
    stdout: SplitParser { onRead: function(line) { service.edgeLine(String(line)) } }
    onExited: function(code) {
      // 3 is "no touchpad" or "no access", already reported on stdout; asking
      // again every few seconds would not change either. Anything else - the
      // pad vanishing over a suspend - is worth another go.
      if (code === 3 || !service.edgeSwipe) return
      if (service.edgeStatus !== "no-access" && service.edgeStatus !== "no-touchpad")
        service.edgeStatus = code === 1 ? "unavailable" : "starting"
      edgeRetry.restart()
    }
  }
  Timer {
    id: edgeRetry
    interval: 3000
    onTriggered: service.startEdge()
  }
  function startEdge() {
    if (!edgeSwipe || !helperSettingsReady || edgeProc.running) return
    edgeStatus = "starting"
    edgeProc.running = true
  }
  onEdgeSwipeChanged: {
    if (edgeSwipe) startEdge()
    else { edgeRetry.stop(); edgeProc.running = false; edgeStatus = "off" }
  }

  function edgeLine(line) {
    var parts = line.trim().split(/\s+/)
    var verb = parts[0]
    if (verb === "ready" || verb === "no-access" || verb === "no-touchpad") {
      edgeStatus = verb
      return
    }
    if (verb === "begin") beginMissed()
    else if (verb === "move") followMissed(Number(parts[1]) || 0)
    else if (verb === "end") releaseMissed(Number(parts[1]) || 0, Number(parts[2]) || 0)
  }

  // What you missed is read ahead of time, not when you ask for it. Reading
  // it on the swipe meant the store answered after the panel had started
  // moving, and everything but the live cards popped in once it had
  // arrived. Kept fresh a moment after anything closes or is held back -
  // the only times the answer can change.
  property var missedCache: []
  Process {
    id: missedProc
    environment: service.helperEnvironment
    running: false
    command: [service.storeBin, "unseen", String(service.missedLimit)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        service.missedCache = Store.parseList(text)
        service.loadMissed(service.missedCache)
      }
    }
  }
  Timer {
    id: missedPrefetch
    // Long enough for the store's queued close to land first.
    interval: 700
    onTriggered: service.refreshMissed()
  }
  function prefetchMissed() { missedPrefetch.restart() }

  // The panel is everything: what is on screen now, then what you missed.
  //
  // Its cards are built ahead of time and kept, hidden, in step with the
  // deck and the store - never built when the fingers arrive. Building forty
  // cards took a quarter of a second on the thread that draws, which is as
  // long as the whole swipe: the panel could not follow the fingers because
  // nothing was drawn until they had already let go. Opening it now only
  // reveals what exists.
  function panelRow(source, live) {
    var row = Store.normalise(source)
    row.duration = 0                 // nothing in here times out
    row.live = live
    return row
  }

  function panelLiveCount() {
    var n = 0
    for (var i = 0; i < missed.count && missed.get(i).live; i++) n += 1
    return n
  }

  // The live rows at the top, in the deck's order. Normally already true -
  // arrivals and closes keep it so - and then this moves nothing.
  function syncLive() {
    var want = []
    for (var i = 0; i < toasts.count; i++) {
      var row = toasts.get(i)
      if (!leaving[row.key]) want.push(row)
    }
    var keep = {}
    for (var w = 0; w < want.length; w++) {
      keep[want[w].key] = true
      var at = missedIndex(want[w].key)
      if (at < 0) missed.insert(w, panelRow(want[w], true))
      else if (at !== w) missed.move(at, w, 1)
    }
    for (var r = missed.count - 1; r >= want.length; r--)
      if (missed.get(r).live && !keep[missed.get(r).key]) missed.remove(r)
    missedCount = missed.count
    missedRevision += 1
  }

  function startPanel() {
    missedOpenDeck = ""
    missedScroll = 0
    syncLive()
    refreshMissed()                  // only adds what is new since the last read
  }

  // The missed rows below the live ones, in the store's order (newest
  // first), changed in place: moved, inserted or removed, never rebuilt.
  function loadMissed(entries) {
    var listed = {}
    for (var e = 0; e < entries.length; e++) if (entries[e]) listed[entries[e].key] = true
    for (var r = missed.count - 1; r >= 0; r--)
      if (!missed.get(r).live && !listed[missed.get(r).key]) missed.remove(r)
    var p = panelLiveCount()
    for (var i = 0; i < entries.length; i++) {
      var row = Store.restored(entries[i])
      if (!row) continue
      var at = missedIndex(row.key)
      if (at >= 0 && missed.get(at).live) continue      // still on screen
      if (at < 0) {
        row = panelRow(row, false)
        wantIcon(row)                // the source's icon, as a live card gets it
        missed.insert(p, row)
      } else if (at !== p) {
        missed.move(at, p, 1)
      }
      p += 1
    }
    missedCount = missed.count
    missedLoaded = true
    missedRevision += 1
  }

  function joinMissed(row) {
    var at = missedIndex(row.key)
    if (at >= 0) {
      missed.set(at, panelRow(row, true))   // an update to a card already here
    } else {
      missed.insert(0, panelRow(row, true))
    }
    missedCount = missed.count
    missedRevision += 1
  }

  function forgetGone(key) {
    if (!missedGone[key]) return
    var rest = {}
    for (var k in missedGone) if (k !== key) rest[k] = true
    missedGone = rest
    missedGoneRevision += 1
  }

  function leaveMissed(key) {
    forgetGone(key)
    var at = missedIndex(key)
    if (at < 0 || !missed.get(at).live) return
    missed.remove(at)
    missedCount = missed.count
    missedRevision += 1
  }

  function refreshMissed() {
    if (!helperSettingsReady || missedProc.running) return
    missedProc.running = true
  }

  NumberAnimation {
    id: missedSlide
    target: service; property: "missedShown"
    easing.type: Easing.OutCubic
    onFinished: if (service.missedShown <= 0.001) service.missedOpen = false
  }

  function slideMissed(to, duration) {
    missedSlide.stop()
    missedSlide.from = missedShown
    missedSlide.to = to
    missedSlide.duration = duration || 260
    missedSlide.start()
  }

  function beginMissed() {
    if (missedOpen && missedShown >= 0.999) return
    missedFollowing = true
    missedSlide.stop()
    if (!missedOpen) startPanel()
  }

  function followMissed(progress) {
    if (!missedFollowing) return
    missedShown = Math.max(0, Math.min(1, progress / edgeFull))
  }

  // Let go: open if it came more than half way, or was flicked in, and go
  // back out otherwise - from wherever it is, at the speed it was going.
  function releaseMissed(progress, speed) {
    if (!missedFollowing) return
    missedFollowing = false
    followMissed(progress)
    missedFollowing = false
    var open = missedShown > 0.45 || (speed > 0.9 && missedShown > 0.08)
    if (open) {
      missedOpen = true
      slideMissed(1, Math.max(120, 260 * (1 - missedShown)))
      missedAway.restart()
    } else {
      slideMissed(0, Math.max(120, 220 * missedShown))
    }
  }

  function closeMissed() {
    missedAway.stop()
    missedFollowing = false
    slideMissed(0, 220)
  }

  function openMissed() {
    startPanel()
    missedOpen = true
    slideMissed(1, 260)
    missedAway.restart()
  }

  // It goes away by itself when you are done with it: soon after the pointer
  // leaves it, or after a while if the pointer never went there at all. A
  // layer surface never hears about a click somewhere else, which is how a
  // Mac closes it.
  Timer {
    id: missedAway
    interval: service.missedPointerIn ? 0 : (service.missedWasEntered ? 1500 : 9000)
    running: false
    onTriggered: if (!service.missedPointerIn && !service.missedFollowing) service.closeMissed()
  }
  property bool missedWasEntered: false
  onMissedPointerInChanged: {
    if (missedPointerIn) { missedWasEntered = true; missedAway.stop() }
    else {
      missedCollapse.restart()
      if (missedOpen) missedAway.restart()
    }
  }
  onMissedOpenChanged: if (!missedOpen) { missedWasEntered = false; missedPointerIn = false }

  // The list is stacked the way the live deck is: one stack per source,
  // wearing its count, opened by resting the pointer on its front card. A
  // long afternoon of one chatty channel is one card until you ask for it.
  property string missedOpenDeck: ""
  property var missedHeights: ({})
  property int missedRevision: 0
  onMissedOpenDeckChanged: missedRevision += 1
  // A copy of the rows taken once per change, not the model itself: reading
  // the model made this layout re-run in the middle of every insert, while
  // the card being inserted was itself asking for its place in it.
  property var missedRows: []
  onMissedRevisionChanged: {
    var rows = []
    for (var i = 0; i < missed.count; i++) rows.push(missed.get(i))
    missedRows = rows
  }
  readonly property var missedLayout: {
    var rows = missedRows
    return Layout.compute(rows, {
      stacking: "source",
      expanded: missedOpenDeck !== "",
      openDeck: missedOpenDeck,
      gap: gap,
      deckGap: Style.space(11),
      heightOf: function(key) { return service.missedHeights[key] || Style.space(58) }
    })
  }
  // Batched to the end of the event: cards measure themselves while the
  // layout that places them is being built, and bumping the revision from
  // inside that is a loop. One relayout per burst of measurements.
  function noteMissedHeight(key, h) {
    if (Math.abs((missedHeights[key] || 0) - h) < 0.5) return
    missedHeights[key] = h
    Qt.callLater(bumpMissed)
  }
  function bumpMissed() { missedRevision += 1 }
  function openMissedDeck(deckKey) {
    missedCollapse.stop()
    if (missedOpenDeck !== deckKey) missedOpenDeck = deckKey
  }
  // Crossing the gap between two stacks should not slam one shut first.
  Timer {
    id: missedCollapse
    interval: 150
    onTriggered: service.missedOpenDeck = ""
  }

  function missedIndex(key) {
    for (var i = 0; i < missed.count; i++) if (missed.get(i).key === key) return i
    return -1
  }

  // Dealt with: it will not come back on the next swipe. A live card is
  // dismissed as a live card - closing it takes it out of the panel too.
  function seeMissed(keys) {
    if (!keys.length) return
    var stored = []
    for (var i = 0; i < keys.length; i++) {
      var at = missedIndex(keys[i])
      if (at < 0) continue
      if (missed.get(at).live) { closeToast(keys[i], "dismissed"); continue }
      stored.push(keys[i])
      forgetGone(keys[i])
      missed.remove(at)
    }
    if (stored.length) {
      Store.write(storeProc, storeBin, "seen", null, stored)
      missedCache = missedCache.filter(function(entry) { return stored.indexOf(entry.key) < 0 })
    }
    missedCount = missed.count
    missedRevision += 1
    if (!missed.count && missedOpen) closeMissed()
  }

  function dismissMissed(key) { seeMissed([key]) }

  function dismissMissedGroup(key) {
    var at = missedIndex(key)
    if (at < 0) return
    var group = Layout.groupKeyFor(missed.get(at)), keys = []
    for (var i = 0; i < missed.count; i++)
      if (Layout.groupKeyFor(missed.get(i)) === group) keys.push(missed.get(i).key)
    seeMissed(keys)
  }

  function clearMissed() {
    var keys = []
    for (var i = 0; i < missed.count; i++) keys.push(missed.get(i).key)
    seeMissed(keys)
    closeMissed()
  }

  function missedGroupSize(key, revision) {
    var at = missedIndex(key)
    if (at < 0) return 1
    var group = Layout.groupKeyFor(missed.get(at)), n = 0
    for (var i = 0; i < missed.count; i++) if (Layout.groupKeyFor(missed.get(i)) === group) n += 1
    return n
  }

  function activateMissed(key) {
    var at = missedIndex(key)
    if (at < 0) return
    var row = missed.get(at)
    if (row.live) { closeMissed(); activate(key); return }
    var copy = { senderPid: row.senderPid, source: row.source, link: row.link }
    seeMissed([key])
    closeMissed()
    routeRow(copy)
  }

  // Two fingers on the open panel: across a card throws that card away,
  // across the panel's own header pushes the panel back out, up and down
  // scrolls it. The same reading of the fingers as the deck uses.
  property var missedGesture: null
  property string missedSwipeKey: ""     // "" = the panel itself
  property var missedSwipeKeys: []       // what the fingers are carrying
  // Thrown and on their way out: kept off the edge until their row is gone,
  // or a live card - which takes a moment to close - flicks back first.
  property var missedGone: ({})
  property int missedGoneRevision: 0
  property real missedSwipeX: 0
  property real missedScroll: 0
  property string missedHoverKey: ""
  property real missedHoverX: -1
  property real missedHoverY: -1
  property real missedScrollMax: 0
  Timer {
    id: missedFingersUp
    interval: Gesture.IDLE
    onTriggered: service.endMissedGesture()
  }

  function missedWheel(ev, under) {
    var px = ev.pixelDelta, phase = ev.phase === undefined ? -1 : ev.phase
    if (phase === Qt.ScrollEnd) { endMissedGesture(); return true }
    if (px.x === 0 && px.y === 0) {
      scrollMissed(ev.angleDelta.y / 120 * Style.space(56))
      return true
    }
    if (missedSlide.running || throwMissed.running) return true
    if (!missedGesture) { missedGesture = Gesture.start(Date.now()); missedSwipeKey = under || "" }
    missedFingersUp.restart()
    var sign = (ev.inverted || naturalScroll) ? 1 : -1
    missedGesture = Gesture.feed(missedGesture, px.x * sign, px.y * sign, Date.now())
    if (missedGesture.axis === "x") {
      if (missedSwipeKey && !missedSwipeKeys.length) missedSwipeKeys = missedTargets(missedSwipeKey)
      if (missedSwipeKey) missedSwipeX = Gesture.drawn(missedGesture.x)
      else missedShown = Math.max(0, Math.min(1, 1 - Math.max(0, missedGesture.x) / notificationWidth))
    } else if (missedGesture.axis === "y") {
      scrollMissed(px.y)
    }
    return true
  }

  function scrollMissed(dy) {
    missedScroll = Math.max(0, Math.min(missedScrollMax, missedScroll - dy))
  }
  onMissedScrollMaxChanged: if (missedScroll > missedScrollMax) missedScroll = missedScrollMax

  // The front card of a stack wearing its count carries the stack; any
  // other card only itself - the deck's rule.
  function missedTargets(key) {
    var place = missedLayout.placements[key]
    if (!place || (place.count || 1) < 2) return [key]
    var out = []
    for (var k in missedLayout.placements)
      if (missedLayout.placements[k].deck === place.deck) out.push(k)
    return out
  }

  function throwMissedGroup(key) {
    if (throwMissed.running || springMissed.running) return
    missedSwipeKey = key
    missedSwipeKeys = missedTargets(key)
    if (missedSwipeKeys.length < 2) {
      var at = missedIndex(key), keys = []
      if (at >= 0) {
        var group = Layout.groupKeyFor(missed.get(at))
        for (var i = 0; i < missed.count; i++)
          if (Layout.groupKeyFor(missed.get(i)) === group) keys.push(missed.get(i).key)
      }
      missedSwipeKeys = keys.length ? keys : [key]
    }
    missedSwipeX = 0
    throwMissed.from = 0
    throwMissed.to = notificationWidth + Style.space(24)
    throwMissed.duration = 220
    throwMissed.start()
  }

  function endMissedGesture() {
    missedFingersUp.stop()
    var g = missedGesture
    missedGesture = null
    if (!g || g.axis !== "x") return
    if (missedSwipeKey) {
      if (Gesture.throws(g, notificationWidth)) {
        throwMissed.from = missedSwipeX
        throwMissed.to = notificationWidth + Style.space(24)
        throwMissed.duration = Gesture.throwDuration(g, notificationWidth)
        throwMissed.start()
      } else {
        springMissed.start()
      }
      return
    }
    if (Gesture.throws(g, notificationWidth) || missedShown < 0.55) closeMissed()
    else slideMissed(1, 200)
  }

  NumberAnimation {
    id: throwMissed
    target: service; property: "missedSwipeX"
    easing.type: Easing.OutCubic
    onFinished: {
      var keys = service.missedSwipeKeys.length ? service.missedSwipeKeys : [service.missedSwipeKey]
      var gone = {}
      for (var k in service.missedGone) gone[k] = true
      for (var i = 0; i < keys.length; i++) gone[keys[i]] = true
      service.missedGone = gone
      service.missedGoneRevision += 1
      service.missedSwipeKey = ""
      service.missedSwipeKeys = []
      service.missedSwipeX = 0
      service.seeMissed(keys)
    }
  }
  NumberAnimation {
    id: springMissed
    target: service; property: "missedSwipeX"; to: 0
    duration: 260
    easing.type: Easing.OutBack
    onFinished: { service.missedSwipeKey = ""; service.missedSwipeKeys = [] }
  }

  // The same rule as the deck: the card wearing its group's count carries
  // the group.
  function dismissMissedGroupOrOne(key) {
    var place = missedLayout.placements[key]
    if (place && (place.count || 1) > 1) dismissMissedGroup(key)
    else dismissMissed(key)
  }
  function missedFrontOf(key) {
    var at = missedIndex(key)
    if (at < 0) return -1
    var group = Layout.groupKeyFor(missed.get(at))
    for (var i = 0; i < missed.count; i++) if (Layout.groupKeyFor(missed.get(i)) === group) return i
    return -1
  }

  // Whether the touchpad scrolls naturally, from Hyprland itself: Qt's own
  // `inverted` flag never arrives over this compositor. Read at startup and
  // again whenever the config reloads, since that is where it is set.
  property bool naturalScroll: false
  Process {
    id: naturalProbe
    command: ["hyprctl", "-j", "getoption", "input:touchpad:natural_scroll"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var o = JSON.parse(text)
          service.naturalScroll = o.bool === true || Number(o.int) === 1
        } catch (e) {}
      }
    }
  }
  // And the width windows are drawn with, which is what a card's border
  // falls back to when the theme does not give one of its own.
  property int windowBorderWidth: 2
  Process {
    id: borderProbe
    command: ["hyprctl", "-j", "getoption", "general:border_size"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var n = Number(JSON.parse(text).int)
          if (isFinite(n) && n >= 0) service.windowBorderWidth = n
        } catch (e) {}
      }
    }
  }
  Component.onCompleted: { naturalProbe.running = true; borderProbe.running = true }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "configreloaded") { naturalProbe.running = true; borderProbe.running = true }
    }
  }

  // ------------------------------------------------------------- scrolling
  //
  // An open deck of long messages is taller than the screen, and before this
  // the bottom of it - and every deck below - was simply unreachable.
  property real deckRoom: 100000      // what the showing output can fit
  property real scrollY: 0
  readonly property real scrollMax: Math.max(0, layout.height - deckRoom)
  onScrollMaxChanged: if (scrollY > scrollMax) scrollY = scrollMax
  signal scrolled()

  function scrollBy(dy) {
    if (scrollMax <= 0) return false
    scrollHome.stop()
    scrollY = Math.max(0, Math.min(scrollMax, scrollY - dy))
    scrolled()
    return true
  }

  NumberAnimation {
    id: scrollHome
    target: service; property: "scrollY"; to: 0
    duration: service.sceneDuration
    easing.type: Easing.OutCubic
  }

  // A card's target height: what its state implies, never what it currently
  // measures. This moves on a state change - a hover, a reply opening - and
  // not on a frame, so the layout is recomputed on events rather than while
  // things are in flight.
  property int heightNotes: 0        // how often a target height moved the layout

  function noteHeight(key, h) {
    if (Math.abs((heights[key] || 0) - h) < 0.5) return
    commit(function() { service.heights[key] = h; service.heightNotes += 1 })
  }

  // ------------------------------------------------------- the scene clock
  //
  // One clock for the whole deck. Every card's position, scale, opacity and
  // height is a function of three things: where the layout wants it, where it
  // was when that last changed, and how far through the move we are. Cards
  // animate nothing themselves.
  //
  // What this replaces: a Behavior per property per card, each starting
  // whenever its own binding happened to re-evaluate. Because the layout was
  // recomputed from heights that were themselves animating, those Behaviors
  // were retargeted every frame - and a Behavior restarts with its full
  // duration each time, so a card played only the slow opening of its curve
  // until the heights settled, and then jumped.
  readonly property var sceneCurve: [0.21, 1.02, 0.73, 1.0, 1.0, 1.0]
  readonly property int sceneDuration: 320

  property real t: 1                 // 0..1, eased, shared by every card
  property var was: ({})             // where each card was when the target moved
  property real deckWas: 0

  NumberAnimation {
    id: sceneRun
    target: service; property: "t"; from: 0; to: 1
    duration: service.sceneDuration
    easing.type: Easing.Bezier
    easing.bezierCurve: service.sceneCurve
    onFinished: service.sceneSettled()
  }

  // One value of one card, right now. `t` is already eased by the animation
  // above, so this interpolates linearly through it.
  function at(key, what) {
    var target = placements[key]
    if (!target) return 0
    var to = target[what]
    if (t >= 1) return to
    var from = was[key]
    if (!from || from[what] === undefined) return to
    return from[what] + (to - from[what]) * t
  }

  readonly property real deckHeight: t >= 1 ? layout.height
                                            : deckWas + (layout.height - deckWas) * t

  // Everything that changes the scene comes through here: snapshot where every
  // card is *now*, let the layout recompute, and start one move for all of
  // them from the same instant.
  // Where everything is at this instant. This has to be taken *before* the
  // thing that changes the scene - inserting a row, marking one as leaving -
  // because the layout is a binding on those, and after them "where it was"
  // and "where it is going" are the same number, so nothing moves at all.
  function snapshot() {
    var snap = {}
    for (var key in placements)
      snap[key] = { y: at(key, "y"), scale: at(key, "scale"),
                    opacity: at(key, "opacity"), height: at(key, "height"),
                    size: placements[key].size }
    return snap
  }

  // Anything that moves the deck goes through here: take the snapshot, make
  // the change, start one move for all of it.
  //
  // This is the whole discipline. The layout is a binding on `expanded`,
  // `openDeck`, `stacking` and the model, so writing any of them recomputes
  // every placement *immediately* - and if the clock is not started in the
  // same breath, the cards are simply already there. Expanding the deck did
  // exactly that: it was one frame, because nothing told the scene it had
  // happened.
  function commit(change) {
    var snap = snapshot(), deckNow = deckHeight
    change()
    retarget(undefined, undefined, snap, deckNow)
  }

  function retarget(seedKey, seed, snap, deckNow) {
    if (!snap) { snap = snapshot(); deckNow = deckHeight }
    // A card that has just arrived has nowhere to have been, so it is told:
    // under the bar, transparent. It comes down in the same move everything
    // else is making rather than in an animation of its own.
    if (seedKey) snap[seedKey] = seed
    deckWas = deckNow
    was = snap
    layoutRevision += 1          // the layout is a binding on this
    t = 0
    sceneRun.restart()
  }

  // Where a leaving card sits while it fades: exactly where it was. The others
  // close over it in the same move.
  function restingPlace(key) {
    var prev = was[key]
    // front: true so it keeps its text on the way out. A card behind the front
    // one in a collapsed deck draws no content - correct while it is a peek of
    // an edge, wrong for one that is fading in place, which blanked itself for
    // a frame and read as a flash.
    return { y: prev ? prev.y : 0, scale: prev ? prev.scale : 1, opacity: 0,
             height: prev ? prev.height : 0, z: 2000, front: true,
             hidden: false, count: 1,
             // The deck it was in, as far as the card's own sizing goes: a
             // card that changed its line count on the way out would move
             // the layout it is supposed to be leaving quietly.
             size: prev ? prev.size : 1 }
  }

  // A row on its way out keeps its place in the model until the move that
  // closes the gap has finished, so the fade and the gap are one motion
  // rather than a fade, then a hole, then a jump.
  function sceneSettled() {
    var keys = []
    for (var key in leaving) keys.push(key)
    if (!keys.length) return
    for (var i = 0; i < keys.length; i++) finishClose(keys[i], leaving[keys[i]])
    // Nothing should move now: the gap closed while they faded, so the rows
    // that remain are already where the recomputed layout wants them. Pin
    // them there, or the recompute reads as a move from a stale snapshot.
    var snap = {}
    for (var k in placements)
      snap[k] = { y: placements[k].y, scale: placements[k].scale,
                  opacity: placements[k].opacity, height: placements[k].height }
    was = snap
    t = 1
  }

  readonly property var layout: {
    layoutRevision                      // recompute when the scene retargets
    var rows = []
    for (var i = 0; i < toasts.count; i++) {
      var row = toasts.get(i)
      if (!leaving[row.key]) rows.push(row)   // a card on its way out takes no space
    }
    return Layout.compute(rows, {
      stacking: stacking,
      expanded: expanded,
      openDeck: stacking === "source" ? openDeck : undefined,
      gap: gap,
      deckGap: Style.space(11),
      heightOf: function(key) { return service.heights[key] || Style.space(58) }
    })
  }

  // The layout above only knows about cards that are staying. Everything on
  // its way out is pinned where it was, fading, taking no room.
  //
  // Copied, not borrowed. `layout.placements` belongs to the binding above,
  // and writing the leaving cards straight into it meant this binding mutated
  // its own input while reading it: Qt saw `layout` change mid-evaluation,
  // re-ran `placements`, and the two chased each other - a hundred binding-loop
  // warnings per scene, and the work behind them on the frames the animation
  // is trying to keep smooth. It also left cards that had finished leaving
  // sitting inside `layout.placements` until the next retarget cleared them.
  readonly property var placements: {
    var out = {}
    var base = layout.placements
    for (var k in base) out[k] = base[k]
    for (var key in leaving) out[key] = restingPlace(key)
    return out
  }


  // Our own identity for a notification. The sender's id is reused (that is
  // what replaces_id is for), so it identifies a slot, not an event.
  function nextKey() {
    var key
    do {
      keySeed += 1
      key = "n" + Date.now().toString(36) + keySeed.toString(36)
    } while (liveKeys[key])
    return key
  }

  function rowIndexFor(key) {
    for (var i = 0; i < toasts.count; i++)
      if (toasts.get(i).key === key) return i
    return -1
  }

  // id 0 means "this is a new notification", not "replace the one with id 0".
  // Matching on it made every notify-send take over whichever restored row
  // happened to have no id.
  function keyForOriginal(id) {
    if (!id) return ""
    for (var key in liveKeys)
      if (liveKeys[key].originalId === id && refs[key]) return key
    return ""
  }

  // ------------------------------------------------------------- arrival
  function handleNotification(notification) {
    // Replacements reuse the same slot, including before its first insertion.
    var key = keyForOriginal(notification.id) || nextKey()

    // Without this the object is destroyed as soon as this handler returns,
    // taking the actions and the image with it.
    if (!reserveLive(key)) {
      notification.tracked = false
      return
    }
    liveKeys[key].originalId = notification.id || 0
    notification.tracked = true

    var row = Store.snapshot(notification, key, NotificationUrgency)
    row.duration = durationFor(notification.urgency, row.expireTimeout)
    rememberRecent(row)

    var previous = refs[key]
    refs[key] = notification
    // refs is a plain map, so nothing watching it re-evaluates on its own. The
    // card's action buttons are bound through this counter, or they would be
    // read once - before the sender was recorded - and stay empty forever.
    refsRevision += 1
    if (previous !== notification) watchNotification(notification, key)
    if (previous && previous !== notification) {
      try { previous.tracked = false } catch (e) {}
    }

    // Silenced or snoozed still means recorded: "what did I miss" is the whole
    // point of a store. It goes straight to history without being on screen.
    // A sharing offer never changes delivery; only an explicit snooze does.
    var muted = doNotDisturb ? "silenced"
              : (globalSnoozeUntil || snoozedUntil(row.groupKey)) ? "snoozed" : ""
    if (muted && codesBypassQuiet && String(row.code || "")) muted = ""
    if (muted && notification.urgency !== NotificationUrgency.Critical) {
      Store.write(storeProc, storeBin, "put", row)
      Store.write(storeProc, storeBin, "close", null, [key, muted])
      prefetchMissed()
      release(key)
      if (rowIndexFor(key) < 0) releaseLive(key)
      else liveKeys[key].row = null
      return
    }

    Store.write(storeProc, storeBin, "put", row)
    wantSenderImage(row)
    wantIcon(row)
    lookForReply(row)

    // An update to something already on screen goes through either way: it
    // changes a card in place rather than moving anything. Only a genuinely
    // new card waits, and only while the deck is being held - and it keeps
    // its reservation the whole time it sits there, unshown.
    if (service.holding() && service.rowIndexFor(key) < 0) {
      var pending = liveKeys[key]
      pending.row = row
      if (!pending.held) {
        pending.held = true
        service.held = service.held.concat([key])
      }
      return
    }

    service.showRow(row)
  }

  function watchNotification(notification, key) {
    var reservation = liveKeys[key]
    notification.closed.connect(function() {
      if (service.refs[key] !== notification) return
      delete service.refs[key]
      service.refsRevision += 1
      // Visible snapshots outlive their sender; pending rows must not appear
      // after the sender withdraws them.
      if (service.rowIndexFor(key) < 0) service.finishClose(key, "closed")
    })
    // NotificationServer emits onNotification only for new objects. A
    // replaces_id update mutates this QObject and emits its property signals.
    // Snapshot once after the whole update, not once per changed field.
    var queued = false
    var refresh = function() {
      if (!queued) return
      queued = false
      if (reservation.refresh === refresh) reservation.refresh = null
      if (service.liveKeys[key] !== reservation || service.refs[key] !== notification) return
      service.handleNotification(notification)
    }
    var schedule = function() {
      if (queued || service.liveKeys[key] !== reservation || service.refs[key] !== notification) return
      queued = true
      reservation.refresh = refresh
      Qt.callLater(refresh)
    }
    var signals = [notification.summaryChanged, notification.bodyChanged,
                   notification.appNameChanged, notification.appIconChanged,
                   notification.imageChanged, notification.urgencyChanged,
                   notification.expireTimeoutChanged, notification.hintsChanged,
                   notification.actionsChanged]
    for (var i = 0; i < signals.length; i++) signals[i].connect(schedule)
  }

  // Qt.callLater: mutating the model while a Repeater is mid-incubation
  // crashes in QV4::Object::insertMember.
  function showRow(row) {
    var key = String(row.key || "")
    if (!reserveLive(key)) return
    var pending = liveKeys[key]
    pending.row = row
    pending.originalId = row.originalId || 0
    if (pending.held) {
      pending.held = false
      held = held.filter(function(heldKey) { return heldKey !== key })
    }
    if (pending.scheduled) return
    pending.scheduled = true
    Qt.callLater(function() {
      if (service.liveKeys[key] !== pending) return
      // This insertion may have been queued before a replaces_id update.
      // Consume that update first, including its quiet/cancellation decision.
      if (pending.refresh) pending.refresh()
      pending.scheduled = false
      if (service.liveKeys[key] !== pending || pending.held || !pending.row) return
      var row = pending.row
      pending.row = null
      var at = service.rowIndexFor(key)
      var snap = service.snapshot(), deckNow = service.deckHeight
      if (at >= 0) {
        Store.applyTo(toasts, at, row)      // an update, in place
        Qt.callLater(function() {
          var now = service.rowIndexFor(key)
          if (now >= 0) service.joinMissed(toasts.get(now))
        })
        service.retarget(undefined, undefined, snap, deckNow)
      } else {
        service.pinDeckDisplay()
        toasts.insert(0, row)
        // After this arrival has settled into the deck, not in the middle of
        // it: creating a panel card here re-entered the deck's layout.
        Qt.callLater(function() {
          var at = service.rowIndexFor(key)
          if (at >= 0) service.joinMissed(toasts.get(at))
        })
        // Where it comes from: under the bar, transparent. The layout has
        // already made room for it, so this is the only thing the arrival
        // needs - the drop is the same move everything else is making.
        var landing = service.layout.placements[key]
        service.retarget(key, {
          y: (landing ? landing.y : 0) - Style.space(30),
          scale: landing ? landing.scale : 1,
          opacity: 0,
          height: landing ? landing.height : 0
        }, snap, deckNow)
      }
    })
  }

  // Let go of the sender's object. Untracking tells it the notification
  // closed, which is when Chromium deletes the avatar it handed us.
  function release(key, reason) {
    var ref = refs[key]
    if (!ref) return
    // Clear identity before invoking the QObject: its close signal can run
    // synchronously and must not cancel a row or release a newer sender.
    delete refs[key]
    refsRevision += 1
    // Untracking itself dismisses the notification. Do exactly one close:
    // dismiss()/expire() have already destroyed it before they return.
    try {
      if (reason === "expired") ref.expire()
      else if (reason) ref.dismiss()
      else ref.tracked = false
    } catch (e) {}
  }

  // ------------------------------------------------------------- departure
  // Removing the row immediately would mean no exit to animate, so the card
  // is asked to play its exit and the row goes when it has finished.
  property var leaving: ({})

  // Marking it, not removing it. The row keeps its slot in the model until the
  // move finishes; the layout stops giving it room immediately, so the gap
  // closes while it fades. There used to be a fade, then a 200ms hole, then a
  // jump - three motions for one event, and the hole was visible in every
  // recording.
  function closeToast(key, reason) {
    if (leaving[key]) return
    if (rowIndexFor(key) < 0) {
      finishClose(key, reason || "dismissed")
      return
    }
    // Where it is *before* the layout stops giving it room. Marking it first
    // and asking afterwards gets the answer the pinned placement invented,
    // which is wherever it happened to come in from.
    var snap = snapshot(), deckNow = deckHeight
    var next = {}
    for (var k in leaving) next[k] = leaving[k]
    next[key] = reason || "dismissed"
    leaving = next
    retarget(key, snap[key], snap, deckNow)
  }

  function finishClose(key, reason) {
    if (replyingKey === key) replyingKey = ""
    leaveMissed(key)
    prefetchMissed()
    if (thrown[key]) {
      var still = {}
      for (var t in thrown) if (t !== key) still[t] = true
      thrown = still
      swipeRevision += 1
    }
    var rest = {}
    for (var k in leaving) if (k !== key) rest[k] = leaving[k]
    leaving = rest
    var at = rowIndexFor(key)
    if (!liveKeys[key]) return
    releaseLive(key)
    release(key, reason)
    if (at >= 0) toasts.remove(at)
    delete heights[key]
    Store.write(storeProc, storeBin, "close", null, [key, reason])
    layoutRevision += 1        // the row is gone; nothing moves, the gap already closed
  }

  function clearAll(reason) {
    // Over a snapshot of the keys, never over the model's count: closeToast
    // does not remove the row, it marks it leaving and lets the exit timer
    // take it 200ms later. `while (toasts.count > 0)` therefore never made
    // progress - the second pass at the same key returned early on `leaving`,
    // the count stayed put, and the loop spun the main thread at 100% with no
    // error and no log. Every wedge traced back to here, because the demo
    // script clears before it starts.
    var keys = Object.keys(liveKeys)
    for (var k = 0; k < keys.length; k++) closeToast(keys[k], reason || "cleared")
  }

  // What the sender said can be done with this notification. Not a guess - the
  // app put these on the wire itself, and until now the daemon accepted them
  // (actionsSupported: true), invoked "default" on a click, and drew none of
  // the rest. A restored row has no live sender, so it has none of these.
  property int refsRevision: 0

  function actionsOf(key, revision) {
    var out = []
    var ref = refs[key]
    if (!ref || !ref.actions) return out
    for (var i = 0; i < Math.min(ref.actions.length, Security.MAX_ACTIONS); i++) {
      var a = ref.actions[i]
      var identifier = String(a.identifier || "")
      if (identifier.length > Security.MAX_ACTION_ID || !identifier) continue
      if (identifier === "default") { out.push({id: identifier, text: "Open in app"}); continue }
      var label = Security.bounded(String(a.text || identifier), Security.MAX_ACTION_LABEL)
      if (hideSettingsAction && (/^settings$/i.test(label) || /^settings$/i.test(identifier)))
        continue
      out.push({ id: identifier, text: label })
    }
    return out
  }

  function invokeAction(key, identifier) {
    if (typeof identifier !== "string" || identifier.length > Security.MAX_ACTION_ID) return
    var ref = refs[key]
    if (ref && ref.actions) {
      for (var i = 0; i < Math.min(ref.actions.length, Security.MAX_ACTIONS); i++) {
        if (String(ref.actions[i].identifier) === identifier) {
          try { ref.actions[i].invoke() } catch (e) {}
          break
        }
      }
    }
    closeToast(key, "activated")
  }

  // ------------------------------------------------------- source routing
  //
  // Which open window is already showing the thing that notified you.
  // Senders come in two shapes and need two different answers:
  //
  //   web.whatsapp.com   an Omarchy web app, which writes its host straight
  //                      into its class: "chrome-web.whatsapp.com__-Default"
  //   app.slack.com      a tab in an ordinary browser, whose class says only
  //                      which browser it is ("chrome-work"). Nothing about
  //                      Slack appears anywhere but the window title.
  //
  // So: the class first, because it is exact, and the title second, cautiously.

  // Whole words only: "slack" must not match "slackline", and a brand that
  // happens to be a substring of a longer word is not a sighting of it.
  function wordIn(text, word) {
    var at = text.indexOf(word)
    while (at >= 0) {
      var before = at === 0 ? "" : text.charAt(at - 1)
      var after = text.charAt(at + word.length)
      if (!/[a-z0-9]/.test(before) && !/[a-z0-9]/.test(after)) return true
      at = text.indexOf(word, at + 1)
    }
    return false
  }

  // Every window on the desktop, as { wmClass, title }. Hyprland.toplevels is
  // the current name; clients is the older one, kept as a fallback so the
  // plugin still routes on an older Quickshell.
  function openWindows() {
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    if (!list.length && Hyprland.clients) list = Hyprland.clients.values
    var out = []
    for (var i = 0; i < list.length; i++) {
      var ipc = list[i].lastIpcObject
      var wmClass = String((ipc && ipc["class"]) || "")
      if (wmClass) out.push({ wmClass: wmClass,
                              title: String((ipc && ipc.title) || ""),
                              address: String((ipc && ipc.address) || ""),
                              pid: Number((ipc && ipc.pid) || 0),
                              // 0 is the window you are in, 1 the one before
                              // it, and so on back through the session.
                              focusOrder: Number(ipc && ipc.focusHistoryID !== undefined
                                                 ? ipc.focusHistoryID : 9999) })
    }
    return out
  }

  // Matching a site against a browser window's *title* is the guessy half of
  // routing: the class half is exact, this one is inference. It is what finds
  // Slack when Slack is a tab rather than a web app, and it is the difference
  // between landing in the conversation and opening a second copy of it in a
  // new tab - so it is on. Turn it off and a source with no window of its own
  // opens its site instead of raising a window that might be the wrong one.
  property bool smartRaise: true

  readonly property var browserClasses: /^(chrome|chromium|firefox|zen|brave|edge|vivaldi)/

  // Every Chrome window title ends "- Google Chrome", every Firefox one
  // "- Mozilla Firefox". Left on, a notification from any google.com host
  // matches every Chrome window on the desktop, so the browser's own name
  // comes off before anything is compared.
  readonly property var browserSuffix:
    /\s*[-\u2013\u2014|]\s*(google chrome|chromium|mozilla firefox|firefox|zen browser|brave|microsoft edge|vivaldi)\s*$/

  // Labels that name nobody: the subdomains everyone uses, and public suffixes.
  readonly property var genericLabels: ({ www: 1, app: 1, web: 1, my: 1, m: 1,
                                          mail: 1, com: 1, org: 1, net: 1,
                                          io: 1, co: 1, dev: 1, ai: 1, so: 1,
                                          site: 1, uk: 1 })

  // What to look for in a title, most telling first. "app.slack.com" gives
  // ["slack"]; "news.ycombinator.com" gives ["news", "ycombinator"], because
  // either half can be the one a page actually puts in its title. Tried in
  // order, so the more specific label gets first refusal on every window.
  function brandsOf(host) {
    var labels = String(host || "").toLowerCase().split(".")
    var out = []
    for (var i = 0; i < labels.length; i++) {
      if (labels[i].length >= 4 && !genericLabels[labels[i]]) { out.push(labels[i]); break }
    }
    var registered = labels.length >= 2 ? labels[labels.length - 2] : ""
    if (registered.length >= 4 && !genericLabels[registered] && out.indexOf(registered) < 0)
      out.push(registered)
    return out
  }

  // The window belonging to the process that sent the notification.
  //
  // This is the only identity that is never a guess. A terminal announces
  // itself as "kitty" and there are five of those open; a class cannot tell
  // them apart, and the first one Hyprland lists is almost never the one you
  // were looking at. The sender's pid can, whenever the sender is the thing
  // that owns a window - which is the case for a terminal relaying a
  // notification from something running inside it, and that is where this
  // matters most.
  function windowForPid(pid) {
    var want = Number(pid || 0)
    if (!want) return null
    var windows = openWindows()
    for (var i = 0; i < windows.length; i++)
      if (windows[i].pid === want) return windows[i]
    return null
  }

  // Of several windows that all match, the one you were in most recently.
  //
  // A class is not an identity: five terminals are all "kitty", and the
  // notification that says "waiting for your input" came from exactly one of
  // them. Hyprland remembers the order you last focused things in, and the
  // terminal you were last in is a far better answer than the first one it
  // happens to list - which, as it turned out, was reliably the one you had
  // touched least recently.
  function mostRecent(candidates) {
    if (!candidates.length) return null
    var best = candidates[0]
    for (var i = 1; i < candidates.length; i++)
      if (candidates[i].focusOrder < best.focusOrder) best = candidates[i]
    return best
  }

  function windowForSource(source) {
    var name = String(source || "").toLowerCase()
    if (!name) return null
    // Compare in lower case, return the class as it actually is: Hyprland's
    // class filter is an exact match, so the lowercased form
    // ("...__-default") would never find the window ("...__-Default").
    var windows = openWindows()
    var i

    var found = []
    if (name.indexOf(".") > 0) {
      for (i = 0; i < windows.length; i++)
        if (windows[i].wmClass.toLowerCase().indexOf(name) >= 0) found.push(windows[i])
      if (found.length) return mostRecent(found)

      // No class carries it, so the site is a tab in a browser that named
      // itself after something else. Browsers only: "slack" in an editor's
      // title is a filename, not a place to go.
      if (!smartRaise) return null
      var brands = brandsOf(name)
      for (var b = 0; b < brands.length; b++) {
        found = []
        for (i = 0; i < windows.length; i++) {
          if (!browserClasses.test(windows[i].wmClass.toLowerCase())) continue
          var title = windows[i].title.toLowerCase().replace(browserSuffix, "")
          if (wordIn(title, brands[b])) found.push(windows[i])
        }
        if (found.length) return mostRecent(found)
      }
      return null
    }

    // Not a host - a phone-forwarded notification says "WhatsApp", not
    // "web.whatsapp.com". Match it against the labels of each open web app's
    // host, and against native app classes, so a message forwarded from the
    // phone still lands on the desktop window showing the same thing. Whole
    // labels only, and nothing shorter than four characters: "X" would
    // otherwise match half the desktop.
    var slug = name.replace(/[^a-z0-9]+/g, "")
    if (slug.length < 4) return null
    found = []
    for (i = 0; i < windows.length; i++) {
      var lower = windows[i].wmClass.toLowerCase()
      if (lower === slug) { found.push(windows[i]); continue }   // a native app
      if (lower.indexOf("chrome-") !== 0) continue
      var labels = lower.substring(7).split("__")[0].split(".")
      for (var l = 0; l < labels.length; l++)
        if (labels[l] === slug) { found.push(windows[i]); break }
    }
    return mostRecent(found)
  }

  // By address, because a class is not an identity: this desktop runs two
  // browser windows both called "chrome-work", and only one of them is showing
  // Slack. The class is the fallback for a window Hyprland gave us no address
  // for. Dispatch arguments are evaluated as Lua here, so this is an
  // expression rather than the classic `dispatch focuswindow ...` string.
  function focusWindow(win) {
    if (!win) return
    if (!/^0x[0-9a-f]+$/i.test(String(win.address || ""))) return
    Hyprland.dispatch('hl.dsp.focus({window = hl.get_window("address:' + win.address + '")})')
  }

  function runExecArgv(argv) {
    Quickshell.execDetached(argv[0].charAt(0) === "/" ? argv : ["/usr/bin/env"].concat(argv))
  }

  function activate(key) {
    var at = rowIndexFor(key)
    var row = at >= 0 ? toasts.get(at) : null
    var argv = Security.parseOmarchyExecArgv(row ? row.execArgv : "")
    if (argv) {
      runExecArgv(argv)
      closeToast(key, "activated")
      return
    }

    var ref = refs[key]
    var handled = false
    if (allowDefaultActionOnCardClick && ref && ref.actions) {
      for (var i = 0; i < Math.min(ref.actions.length, Security.MAX_ACTIONS); i++) {
        if (String(ref.actions[i].identifier) === "default") {
          try { ref.actions[i].invoke(); handled = true } catch (e) {}
          break
        }
      }
    }

    if (!handled && row) routeRow(row)
    closeToast(key, "activated")
  }

  // Where a click on this row goes, when the sender has no action of its own
  // to run. Shared by live cards and missed ones, which never have a sender.
  function routeRow(row) {
    // Source first, link last. A Slack message quoting a link to
    // somewhere else is still a Slack notification: clicking it should
    // take you to Slack, not to whatever URL happened to be in the text.
    // That link already has its own button. Checked against 300 stored
    // notifications, where the wrong order would have sent 20 clicks to
    // the wrong place - including a Slack card that would have opened
    // axiom.co.
    // The sender's own window first, then the source's, then the site.
    var win = windowForPid(row.senderPid) || windowForSource(row.source)
    if (win) focusWindow(win)
    // Not `indexOf(".") > 0`. A source is lifted out of text the sender
    // wrote, and "https://" + it is a URL going wherever it says - so it
    // has to be a hostname by the same test omapager-icon uses before it
    // will fetch anything, not merely a string with a dot in it.
    else if (Markup.hostname(row.source))
      Security.openExternalUrl("https://" + Markup.hostname(row.source) + "/")
    else if (String(row.link || "")) Security.openExternalUrl(String(row.link))
  }

  // ------------------------------------------------------------- replying
  //
  // A message forwarded from the phone can be answered from here. KDE Connect
  // keeps an object per phone notification on its own bus carrying a replyId
  // and a sendReply method - the part the freedesktop spec has no room for -
  // and the helper matches our row to it by app name and text.
  readonly property string kdeBin: Qt.resolvedUrl("bin/omapager-run-kdeconnect")
                                     .toString().replace(/^file:\/\//, "")
  property string replyingKey: ""        // the card with its reply box open

  Process {
    id: replyProc
    environment: service.helperEnvironment
    property string replyKey: ""
    running: false
    onExited: function(code, status) {
      if (code === 0) { service.replyingKey = ""; service.closeToast(replyKey, "activated") }
      else service.replyError = "Unable to safely identify reply target"
    }
  }
  property string replyError: ""

  // A reply box holds the keyboard, so it must not be able to hold it
  // indefinitely - a card that expires or is dismissed while you are typing
  // would otherwise leave the desktop deaf.
  Timer {
    id: replyGiveUp
    interval: 120000
    running: service.replyingKey !== ""
    onTriggered: service.replyingKey = ""
  }

  Process {
    id: findProc
    environment: service.helperEnvironment
    property var job: ({})
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var job = findProc.job || {}
        var path = "", who = ""
        try {
          var found = JSON.parse(String(text) || "{}")
          path = String(found.path || "")
          who = String(found.title || "")
        } catch (e) {}
        var at = service.rowIndexFor(String(job.key || ""))
        if (path && at >= 0) {
          toasts.setProperty(at, "replyPath", path)
          if (who) toasts.setProperty(at, "replyTo", who)
        } else if (!path && at >= 0 && (job.tries || 0) < 1) {
          // Nothing yet. Once more in a moment, in case the phone's side of it
          // had not appeared when we looked.
          job.tries = (job.tries || 0) + 1
          var queue = service.replyQueue.slice(0, 99)
          queue.push(job)
          service.replyQueue = queue
          replyRetry.restart()
        }
        Qt.callLater(service.pumpReplies)
      }
    }
  }

  // Lookups are queued rather than dropped, and each row is tried twice: KDE
  // Connect posts the desktop notification and publishes the object that backs
  // it at about the same moment, so the first look can arrive before there is
  // anything to find.
  property var replyQueue: []

  function lookForReply(row) {
    if (!/kde\s*connect/i.test(String(row.app || ""))) return
    var queue = replyQueue.slice()
    queue.push({ key: String(row.key || ""), source: String(row.source || ""),
                 body: String(row.bodyLine || row.body || ""), tries: 0 })
    replyQueue = queue
    pumpReplies()
  }

  function pumpReplies() {
    if (!helperSettingsReady || findProc.running || replyQueue.length === 0) return
    var queue = replyQueue.slice()
    var job = queue.shift()
    replyQueue = queue
    findProc.job = job
    findProc.command = [kdeBin, "find", job.source, job.body]
    findProc.running = true
  }

  Timer {
    id: replyRetry
    interval: 1500
    onTriggered: service.pumpReplies()
  }

  function sendReply(key, text) {
    var at = rowIndexFor(key)
    if (at < 0) return
    var path = String(toasts.get(at).replyPath || "")
    if (!helperSettingsReady || !path || !String(text).trim() || String(text).length > 4096 || replyProc.running) return
    replyProc.running = false
    replyProc.replyKey = key
    replyProc.command = [kdeBin, "reply", path, String(text), String(toasts.get(at).source), String(toasts.get(at).bodyLine)]
    replyProc.running = true

  }

  // ------------------------------------------------------------- offers
  //
  // Acting on what Detect.js found in a card: copy the code, open the link.
  // Nothing here guesses - the card only ever offers what was actually found,
  // and the offer is a click, never automatic.
  Process { id: clipProc; running: false }

  // wl-copy is not an Omarchy dependency - it arrives with some other package
  // or it does not arrive at all - so the copy buttons cannot assume it. Probed
  // once at startup: the answer cannot change while the shell is running, and a
  // button that has to shell out before it knows whether it works is a button
  // that stutters.
  property bool hasWlCopy: false
  Process {
    id: clipProbe
    running: true
    command: [service.helperBin, "capabilities"]
    onExited: function(code, status) { service.hasWlCopy = code === 0 }
  }

  // A verification code is not clipboard history material. wl-copy's
  // --sensitive marks it, and Omarchy's clipboard capture skips anything
  // carrying that hint - so the code is pasteable but never recorded. It is
  // also cleared once it has had time to be used, the way a phone does it.
  property string secretHeld: ""

  function copyText(text, sensitive) {
    var value = String(text || "")
    if (!value || value.length > (sensitive ? 64 : 4096)) return

    // Without wl-copy, Qt holds the selection instead. That loses --sensitive,
    // but it loses nothing real: Omarchy's clipboard history is wl-paste
    // --watch, as is every other Wayland clipboard manager here, so if wl-copy
    // is absent there is no history for the code to land in. What matters is
    // that the button still works - saying "Copied" and copying nothing is the
    // one outcome worth ruling out.
    if (!hasWlCopy) {
      Quickshell.clipboardText = value
      if (sensitive) { secretHeld = value; secretLife.restart() }
      return
    }

    var args = ["wl-copy"]
    if (sensitive) args.push("--sensitive")
    args.push("--")
    args.push(value)
    clipProc.running = false
    clipProc.command = args
    clipProc.running = true
    if (sensitive) { secretHeld = value; secretLife.restart() }
  }

  Timer {
    id: secretLife
    interval: service.clipboardTimeout * 1000
    onTriggered: {
      if (service.hasWlCopy) { clipReader.running = true; return }
      if (service.secretHeld && Quickshell.clipboardText === service.secretHeld)
        Quickshell.clipboardText = ""
      service.secretHeld = ""
    }
  }

  // Only clear it if it is still the thing on the clipboard: taking away
  // something the person copied afterwards would be its own small betrayal.
  Process {
    id: clipReader
    running: false
    command: ["wl-paste", "--no-newline"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text) === service.secretHeld && service.secretHeld) {
          clipProc.running = false
          clipProc.command = ["wl-copy", "--clear"]
          clipProc.running = true
        }
        service.secretHeld = ""
      }
    }
  }

  function takeOffer(kind, value, key) {
    if (kind === "code") {
      var index = rowIndexFor(String(key || ""))
      if (index < 0 || String(toasts.get(index).codes).split(" ").indexOf(String(value)) < 0) return
      copyText(value, true)
    }
    else if (kind === "phone") copyText(value, false)
    else Security.openExternalUrl(value)

    // A copied code is a finished notification: it exists to carry six digits
    // to a login box, and once they are on the clipboard there is nothing left
    // in it. Long enough after the press for the button's tick to be seen,
    // because a card that vanishes the instant you click it leaves you unsure
    // whether it copied or you missed.
    // ...unless it was carrying more than one, in which case the other one is
    // still in there and taking the card away would be taking that with it.
    if (kind === "code" && String(key || "")) {
      var at = rowIndexFor(String(key))
      var several = at >= 0 && String(toasts.get(at).codes || "").indexOf(" ") > 0
      if (!several) {
        var waiting = codeTaken.keys.slice()
        waiting.push(String(key))
        codeTaken.keys = waiting
      }
    }
  }

  Timer {
    id: codeTaken
    property var keys: []
    interval: 900
    repeat: true
    running: keys.length > 0
    onTriggered: {
      var pending = keys
      keys = []
      for (var i = 0; i < pending.length; i++) service.closeToast(pending[i], "activated")
    }
  }

  // ------------------------------------------------------------- store
  Process {
    id: storeProc
    running: false
    environment: service.helperEnvironment
    property bool policyReady: service.helperSettingsReady
  }

  function restoreRows(rows, replay) {
    // Restore is oldest first; history is newest first. Both insert at zero.
    for (var i = replay ? rows.length - 1 : 0;
         replay ? i >= 0 : i < rows.length; i += replay ? -1 : 1) {
      var row = Store.restored(rows[i])
      if (!row) continue
      if (liveKeys[row.key]) {
        // Startup must not overwrite a newer live arrival. Replaying the same
        // entry deliberately creates a separate card, even while pending.
        if (!replay) continue
        row.key = nextKey()
      }
      if (!reserveLive(row.key)) break
      // Live image handles died with the old shell; restore a durable icon.
      if (!replay) wantIcon(row)
      showRow(row)
    }
  }

  Process {
    id: restoreProc
    environment: service.helperEnvironment
    running: false
    command: [service.storeBin, "restore"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        service.restoreRows(Store.parseList(text), false)
      }
    }
  }

  Process {
    id: quietRestoreProc
    environment: service.helperEnvironment
    running: false
    command: [service.storeBin, "quiet"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var read = JSON.parse(String(text) || "{}")
          if (read && typeof read === "object") {
            if (read.snoozes && typeof read.snoozes === "object") service.snoozes = read.snoozes
            service.doNotDisturb = read.dnd === true
            service.silencedSince = Number(read.silencedSince || 0)
            // Turned off in the panel, it stays off - the setting is the
            // default, not a standing instruction to put it back.
            if (read.codesBypassQuiet !== undefined)
              service.codesBypassQuiet = read.codesBypassQuiet === true
          }
        } catch (e) {}
        service.snoozeRevision += 1
      }
    }
  }

  // Housekeeping, once, at startup. History trims itself on every close, so
  // this is really for the icon cache - nothing else ever looks at it, and
  // without this it only ever grows.
  Process {
    id: tidyProc
    environment: service.helperEnvironment
    running: false
    command: [service.storeBin, "tidy"]
  }

  // Wait for the bar widget's saved policy before any helper can run. Otherwise
  // a stored requireSandbox=true could be bypassed during service startup.
  onHelperSettingsReadyChanged: if (helperSettingsReady) Qt.callLater(function() {
    sandboxProbe.running = true
    service.startEdge()
    service.refreshMissed()
    restoreProc.running = true
    quietRestoreProc.running = true
    tidyProc.running = true
    Store._pump(storeProc)
    pumpIcons()
    pumpSenderImages()
    pumpReplies()
  })

  // ------------------------------------------------------------- server
  NotificationServer {
    id: server
    keepOnReload: false
    imageSupported: true
    actionsSupported: true
    bodyMarkupSupported: true
    bodyHyperlinksSupported: true
    persistenceSupported: true

    onNotification: function(notification) { service.handleNotification(notification) }
  }

  IpcHandler {
    target: "omapager"
    function count(): string { return String(toasts.count) }
    // What the daemon thinks is true, for a script to check against what it
    // can see. Everything here answers a question that has actually been
    // asked in anger: where would a click go, did the reply channel resolve,
    // which of the sender's actions survived, how tall is each card.
    function probe(): string {
      return JSON.stringify({fontScale: service.fontScale, toasts: toasts.count,
        doNotDisturb: service.doNotDisturb, expanded: service.expanded,
        hasWlCopy: service.hasWlCopy, security: service.sandboxStatus,
        fetchRemoteIcons: service.fetchIcons,
        allowDefaultActionOnCardClick: service.allowDefaultActionOnCardClick,
        sharingActive: service.sharingActive, sharingStreams: service.sharingStreams,
        sharingOfferPending: service.sharingOfferPending, offerSnoozeWhenSharing: service.offerSnoozeWhenSharing,
        globalSnoozeUntil: service.globalSnoozeUntil,
        displayMode: service.displayMode, displayName: service.displayName,
        displays: service.displayNames, focusedDisplay: service.focusedDisplayName,
        targetDisplay: service.targetDisplayName,
        notificationDisplays: service.displayMode === "all" ? service.displayNames : [service.targetDisplayName],
        swipeKeys: service.swipeKeys.length, swipeX: service.swipeX,
        thrown: Object.keys(service.thrown).length, lastWheel: service.lastWheel, wheelLog: service.wheelLog,
        naturalScroll: service.naturalScroll, windowBorderWidth: service.windowBorderWidth,
        scrollY: service.scrollY, scrollMax: service.scrollMax, deckRoom: service.deckRoom,
        layoutHeight: service.layout.height,
        edgeSwipe: service.edgeSwipe, edgeStatus: service.edgeStatus,
        missedShown: service.missedShown, missedOpen: service.missedOpen,
        missedCount: service.missedCount, missedLoaded: service.missedLoaded,
        missedScroll: service.missedScroll, missedScrollMax: service.missedScrollMax,
        missedListHeight: service.missedLayout.height, missedOpenDeck: service.missedOpenDeck,
        missedPointerIn: service.missedPointerIn, missedHoverKey: service.missedHoverKey,
        missedHoverY: service.missedHoverY,
        missedDecks: service.missedLayout.decks.map(function(d) {
          var pl = service.missedLayout.placements[d.rows[0].key]
          return [d.key, Math.round(pl ? pl.y : -1), d.rows.length]
        })})
    }
    function clear(): string { service.clearAll("cleared"); return "ok" }

    // A finished two-finger swipe of `px`, released at rest, starting on the
    // card under the pointer or else the front card. Same decision the
    // touchpad path makes; only the fingers are missing.
    function swipe(px: string): string {
      var key = service.hoverKey
      if (!key && toasts.count > 0) key = toasts.get(0).key
      if (!key || service.swipeBusy) return "none"
      var dx = Number(px) || 0
      var g = Gesture.feed(Gesture.start(0), dx + (dx >= 0 ? Gesture.LOCK : -Gesture.LOCK), 0, 1000)
      service.swipeKeys = service.swipeTargets(key)
      service.swipeRevision += 1
      service.swipeX = Gesture.drawn(g.x)
      service.gesture = g
      var carried = service.swipeKeys.length
      var throws = Gesture.throws(g, service.notificationWidth)
      service.endGesture()
      return (throws ? "thrown " : "sprung ") + carried
    }
    // The missed panel, as the edge swipe would bring it in: "" toggles,
    // "open" / "close" say which. For a keybinding, and for a desktop
    // without a touchpad the helper can read.
    function missed(how: string): string {
      var open = how === "open" || (how !== "close" && !service.missedOpen)
      if (open) service.openMissed()
      else service.closeMissed()
      return open ? "open" : "closed"
    }
    // Pull it in by hand: begin, then move <fraction of the pad>, then end
    // <fraction> <widths per second> - the helper's own words.
    function edge(line: string): string {
      service.edgeLine(line)
      return String(Math.round(service.missedShown * 100)) + "%"
    }
    function scroll(px: string): string {
      service.scrollBy(-(Number(px) || 0))
      return String(Math.round(service.scrollY)) + "/" + String(Math.round(service.scrollMax))
    }
    function dnd(): string {
      service.doNotDisturb = !service.doNotDisturb
      return service.doNotDisturb ? "on" : "off"
    }
    // Drive the deck without a pointer: a headless session has no cursor, and
    // a recording needs the expansion to happen on cue rather than by hand.
    function expand(): string {
      if (service.expanded) {
        service.commit(function() {
          service.expanded = false; service.openDeck = ""; service.hoverKey = ""
        })
      }
      else if (toasts.count > 0) {
        // Stand in for the pointer being on the front card: its deck opens and
        // it counts as hovered, so anything that only appears under a pointer
        // can be seen without one.
        var front = toasts.get(0)
        service.pointerEntered(Layout.deckKeyFor(front, service.stacking))
        service.hoverKey = String(front.key)
      } else {
        service.pointerEntered(undefined)
      }
      return service.expanded ? "expanded" : "collapsed"
    }
    // Snooze the front card's source, or any source by key. Minutes, because
    // that is how anyone says it out loud.
    function snooze(minutes: string): string {
      if (toasts.count === 0) return "nothing"
      var row = toasts.get(0)
      var mins = Number(minutes) > 0 ? Number(minutes) : 60
      var until = service.snoozeSource(String(row.groupKey || ""),
                                       String(row.source || row.app || ""), mins * 60)
      return until ? (String(row.source || row.app) + " until " + new Date(until * 1000).toTimeString().slice(0, 5)) : "no source"
    }

    // Snooze the lot, which is what the panel's own button does. Separate from
    // `snooze` because that one acts on the front card's source, and the two
    // are easy to confuse at a prompt - with the cost of confusing them being
    // a real source silently going quiet for an hour.
    //
    // Toggles, like the silence key it sits beside on the keyboard and like
    // the panel button it stands in for: pressed again, it wakes everything.
    // A key that only goes one way leaves you hunting for the way back.
    function snoozeAll(minutes: string): string {
      if (service.globalSnoozeUntil) {
        service.unsnooze(service.globalKey)
        return "awake"
      }
      var mins = Number(minutes) > 0 ? Number(minutes) : 60
      var until = service.snoozeSource(service.globalKey, "Everything", mins * 60, true)
      return until ? ("everything until " + new Date(until * 1000).toTimeString().slice(0, 5)) : "no"
    }

    function unsnooze(key: string): string {
      if (!String(key || "")) { service.unsnoozeAll(); return "all" }
      service.unsnooze(String(key))
      return String(key)
    }

    function snoozes(): string { return JSON.stringify(service.liveSnoozes()) }

    // Whether a verification code gets through the quiet. The panel's key
    // button, from a script.
    function codes(state: string): string {
      var want = String(state || "").toLowerCase()
      if (want === "on" || want === "off")
        service.setCodesBypassQuiet(want === "on")
      return service.codesBypassQuiet ? "on" : "off"
    }
    function open(deckKey: string): string {
      service.pointerEntered(deckKey)
      return service.openDeck
    }
    // Invoke one of the sender's actions on the front card, by identifier.
    // Scriptable, and the only way to exercise the path without a pointer.
    function act(identifier: string): string {
      if (toasts.count === 0) return "nothing"
      var key = String(toasts.get(0).key)
      var available = service.actionsOf(key, service.refsRevision)
      var wanted = String(identifier || "")
      if (!wanted && available.length > 0) wanted = available[0].id
      if (!wanted) return "no actions"
      service.invokeAction(key, wanted)
      return wanted
    }

    // Take one of the front card's offers - "code", "link", "phone".
    // The same thing the little marks do, without a pointer.
    function offer(kind: string): string {
      if (toasts.count === 0) return "nothing"
      var row = toasts.get(0)
      var want = String(kind || "code")
      var value = want === "code" ? String(row.code || "")
                : want === "phone" ? String(row.phone || "")
                : String(row.link || "")
      if (!value) return "none"
      service.takeOffer(want, value, String(row.key))
      return "performed"
    }

    function align(side: string): string {
      if (side === "left" || side === "right") service.actionsAlign = side
      return service.actionsAlign
    }

    // Reply to the front card, for scripting and for testing the path without
    // a pointer.
    // With text, answers the front card. Without, just opens the box - which
    // is how the field itself can be looked at without a pointer.
    function reply(text: string): string {
      if (toasts.count === 0) return "nothing"
      var key = String(toasts.get(0).key)
      if (!String(toasts.get(0).replyPath || "")) return "not repliable"
      if (!String(text || "").trim()) {
        service.replyingKey = key
        service.pointerEntered(Layout.deckKeyFor(toasts.get(0), service.stacking))
        service.hoverKey = key
        return "open"
      }
      service.sendReply(key, String(text))
      return "sent"
    }

    function stack(mode: string): string {
      if (mode === "all" || mode === "source")
        service.commit(function() { service.stacking = mode })
      return service.stacking
    }
  }

  // ---------------------------------------------------- the stock keybindings
  //
  // Omarchy ships five global bindings on the comma key, and every one of them
  // talks to the IPC target `notifications` - dismiss one, dismiss all, invoke
  // the last, replay history, and the silencing toggle that
  // omarchy-toggle-notification-silencing drives. Disabling the built-in
  // service to run this one takes that target away with it, so all five go
  // quietly dead: the keys still fire, the shell answers "target not found",
  // and nothing tells you why.
  //
  // So omapager answers to it as well. The names and return values are the
  // built-in service's, not ours, because the callers are Omarchy's.
  IpcHandler {
    target: "notifications"

    function dndState(): string { return service.doNotDisturb ? "on" : "off" }
    function isDnd(): string { return dndState() }

    function toggleDnd(): string {
      service.setDoNotDisturb(!service.doNotDisturb)
      return dndState()
    }

    function setDnd(value: string): string {
      var v = String(value || "").toLowerCase()
      service.setDoNotDisturb(v === "true" || v === "1" || v === "on" || v === "yes")
      return dndState()
    }

    function dismissAll(): string { service.clearAll("dismissed"); return "ok" }

    function dismissOne(): string {
      if (toasts.count === 0) return "none"
      service.closeToast(String(toasts.get(0).key), "dismissed")
      return "ok"
    }

    function invokeLast(): string {
      if (toasts.count === 0) return "none"
      service.activate(String(toasts.get(0).key))
      return "ok"
    }

    function showHistory(): string { service.replayHistory(); return "ok" }

    // Forgets what was recorded. What is on screen stays where it is.
    function clear(): string {
      Store.write(storeProc, storeBin, "forget-all", null)
      service.heldRows = []
      service.heldRevision += 1
      service.historyRows = []
      service.historyRevision += 1
      return "ok"
    }

    // Used by Omarchy's first-run notifications to take their own card off
    // the screen once its action has been clicked.
    function dismiss(summary: string): string {
      var needle = String(summary || "")
      if (!needle) return "none"
      var keys = []
      for (var i = 0; i < toasts.count; i++)
        if (String(toasts.get(i).summary || "").indexOf(needle) !== -1)
          keys.push(String(toasts.get(i).key))
      for (var k = 0; k < keys.length; k++) service.closeToast(keys[k], "dismissed")
      return keys.length ? "ok" : "none"
    }

    function ping(): string { return "ok" }
  }

  // Put the last few back on screen, the way the built-in service's
  // "Open notification history" binding does. They come back as restored
  // rows - no live sender, a short grace rather than their original timeout -
  // because the notification they came from is long gone.
  property int replayCount: 6

  Process {
    id: replayProc
    environment: service.helperEnvironment
    running: false
    command: [service.storeBin, "history", String(service.replayCount)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        service.restoreRows(Store.parseList(text), true)
      }
    }
  }

  function replayHistory() { if (helperSettingsReady && !replayProc.running) replayProc.running = true }

  // ------------------------------------------------------------- surface
  //
  // One fixed-width layer per output. Keeping the surface height fixed avoids
  // compositor rescaling while cards enter or leave; the mask keeps everything
  // outside the deck click-through.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: surface
      required property var modelData
      screen: modelData
      readonly property bool showingNotifications: service.displayMode === "all" || modelData.name === service.targetDisplayName
      // Always mapped, even with nothing to draw. It used to appear with the
      // first notification and vanish with the last, and a layer surface
      // coming and going makes the compositor re-evaluate focus each time -
      // which on a scrolling layout drags the viewport somewhere else the
      // moment you dismiss the last card. The surface is the canvas; the deck
      // is what is painted on it, and an empty canvas costs a transparent
      // buffer nobody composites over.
      //
      // Input is unaffected: the mask follows the deck, and an empty deck is a
      // zero-area mask, which is click-through everywhere.
      visible: true
      color: "transparent"

      // The name the Hyprland layer_rule matches on for blur.
      WlrLayershell.namespace: "omapager"
      WlrLayershell.layer: WlrLayer.Overlay
      // Exclusive while a reply is being typed, and nothing at all otherwise.
      // OnDemand only hands the keyboard over when the surface is clicked,
      // which means anything that opens the box any other way - a keybinding,
      // the IPC verb - gets a field that silently ignores typing. A
      // notification layer holding the keyboard the rest of the time would
      // swallow every keystroke on the desktop, so this is tightly bounded:
      // Escape closes it, so does answering, and so does the timeout below.
      WlrLayershell.keyboardFocus: surface.showingNotifications && service.replyingKey !== ""
                                   ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      // As wide as the deck needs and no wider. Full-screen was the obvious
      // shape - the deck can sit anywhere in it - but it meant Qt re-rendering
      // a 5120x2880 surface for every frame of every arrival, for a stack
      // 380px across. The width is a constant, so the buffer is allocated once
      // and never resized under an animation; the height stays full so the
      // deck can grow downwards without the window changing size either.
      anchors { top: true; bottom: true; right: true }
      implicitWidth: clipper.width + Style.space(10)

      // Only the deck takes input; the rest of the surface stays
      // click-through. Tracking the item keeps the region honest as the deck
      // grows and shrinks.
      // The deck's input follows the deck item. The panel's cannot follow
      // its item: the panel slides by a transform, and a Region tracks an
      // item's own geometry, not a parent's transform - so it was measured
      // once, while the panel was still off to the side, and never moved.
      // It only ever worked because the list used to load late and resize
      // the panel after it had arrived. The rectangle is spelled out here,
      // bound to the slide itself.
      mask: Region {
        Region { item: surface.showingNotifications && !service.missedVisible ? deck : null }
        Region {
          readonly property bool on: surface.showingNotifications && service.missedVisible
          x: missedPanel.x + missedBody.x + (1 - service.missedShown) * missedPanel.away
          y: missedPanel.y + missedBody.y
          width: on ? missedBody.width : 0
          height: on ? missedBody.height : 0
        }
      }

      // Clip arrivals at the configured deck edge. Reserve only enough
      // side/bottom room for their scale animation; native notification
      // surfaces have no custom drop shadows to accommodate.
      Item {
        id: clipper
        visible: surface.showingNotifications
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: service.barClearance
        anchors.rightMargin: 0
        readonly property int motionInset: Style.spacing.sm
        // Room to the left of the cards for a card pulled the wrong way to
        // be seen giving and springing back, rather than cut off at its own
        // edge. Transparent and outside the input mask, so it costs nothing.
        readonly property int swipeRoom: Style.space(44)
        readonly property int deckX: motionInset + swipeRoom
        // In from the screen's right edge - plus the bar's width, if the bar
        // is the thing occupying that edge.
        readonly property int edgeGap: service.edgeClearance
        width: service.notificationWidth + deckX + edgeGap
        height: deck.y + deck.height + motionInset
        clip: true
        // Out of the way while the missed panel is in: the two occupy the
        // same strip of screen, and the panel is what the fingers asked for.
        // The panel draws the live cards itself while it is up - they travel
        // into it - so the deck steps aside entirely rather than fading.
        opacity: service.missedVisible ? 0 : 1
        enabled: !service.missedVisible

        Item {
          id: deck
        x: clipper.deckX
        width: service.notificationWidth
        // From the same clock as everything on it, so the clip and its
        // contents can never disagree mid-move - and never taller than the
        // screen. Past that the cards scroll inside it.
        height: Math.min(service.deckHeight, service.deckRoom)

        // What this output can show below the bar, for the scroll limit.
        // Only the surface actually showing the deck gets a say.
        Binding {
          target: service
          property: "deckRoom"
          when: surface.showingNotifications && surface.height > 0
          value: surface.height - service.barClearance - clipper.motionInset
                 - service.edgeSpacing
                 - (service.barPosition === "bottom" ? service.barThickness : 0)
        }

        // One hover region for the whole deck. Individual cards must not own
        // this: moving between two of them would leave and re-enter, and the
        // deck would flicker shut between every card.
        MouseArea {
          // Above the cards, not beneath them. A MouseArea that sets a
          // cursorShape accepts hover events whether or not hoverEnabled is
          // set, so every card was swallowing the hover this region needed -
          // and accepting no buttons means clicks still fall through to the
          // card underneath. Cards carry z of 1000-and-up from their
          // placement, so this has to clear that.
          z: 5000
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
          propagateComposedEvents: true
          id: hoverArea
          // Containment, not enter/exit events: the deck changes size the
          // moment it expands, and a resize under a stationary pointer was
          // producing an exit that shut it again a frame later.
          // Which card the pointer is over. The hover region sits above the
          // cards (they would otherwise swallow it), so a card cannot work
          // this out for itself - it is told. Done on entry as well as on
          // movement: arriving in the region without moving again inside it -
          // which is what a warped pointer does, and what a slow hand does at
          // the boundary - used to leave the deck thinking no card was under
          // the pointer at all.
          function hoverAt(x, y) {
            // Where the pointer is, for anything inside a card that wants to
            // light up under it. The card cannot find out for itself: this
            // region is above every card, hover goes to the topmost item that
            // accepts it, and so a button's own containsMouse never becomes
            // true. Clicks are fine - this accepts no buttons and they fall
            // through - which is why the buttons worked while looking dead.
            // The cards scroll; this region does not. Everything below is in
            // the cards' coordinates.
            y += service.scrollY
            service.hoverX = x
            service.hoverY = y
            var places = service.placements
            var found = ""
            for (var key in places) {
              var pl = places[key]
              if (pl.hidden) continue
              var h = pl.height || Style.space(58)
              if (y >= pl.y && y <= pl.y + h) { found = key; break }
            }
            service.hoverKey = found
          }

          // Cards can move under a stationary pointer after a dismissal.
          // Refresh after the finished handler removes leaving rows, or the
          // next card keeps its close control disabled and a second click
          // invokes the card's default action instead.
          Connections {
            target: sceneRun
            function onFinished() {
              Qt.callLater(function() {
                if (hoverArea.containsMouse)
                  hoverArea.hoverAt(hoverArea.mouseX, hoverArea.mouseY)
              })
            }
          }

          onContainsMouseChanged: {
            service.pointerIn = containsMouse
            if (containsMouse) {
              service.pointerEntered(undefined)
              hoverAt(mouseX, mouseY)
            } else {
              service.hoverKey = ""
              service.pointerLeft()
            }
          }
          // Two fingers: carry a card, or scroll the deck. Everything that
          // decides which is in the service; this only says where it happened.
          onWheel: function(wheel) {
            hoverAt(wheel.x, wheel.y)
            wheel.accepted = service.wheel(wheel, service.hoverKey)
          }
          Connections {
            target: service
            function onScrolled() {
              if (hoverArea.containsMouse) hoverArea.hoverAt(hoverArea.mouseX, hoverArea.mouseY)
            }
          }

          onPositionChanged: function(mouse) {
            hoverAt(mouse.x, mouse.y)

            // In source mode, which deck you are over decides which opens.
            if (service.stacking !== "source") return
            var decks = service.layout.decks
            for (var i = 0; i < decks.length; i++) {
              var first = decks[i].rows[0]
              var place = service.layout.placements[first.key]
              if (!place) continue
              var top = place.y
              var bottom = top + (service.heights[first.key] || Style.space(58))
              var my = mouse.y + service.scrollY
              if (my >= top - Style.space(6) && my <= bottom + Style.space(6)) {
                service.pointerEntered(decks[i].key)
                return
              }
            }
          }
        }

        // Where it is in a deck too tall for the screen. Outside the deck's
        // input mask, in the gap to the screen edge, so it never covers a card.
        Rectangle {
          visible: service.scrollMax > 0
          x: deck.width + Math.max(2, Math.round((clipper.edgeGap - width) / 2))
          width: Style.space(3)
          radius: width / 2
          height: Math.max(Style.space(24), deck.height * deck.height / Math.max(1, service.layout.height))
          y: service.scrollMax > 0 ? (deck.height - height) * service.scrollY / service.scrollMax : 0
          color: Color.notifications.text
          opacity: service.pointerIn ? 0.45 : 0.2
          Behavior on opacity { NumberAnimation { duration: 150 } }
        }

        Item {
          id: scroller
          width: deck.width
          height: service.deckHeight
          y: -service.scrollY

        Repeater {
          model: toasts

          Toast {
            id: toast
            required property var model
            row: model
            senderImage: service.senderImageFor(model.key, model.image, service.senderImageRevision)
            scene: service
            cardWidth: deck.width
            place: service.placements[model.key]
                   || ({ y: 0, scale: 1, opacity: 0, z: 1, front: false, hidden: true })
            hovered: service.hoverKey === model.key
            actions: service.actionsOf(model.key, service.refsRevision)
            fontScale: service.fontScale
            windowBorderWidth: service.windowBorderWidth
            showCountdown: service.showCountdown
            actionsAlign: service.actionsAlign
            replyError: service.replyingKey === model.key ? service.replyError : ""
            replying: service.replyingKey === model.key
            onReplyRequested: {
              service.replyError = ""
              service.replyingKey = model.key
              service.pointerEntered(Layout.deckKeyFor(model, service.stacking))
              service.hoverKey = String(model.key)
            }
            onReplySent: function(text) { service.sendReply(model.key, text) }
            onReplyCancelled: service.replyingKey = ""
            hoverX: service.hoverX
            hoverY: service.hoverY
            onActionInvoked: function(identifier) { service.invokeAction(model.key, identifier) }
            onOfferTaken: function(kind, value) { service.takeOffer(kind, value, model.key) }
            now: service.nowTick
            expanded: service.expanded
                      && (service.stacking !== "source" || service.openDeck === Layout.deckKeyFor(model, service.stacking))
            // Hover opens the body only when there is nothing else to open.
            // `toasts` is the ListModel's id, which is file-scoped - it is not
            // a property of `service`, and reaching for it that way is how this
            // line spent a morning throwing a TypeError per frame.
            sole: toasts.count === 1
            // Nothing counts down while the deck is open, mid-throw, or with
            // an answer half typed into it.
            paused: service.expanded || service.replyingKey !== "" || service.missedVisible

            // The target height, not the drawn one: a step function of the
            // card's state, so the layout moves on events rather than frames.
            drawnHeight: service.at(model.key, "height")
            // Hidden outputs collapse effective child visibility. Their text
            // measurements must not overwrite the visible deck's height.
            onTargetHeightChanged: if (surface.showingNotifications) service.noteHeight(model.key, targetHeight)
            Component.onCompleted: if (surface.showingNotifications) service.noteHeight(model.key, targetHeight)

            onExpired: service.closeToast(model.key, "expired")
            onActivated: service.activate(model.key)
            onDismissed: service.closeToast(model.key, "dismissed")
            snoozeOptions: service.snoozeOptions
            onSnoozeRequested: function(seconds) {
              service.snoozeSource(String(model.groupKey || ""),
                                   String(model.source || model.app || ""), seconds)
            }
            onSilenceRequested: service.doNotDisturb = true

            swipe: service.swipeOffsetFor(model.key, service.swipeRevision)
            groupSize: service.groupSizeOf(model.key, service.layoutRevision)
            onDismissGroupRequested: service.throwGroup(model.key)
            onDismissAllRequested: service.clearAll("dismissed")
          }
        }
        }
      }
      }

      // What you missed, pulled in from the right edge by two fingers. It
      // rides on the fingers - `missedShown` is how far in they have brought
      // it - and is otherwise the deck's own cards in a column.
      Item {
        id: missedPanel
        visible: surface.showingNotifications && service.missedVisible
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: service.barClearance
        anchors.bottomMargin: service.edgeSpacing
        width: clipper.width
        readonly property real away: width + Style.space(24)
        transform: Translate { x: (1 - service.missedShown) * missedPanel.away }
        // How far the panel is in, eased for fading: what is new to the
        // screen fades in with it; the live cards are already there and only
        // move.
        readonly property real fadeIn: Math.min(1, service.missedShown * 1.5)

        Item {
          id: missedBody
          x: clipper.deckX
          width: service.notificationWidth
          // Down to the bottom of the screen whenever there is more than fits;
          // only as tall as its cards when there is not, so the empty strip
          // below a short list stays click-through.
          height: Math.min(parent.height, missedViewport.y
                           + Math.max(service.missedLayout.height, missedEmpty.visible ? missedEmpty.height : 0))

          // The heading. A title the size of the cards' own, and room around
          // it: a thin strip above a column of full cards read as a label that
          // had lost its panel.
          BorderSurface {
            id: missedHeader
            opacity: missedPanel.fadeIn
            width: parent.width
            height: Math.max(missedTitle.implicitHeight, missedClear.implicitHeight) + Style.space(26)
            radius: Style.cornerRadius
            color: Color.notifications.background
            // The cards' own edge - the window border - so the heading reads
            // as one of them.
            borderSpec: Border.hyprlandActiveSpec(Color.notifications.border,
                                                  service.windowBorderWidth)

            Row {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              Text {
                id: missedTitle
                anchors.verticalCenter: parent.verticalCenter
                text: "Notifications"
                textFormat: Text.PlainText
                color: Color.notifications.text
                font.family: "Liberation Sans"
                font.pixelSize: Style.font.title * 1.3 * service.fontScale
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: service.missedLoaded && service.missedCount > 0
                text: String(service.missedCount)
                textFormat: Text.PlainText
                color: Qt.darker(Color.notifications.text, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.body * service.fontScale
              }
            }

            Row {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Button {
                id: missedClear
                visible: service.missedCount > 0
                text: "Clear all"
                bordered: false
                foreground: Color.notifications.text
                fontFamily: Style.font.family
                fontSize: Style.font.bodySmall * service.fontScale
                horizontalPadding: Style.space(12)
                verticalPadding: Style.space(5)
                onClicked: service.clearMissed()
              }
              Button {
                text: "✕"
                bordered: false
                implicitWidth: implicitHeight
                foreground: Color.notifications.text
                fontFamily: Style.font.family
                fontSize: Style.font.bodySmall * service.fontScale
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(5)
                onClicked: service.closeMissed()
              }
            }
          }

          Item {
            id: missedViewport
            // As wide as the panel, not as the cards: a card being swiped
            // was clipped at its own edge, so it wiped away instead of
            // sliding off the screen. The list inside sits back where the
            // cards are.
            x: -missedBody.x
            y: missedHeader.height + service.gap
            width: missedPanel.width
            height: parent.height - y
            // Not while the panel is travelling: the live cards are being
            // drawn back where the deck had them, which is outside this
            // viewport until the panel arrives, and clipping cut them in
            // half on the way. The list is at its top then, so nothing
            // needs hiding.
            clip: service.missedShown >= 0.999

            Binding {
              target: service
              property: "missedScrollMax"
              when: surface.showingNotifications
              value: Math.max(0, service.missedLayout.height - missedViewport.height)
            }

            Item {
              id: missedList
              x: missedBody.x
              width: missedBody.width
              height: service.missedLayout.height
              y: -service.missedScroll

              Repeater {
                model: missed

                Item {
                  id: missedSlot
                  required property var model
                  readonly property string key: String(model.key)
                  readonly property var place: service.missedLayout.placements[key]
                      || ({ y: 0, scale: 1, opacity: 0, z: 0, front: false, hidden: true,
                            height: 0, count: 1, size: 1 })
                  width: missedList.width
                  height: missedCard.height
                  y: place.y
                  z: place.z + (live ? 1000 : 0)
                  transformOrigin: Item.Top
                  enabled: !place.hidden

                  // A card that is on screen now starts where the deck has
                  // it and travels to its place in the panel as the panel
                  // comes in - the same fraction, so under the fingers it
                  // moves with them. `away` is how far it still has to go.
                  readonly property bool live: model.live === true
                  // Only while the panel is up: hidden, these cards exist all
                  // the time, and reading the deck's layout from them tied
                  // every arrival's layout pass to forty panel cards - a
                  // binding loop that left the deck ignoring the pointer.
                  readonly property var deckPlace: live && service.missedVisible ? service.placements[key] : null
                  readonly property real away: live && deckPlace ? 1 - service.missedShown : 0
                  readonly property real deckY: deckPlace ? deckPlace.y - service.scrollY : 0
                  readonly property real panelY: missedViewport.y + y - service.missedScroll
                  scale: place.scale + ((deckPlace ? deckPlace.scale : place.scale) - place.scale) * away
                  opacity: (live ? place.opacity + ((deckPlace ? deckPlace.opacity : 0) - place.opacity) * away
                                 : place.opacity * missedPanel.fadeIn) * enter
                  // A row that turns up after the panel is already in slides
                  // in from the edge the panel came from, rather than
                  // appearing in place.
                  property real enter: 1
                  NumberAnimation on enter {
                    id: enterRun
                    running: false
                    from: 0; to: 1
                    duration: 280
                    easing.type: Easing.OutCubic
                  }
                  Component.onCompleted: if (service.missedShown >= 0.999) enterRun.start()
                  transform: Translate {
                    x: -missedSlot.away * missedPanel.away + (1 - missedSlot.enter) * missedPanel.away
                    y: missedSlot.away * (missedSlot.deckY - missedSlot.panelY)
                  }

                  // Plain Behaviors are enough for the list's own moves:
                  // nothing in it feeds a moving height back into its layout.
                  // Off while the panel is travelling, or they would trail
                  // the fingers.
                  readonly property bool settled: service.missedShown >= 0.999
                  Behavior on y { enabled: missedSlot.settled; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                  Behavior on scale { enabled: missedSlot.settled; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                  Behavior on opacity { enabled: missedSlot.settled; NumberAnimation { duration: 180 } }

                  Toast {
                    id: missedCard
                    row: missedSlot.model
                    scene: null
                    cardWidth: missedSlot.width
                    place: missedSlot.place
                    expanded: service.missedOpenDeck !== ""
                              && service.missedOpenDeck === Layout.deckKeyFor(missedSlot.model, "source")
                    // Shut, every card in a stack is drawn at the front one's
                    // height, as in the deck; open, at its own. From the
                    // layout only, never from the card's own measurement -
                    // the card reads its drawn height back, and that closes
                    // a loop.
                    drawnHeight: Math.max(1, missedSlot.place.height || Style.space(58))
                    onTargetHeightChanged: service.noteMissedHeight(missedSlot.key, targetHeight)
                    Component.onCompleted: service.noteMissedHeight(missedSlot.key, targetHeight)
                    hovered: service.missedHoverKey === missedSlot.key
                    hoverX: service.missedHoverX - missedSlot.x
                    hoverY: service.missedHoverY - missedSlot.y
                    fontScale: service.fontScale
                    windowBorderWidth: service.windowBorderWidth
                    actionsAlign: service.actionsAlign
                    now: service.nowTick
                    swipe: {
                      service.missedGoneRevision
                      if (service.missedGone[missedSlot.key]) return service.notificationWidth + Style.space(24)
                      return service.missedSwipeKeys.indexOf(missedSlot.key) >= 0 ? service.missedSwipeX : 0
                    }
                    snoozeOptions: service.snoozeOptions
                    groupSize: service.missedGroupSize(missedSlot.key, service.missedCount)
                    onActivated: service.activateMissed(missedSlot.key)
                    onDismissed: service.dismissMissed(missedSlot.key)
                    onOfferTaken: function(kind, value) { service.takeOffer(kind, value, "") }
                    onSnoozeRequested: function(seconds) {
                      service.snoozeSource(String(missedSlot.model.groupKey || ""),
                                           String(missedSlot.model.source || missedSlot.model.app || ""),
                                           seconds)
                    }
                    onSilenceRequested: service.doNotDisturb = true
                    onDismissGroupRequested: service.throwMissedGroup(missedSlot.key)
                    onDismissAllRequested: service.clearMissed()
                  }
                }
              }
            }
          }

          // Where it is in a list taller than the screen, in the gap to the
          // screen edge like the deck's.
          Rectangle {
            visible: service.missedScrollMax > 0
            x: parent.width + Math.max(2, Math.round((clipper.edgeGap - width) / 2))
            y: missedViewport.y + (missedViewport.height - height)
               * service.missedScroll / Math.max(1, service.missedScrollMax)
            width: Style.space(3)
            radius: width / 2
            height: Math.max(Style.space(24), missedViewport.height * missedViewport.height
                                              / Math.max(1, service.missedLayout.height))
            color: Color.notifications.text
            opacity: service.missedPointerIn ? 0.45 : 0.2
          }

          Text {
            id: missedEmpty
            visible: service.missedLoaded && service.missedCount === 0
            y: missedViewport.y + Style.space(6)
            width: parent.width
            height: implicitHeight + Style.space(12)
            horizontalAlignment: Text.AlignHCenter
            text: "Nothing you missed."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Qt.darker(Color.notifications.text, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.body * service.fontScale
          }

          // The panel's own pointer region, above the cards for the same
          // reason as the deck's: a card that took hover would starve it.
          MouseArea {
            id: missedHover
            z: 5000
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            propagateComposedEvents: true

            // Everything below is in the list's own coordinates, which
            // scroll; this region does not.
            function keyAt(x, y) {
              if (y < missedViewport.y) return ""
              var ly = y - missedViewport.y + service.missedScroll
              var places = service.missedLayout.placements
              var found = "", topZ = -1
              for (var key in places) {
                var pl = places[key]
                if (pl.hidden) continue
                if (ly >= pl.y && ly <= pl.y + (pl.height || Style.space(58)) && pl.z > topZ) {
                  found = key
                  topZ = pl.z
                }
              }
              return found
            }
            function track(x, y, moved) {
              var ly = y - missedViewport.y + service.missedScroll
              service.missedHoverX = x
              service.missedHoverY = ly
              service.missedHoverKey = keyAt(x, y)
              // Resting on a stack's front card opens that stack, as in the
              // deck. Only the front card: the ones an open stack spread out
              // below it must not open whichever stack they now overlap.
              // And only when the pointer moved there. Scrolling slides the
              // list under a pointer that has not moved, and letting that
              // switch stacks shut the one being scrolled through - the list
              // shrank to a fraction of its height and jumped back to the top.
              if (!moved || y < missedViewport.y) return
              var decks = service.missedLayout.decks
              for (var i = 0; i < decks.length; i++) {
                var first = decks[i].rows[0]
                var pl = service.missedLayout.placements[first.key]
                if (!pl) continue
                var bottom = pl.y + (service.missedHeights[first.key] || Style.space(58))
                if (ly >= pl.y - Style.space(4) && ly <= bottom + Style.space(4)) {
                  if (decks[i].rows.length > 1) service.openMissedDeck(decks[i].key)
                  return
                }
              }
            }

            onContainsMouseChanged: {
              service.missedPointerIn = containsMouse
              if (!containsMouse) service.missedHoverKey = ""
            }
            onPositionChanged: function(mouse) { track(mouse.x, mouse.y, true) }
            onWheel: function(wheel) {
              track(wheel.x, wheel.y, false)
              wheel.accepted = service.missedWheel(wheel, keyAt(wheel.x, wheel.y))
            }
          }
        }
      }
    }
  }
}
