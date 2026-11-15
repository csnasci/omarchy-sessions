import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Named Hyprland sessions. The bar icon opens a small panel: a Save Session
// button on top (it turns into a name field), and every saved session below as
// a card with its name and the icons of its apps. Clicking a card restores
// that session; the ✕ in its corner deletes it after a second click. All the work happens in bin/omarchy-sessions, which wraps the
// vendored hypr-layout; this file only draws and calls it with argv (no shell).
Panel {
  id: root
  moduleName: "io.github.csnasci.sessions"
  ipcTarget: "omarchy-sessions"
  manageIpc: false  // own ShellIpc below adds save/restore/delete to open/close/toggle

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string tool: decodeURIComponent(String(Qt.resolvedUrl("bin/omarchy-sessions")).replace(/^file:\/\//, ""))

  property var sessions: []            // [{ name, apps: [{ desktop, class }] }]
  readonly property var sessionNames: sessions.map(function(s) { return s.name })
  property bool naming: false          // the Save button became a name field
  property string pendingDelete: ""    // chip waiting for the confirming click
  property string busyName: ""         // session being saved or restored
  property real restoreProgress: -1    // 0..1 while restoring, -1 otherwise
  property int restoreDone: 0
  property int restoreTotal: 0
  readonly property color accent: Commons.Color.accent
  property var alreadyOpen: []         // [{ ws, name }] apps that allow one window, open elsewhere

  // The ring ends in the theme's own green / yellow / red (colors.toml has
  // them; Commons.Color does not expose them), then fades out.
  property var themeColors: ({})
  readonly property color okColor: themeColors.green || "#7fb069"
  readonly property color warnColor: themeColors.yellow || "#e9bb4f"
  readonly property color failColor: themeColors.red || urgent
  property color ringColor: accent
  Behavior on ringColor { ColorAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
  onRingColorChanged: ring.requestPaint()

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
          + "/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var out = {}
      String(text()).split("\n").forEach(function(line) {
        var m = line.match(/^\s*(green|yellow|red)\s*=\s*"(#[0-9a-fA-F]{6,8})"/)
        if (m) out[m[1]] = m[2]
      })
      root.themeColors = out
    }
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // Same rule as bin/omarchy-sessions: letters (accents included), digits,
  // space . - _ ; 1-32 chars; starts with a letter or digit; no "..".
  // Checked per character: a \p{L} regex left the list empty here.
  function isAlnum(c) {
    return (c >= "0" && c <= "9") || c.toLowerCase() !== c.toUpperCase()
  }

  function isValidName(name) {
    name = String(name)
    if (name.length < 1 || name.length > 32 || name.indexOf("..") >= 0) return false
    if (!isAlnum(name[0])) return false
    for (var i = 1; i < name.length; i++) {
      var c = name[i]
      if (!isAlnum(c) && c !== " " && c !== "." && c !== "-" && c !== "_") return false
    }
    return true
  }

  // Icon for a saved app: its .desktop entry's Icon, resolved against the
  // icon theme the way the workspaces widget does it. "" when there is none.
  function appIcon(app) {
    var entry = null
    var id = String(app.desktop || "").replace(/\.desktop$/, "")
    try { if (id) entry = DesktopEntries.byId(id) } catch (e) { entry = null }
    if (!entry && app["class"]) {
      try { entry = DesktopEntries.byId(app["class"]) || DesktopEntries.heuristicLookup(app["class"]) } catch (e) { entry = null }
    }
    if (!entry || !entry.icon) return ""
    var name = String(entry.icon)
    if (name.charAt(0) === "/") return "file://" + name
    if (name.indexOf("file://") === 0 || name.indexOf("image://") === 0) return name
    return Quickshell.iconPath(name, true)
  }

  function notify(text) {
    Quickshell.execDetached(["notify-send", "-a", strings.t("tooltip"), "-i", "window-restore", text])
  }

  function refresh() {
    if (!listProc.running) listProc.running = true
  }

  function startNaming() {
    pendingDelete = ""
    naming = true
    Qt.callLater(function() { nameField.text = ""; nameField.forceActiveFocus() })
  }

  function stopNaming() {
    naming = false
    nameField.text = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function save(name) {
    name = String(name).trim()
    if (!isValidName(name) || saveProc.running) return
    busyName = name
    saveProc.command = [tool, "save", name]
    saveProc.running = true
    stopNaming()
  }

  function restore(name) {
    if (restoreProc.running) return
    pendingDelete = ""
    busyName = name
    finishAnim.stop()
    ring.fade = 1
    ringColor = Qt.binding(function() { return root.accent })
    restoreProgress = 0
    restoreDone = 0
    restoreTotal = 0
    alreadyOpen = []
    restoreProc.output = ""
    restoreProc.command = [tool, "restore", name]
    restoreProc.running = true
    close()
  }

  // Close the ring, turn it the outcome's color, hold a moment, fade out.
  function finishRing(color) {
    ringColor = color
    restoreProgress = 1
    finishAnim.restart()
  }

  SequentialAnimation {
    id: finishAnim
    PauseAnimation { duration: 900 }
    NumberAnimation { target: ring; property: "fade"; to: 0; duration: Style.duration(320); easing.type: Easing.OutCubic }
    ScriptAction {
      script: {
        root.restoreProgress = -1
        ring.fade = 1
        root.ringColor = Qt.binding(function() { return root.accent })
      }
    }
  }

  function requestDelete(name) {
    if (pendingDelete !== name) {
      pendingDelete = name
      confirmTimer.restart()
      return
    }
    pendingDelete = ""
    deleteProc.command = [tool, "delete", name]
    deleteProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      refresh()
    } else {
      naming = false
      pendingDelete = ""
    }
  }

  Component.onCompleted: refresh()

  // omarchy-shell omarchy-sessions <method> [name] — the same paths the
  // panel's clicks take, so they also work from keybindings.
  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function list(): string { return root.sessionNames.join("\n") }
    function save(name: string): string {
      if (!root.isValidName(name)) return "invalid name"
      root.save(name)
      return "ok"
    }
    function restore(name: string): string {
      if (root.sessionNames.indexOf(name) < 0) return "no session named " + name
      root.restore(name)
      return "ok"
    }
    function remove(name: string): string {
      if (root.sessionNames.indexOf(name) < 0) return "no session named " + name
      root.pendingDelete = name
      root.requestDelete(name)
      return "ok"
    }
  }

  Timer {
    id: confirmTimer
    interval: 3000
    onTriggered: root.pendingDelete = ""
  }

  Process {
    id: listProc
    command: [root.tool, "list", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = []
        try { parsed = JSON.parse(String(text || "[]")) } catch (e) { parsed = [] }
        root.sessions = (Array.isArray(parsed) ? parsed : [])
          .filter(function(s) { return s && root.isValidName(s.name) })
          .map(function(s) {
            var apps = Array.isArray(s.apps) ? s.apps.slice(0, 32) : []
            return { name: String(s.name), apps: apps }
          })
      }
    }
  }

  Process {
    id: saveProc
    onExited: function(exitCode) {
      root.notify(exitCode === 0 ? strings.t("notify.saved").arg(root.busyName)
                                 : strings.t("notify.saveFailed").arg(root.busyName))
      root.busyName = ""
      root.refresh()
    }
  }

  Process {
    id: restoreProc
    property string output: ""
    // "progress <0..1> <done>/<total>" lines drive the ring; the last other
    // line is the summary ("N/M windows placed on workspace W").
    stdout: SplitParser {
      onRead: function(line) {
        var m = String(line).match(/^progress ([0-9.]+) (\d+)\/(\d+)$/)
        var a = String(line).match(/^already-open ([^\t]{1,40})\t(.{1,80})$/)
        if (m) {
          root.restoreProgress = Math.max(root.restoreProgress, Math.min(1, parseFloat(m[1])))
          root.restoreDone = parseInt(m[2])
          root.restoreTotal = parseInt(m[3])
        } else if (a) {
          root.alreadyOpen = root.alreadyOpen.concat([{ ws: a[1], name: a[2] }])
        } else if (String(line).trim() !== "") {
          restoreProc.output = String(line)
        }
      }
    }
    onExited: function(exitCode) {
      var name = root.busyName
      root.busyName = ""
      // The script ends with "N/M windows placed on workspace W".
      var m = restoreProc.output.match(/(\d+)\/(\d+) windows placed/)
      var extra = root.alreadyOpen.map(function(o) {
        return strings.t("notify.alreadyOpen").arg(o.name).arg(o.ws)
      }).join("\n")
      var text, color
      if (m && m[1] !== m[2]) {
        text = strings.t("notify.restoredCount").arg(name).arg(m[1]).arg(m[2])
        color = root.warnColor
      } else if (exitCode === 0 || m) {
        text = strings.t("notify.restored").arg(name)
        color = root.okColor
      } else {
        text = strings.t("notify.restoreFailed").arg(name)
        color = root.failColor
      }
      root.notify(extra ? text + "\n" + extra : text)
      root.finishRing(color)
    }
  }

  Process {
    id: deleteProc
    onExited: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖲"
    tooltipText: root.restoreProgress >= 0 && root.restoreTotal > 0
      ? strings.t("restoringTip").arg(root.busyName).arg(root.restoreDone).arg(root.restoreTotal)
      : strings.t("tooltip")
    active: root.busyName !== ""
    activeColor: root.accent          // theme accent, not the urgent red
    onPressed: function(buttonCode) { root.toggle() }
  }

  // Thin ring around the bar icon that closes as the restore advances.
  Canvas {
    id: ring
    readonly property real size: Math.min(button.width, button.height) - Style.space(2)
    readonly property real value: root.restoreProgress
    anchors.centerIn: button
    width: size
    height: size
    property real fade: 1
    visible: opacity > 0
    opacity: value >= 0 ? fade : 0
    Behavior on opacity { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
    property real shown: Math.max(0, value)
    Behavior on shown { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }
    onShownChanged: requestPaint()
    onSizeChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var lw = Math.max(1.5, size * 0.07)
      var r = size / 2 - lw / 2
      var c = size / 2
      ctx.lineWidth = lw
      ctx.lineCap = "round"
      ctx.strokeStyle = Qt.rgba(root.ringColor.r, root.ringColor.g, root.ringColor.b, 0.22)
      ctx.beginPath()
      ctx.arc(c, c, r, 0, Math.PI * 2)
      ctx.stroke()
      if (shown > 0) {
        ctx.strokeStyle = root.ringColor
        ctx.beginPath()
        ctx.arc(c, c, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * shown)
        ctx.stroke()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.naming
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        // Save Session, centered on top. While naming it becomes the name
        // field (Enter saves, Esc backs out). The cards below need no title.
        Button {
          id: saveButton
          visible: !root.naming
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width               // lines up with the card grid below
          text: strings.t("save")
          iconText: "󰆓"
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          iconSize: Style.font.body
          verticalPadding: Style.space(5)
          bordered: true
          enabled: !saveProc.running
          onClicked: root.startNaming()
        }

        Column {
          visible: root.naming
          width: parent.width
          spacing: Style.space(4)

          TextField {
            id: nameField
            width: parent.width
            foreground: root.foreground
            placeholderText: strings.t("namePlaceholder")
            maximumLength: 32
            onAccepted: root.save(text)
            Keys.onEscapePressed: function(event) { root.stopNaming(); event.accepted = true }
          }

          Text {
            readonly property string typed: nameField.text.trim()
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.Wrap
            visible: text !== ""
            text: typed === "" ? ""
                : !root.isValidName(typed) ? strings.t("invalidName")
                : root.sessionNames.indexOf(typed) >= 0 ? strings.t("replaceHint").arg(typed)
                : ""
            color: !root.isValidName(typed) ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          visible: root.sessions.length === 0
          textFormat: Text.PlainText
          text: strings.t("empty")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // Three equal columns; full rows span the panel, the last row is centered.
        Column {
          id: cards
          visible: root.sessions.length > 0
          width: parent.width
          spacing: Style.space(8)
          readonly property int columns: 3
          readonly property real cardWidth: Math.floor((width - spacing * (columns - 1)) / columns)
          readonly property real iconSize: Style.space(18)
          readonly property real iconGap: Style.space(3)
          readonly property var rows: {
            var out = []
            for (var i = 0; i < root.sessions.length; i += columns)
              out.push(root.sessions.slice(i, i + columns))
            return out
          }

          Repeater {
            model: cards.rows

            Row {
              required property var modelData
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: cards.spacing

              Repeater {
                model: modelData

            BorderSurface {
              id: card
              required property var modelData
              readonly property string name: modelData.name
              readonly property var apps: modelData.apps || []
              readonly property bool confirming: root.pendingDelete === name
              readonly property bool hot: cardMouse.containsMouse || closeMouse.containsMouse
              readonly property real badge: Style.space(16)
              readonly property real pad: Style.space(8)
              // As many icons as fit; when some are left over, the last slot shows "+N".
              readonly property int fit: Math.max(1, Math.floor((width - pad * 2 + cards.iconGap) / (cards.iconSize + cards.iconGap)))
              readonly property int maxIcons: apps.length > fit ? fit - 1 : fit

              width: cards.cardWidth
              height: inner.implicitHeight + Style.space(16)
              radius: Style.spacing.labelGap
              color: confirming ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.15)
                   : hot ? Style.selectedFillFor(root.foreground, Commons.Color.accent)
                   : Style.normalFillFor(root.foreground, Commons.Color.accent)
              borderSpec: Border.controlSpec(hot ? "hover-cursor" : "normal", root.foreground, Commons.Color.accent)

              MouseArea {
                id: cardMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (card.confirming) root.pendingDelete = ""
                  else root.restore(card.name)
                }
              }

              // Full name on hover when the card had to cut it.
              PanelToolTip {
                visible: cardMouse.containsMouse && nameText.truncated && !card.confirming
                text: card.name
                fontFamily: root.fontFamily
              }

              Column {
                id: inner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: card.pad
                anchors.rightMargin: card.pad
                spacing: Style.space(6)

                // Centered, with the same room kept free on both sides so the
                // ✕ in the corner never sits on top of it.
                Text {
                  id: nameText
                  readonly property real side: card.badge - Style.space(2)
                  textFormat: Text.PlainText
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: parent.width - side * 2
                  horizontalAlignment: Text.AlignHCenter
                  text: card.confirming ? strings.t("confirmShort") : card.name
                  color: card.confirming ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: card.confirming
                  elide: Text.ElideRight
                }

                Row {
                  id: iconRow
                  anchors.horizontalCenter: parent.horizontalCenter
                  visible: card.apps.length > 0
                  spacing: cards.iconGap
                  opacity: card.confirming ? 0.4 : 1

                  Repeater {
                    model: card.apps.slice(0, card.maxIcons)


                    Item {
                      id: iconItem
                      required property var modelData
                      readonly property string source: root.appIcon(modelData)
                      width: cards.iconSize
                      height: cards.iconSize

                      Image {
                        anchors.fill: parent
                        visible: iconItem.source !== "" && status === Image.Ready
                        source: iconItem.source
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                        mipmap: true
                        asynchronous: true
                        sourceSize.width: Math.round(width * 2)
                        sourceSize.height: Math.round(height * 2)
                      }

                      // No icon: the app's first letter on a small tile.
                      Rectangle {
                        anchors.fill: parent
                        visible: iconItem.source === ""
                        radius: Style.space(4)
                        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

                        Text {
                          anchors.centerIn: parent
                          textFormat: Text.PlainText
                          text: String(iconItem.modelData["class"] || "?").replace(/^.*\./, "").charAt(0).toUpperCase()
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }
                      }
                    }
                  }

                  Text {
                    visible: card.apps.length > card.maxIcons
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: strings.t("moreApps").arg(card.apps.length - card.maxIcons)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              // ✕ in the top-right corner: dim until the card is hovered,
              // red while it waits for the confirming second click.
              Text {
                id: closeBadge
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: Style.space(4)
                anchors.rightMargin: Style.space(6)
                width: card.badge
                height: card.badge
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                textFormat: Text.PlainText
                text: "✕"
                color: card.confirming || closeMouse.containsMouse ? root.urgent : root.dim
                opacity: card.confirming || card.hot ? 1 : 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                MouseArea {
                  id: closeMouse
                  anchors.fill: parent
                  anchors.margins: -Style.space(3)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.requestDelete(card.name)
                }
              }
            }
              }
            }
          }
        }
      }
    }
  }
}
