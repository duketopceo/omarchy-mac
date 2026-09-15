import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Secrets manager over the default Secret Service collection, backed by the
// omarchy-secrets-* commands. Summon with:
//   omarchy-shell shell summon omarchy.secrets '{}'
//
// Security contract: secret values never enter QML state. Copy pipes
// `omarchy-secrets-get` straight into `wl-copy --sensitive` so the value skips
// clipboard history, then a 30s timer runs `omarchy-secrets-clipclear`, which
// clears only while the clipboard still holds that secret. Add writes the
// value to the child's stdin after `started`; close() wipes every field and
// pending identity.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false

  // ---- list state ---------------------------------------------------------
  property var items: []
  property string filter: ""
  property string vault: "*"
  property bool vaultOpen: false
  property string sortMode: "name"
  property int selectedIndex: 0
  property bool loading: false
  property bool refreshPending: false

  // ---- add form -----------------------------------------------------------
  property bool adding: false
  property bool saving: false

  // ---- delete confirm -----------------------------------------------------
  property string pendingDeleteService: ""
  property string pendingDeleteAccount: ""
  property bool deleting: false

  // ---- clipboard clear ----------------------------------------------------
  property string copiedService: ""
  property string copiedAccount: ""
  property bool pendingCopy: false
  // Identity of the in-flight copy; selection may move before it exits.
  property string copyingService: ""
  property string copyingAccount: ""

  // ---- notice -------------------------------------------------------------
  property string notice: ""
  property bool noticeIsError: false

  // Vaults: distinct non-empty services with item counts, name-sorted.
  readonly property var vaults: {
    var counts = {}
    for (var i = 0; i < root.items.length; i++) {
      var s = root.items[i].service
      if (s != null && s !== "") counts[s] = (counts[s] || 0) + 1
    }
    return Object.keys(counts).sort().map(function(s) {
      return { service: s, count: counts[s] }
    })
  }

  readonly property var filtered: {
    var list = root.items
    if (root.vault !== "*")
      list = list.filter(function(it) { return it.service === root.vault })
    var f = root.filter.toLowerCase()
    if (f !== "")
      list = list.filter(function(it) {
        return (it.label || "").toLowerCase().indexOf(f) !== -1
          || (it.service || "").toLowerCase().indexOf(f) !== -1
          || (it.account || "").toLowerCase().indexOf(f) !== -1
      })
    if (root.sortMode === "recent") {
      list = list.slice().sort(function(a, b) {
        return (b.modified || 0) - (a.modified || 0)
      })
    }
    return list
  }

  function open(payloadJson) {
    root.opened = true
    refresh()
    // The window maps hidden-then-visible; grab keys once the surface exists.
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    root.opened = false
    // Wipe anything that could carry a secret or an armed identity.
    root.items = []
    root.filter = ""
    root.vault = "*"
    root.vaultOpen = false
    root.selectedIndex = 0
    root.adding = false
    root.saving = false
    root.pendingDeleteService = ""
    root.pendingDeleteAccount = ""
    root.deleting = false
    root.copiedService = ""
    root.copiedAccount = ""
    root.pendingCopy = false
    root.copyingService = ""
    root.copyingAccount = ""
    clipTimer.stop()
    root.notice = ""
    root.noticeIsError = false
    serviceField.text = ""
    accountField.text = ""
    secretField.text = ""
    confirmDialog.opened = false
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "omarchy.secrets")
    else close()
  }

  function setNotice(text, isError) {
    root.notice = text
    root.noticeIsError = isError
  }

  function refresh() {
    if (listProc.running) { root.refreshPending = true; return }
    root.loading = true
    listProc.running = true
  }

  function applyList(raw) {
    var rows = []
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line === "") continue
      try {
        var obj = JSON.parse(line)
        if (obj) rows.push(obj)
      } catch (e) {}
    }
    root.items = rows
    if (root.vault !== "*"
        && !rows.some(function(it) { return it.service === root.vault }))
      root.vault = "*"
    if (root.selectedIndex >= root.filtered.length) root.selectedIndex = Math.max(0, root.filtered.length - 1)
  }

  function cycleVault() {
    var names = ["*"].concat(root.vaults.map(function(v) { return v.service }))
    var next = (names.indexOf(root.vault) + 1) % names.length
    root.vault = names[next]
    root.selectedIndex = 0
    root.vaultOpen = false
  }

  function selectVault(service) {
    root.vault = service
    root.selectedIndex = 0
    root.vaultOpen = false
  }

  function cycleSort() {
    root.sortMode = root.sortMode === "name" ? "recent" : "name"
    root.selectedIndex = 0
  }

  function vaultLabel() {
    if (root.vault === "*") return "All vaults (" + root.items.length + ")"
    var count = 0
    for (var i = 0; i < root.vaults.length; i++)
      if (root.vaults[i].service === root.vault) count = root.vaults[i].count
    return root.vault + " (" + count + ")"
  }

  function selectedItem() {
    var list = root.filtered
    if (root.selectedIndex < 0 || root.selectedIndex >= list.length) return null
    return list[root.selectedIndex]
  }

  function actionable(it) {
    return it && it.service != null && it.service !== "" && it.account != null && it.account !== ""
  }

  function copySelected() {
    var it = selectedItem()
    if (!it) return
    if (!actionable(it)) { setNotice("Stored by another app — no service/account identity", true); return }
    if (copyProc.running) { root.pendingCopy = true; return }
    setNotice("", false)
    root.copyingService = String(it.service)
    root.copyingAccount = String(it.account)
    // The value flows through the pipe only: it never lands in a QML
    // property, and --sensitive keeps it out of omarchy clipboard history.
    copyProc.command = ["sh", "-c", "omarchy-secrets-get \"$1\" \"$2\" | wl-copy --sensitive", "sh",
      root.copyingService, root.copyingAccount]
    copyProc.running = true
  }

  function armClipClear() {
    root.copiedService = root.copyingService
    root.copiedAccount = root.copyingAccount
    clipTimer.restart()
  }

  function requestDeleteSelected() {
    var it = selectedItem()
    if (!it || !actionable(it) || root.deleting) return
    root.pendingDeleteService = String(it.service)
    root.pendingDeleteAccount = String(it.account)
    confirmDialog.message = "Delete " + root.pendingDeleteService + " / " + root.pendingDeleteAccount + "?"
    confirmDialog.selectedIndex = 0
    confirmDialog.opened = true
    Qt.callLater(function() { confirmDialog.forceActiveFocus() })
  }

  function startAdd() {
    root.adding = true
    setNotice("", false)
    Qt.callLater(function() { serviceField.forceActiveFocus() })
  }

  function cancelAdd() {
    root.adding = false
    serviceField.text = ""
    accountField.text = ""
    secretField.text = ""
    keyCatcher.forceActiveFocus()
  }

  function submitAdd() {
    var service = serviceField.text.trim()
    var account = accountField.text.trim()
    var secret = secretField.text
    if (service === "" || account === "") { setNotice("Service and account are required", true); return }
    if (secret === "") { setNotice("Secret must not be empty", true); return }
    if (setProc.running) return
    root.saving = true
    setProc.command = ["omarchy-secrets-set", service, account]
    setProc.running = true
  }

  // ---- backend processes --------------------------------------------------
  Process {
    id: listProc
    command: ["omarchy-secrets-list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyList(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") root.setNotice(err, true)
      }
    }
    onExited: function(exitCode) {
      root.loading = false
      if (root.refreshPending) {
        root.refreshPending = false
        Qt.callLater(root.refresh)
        return
      }
      if (exitCode !== 0 && root.notice === "") root.setNotice("Could not list secrets", true)
    }
  }

  Process {
    id: copyProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") root.setNotice("Copy failed: " + err, true)
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.armClipClear()
        root.setNotice("Copied to clipboard (clears in 30s)", false)
      } else if (root.notice === "") {
        root.setNotice("Copy failed", true)
      }
      if (root.pendingCopy) {
        root.pendingCopy = false
        Qt.callLater(root.copySelected)
      }
    }
  }

  // Clears the clipboard 30s after a copy, but only if the user has not
  // copied something else since: clipclear compares inside the keyring and
  // never touches the clipboard on a mismatch.
  Timer {
    id: clipTimer
    interval: 30000
    onTriggered: {
      if (root.copiedService === "") return
      clipProc.command = ["omarchy-secrets-clipclear", root.copiedService, root.copiedAccount]
      clipProc.running = true
    }
  }

  Process {
    id: clipProc
    onExited: function(exitCode) {
      root.copiedService = ""
      root.copiedAccount = ""
    }
  }

  Process {
    id: setProc
    stdinEnabled: true
    onStarted: {
      write(secretField.text)
      stdinEnabled = false
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") root.setNotice("Save failed: " + err, true)
      }
    }
    onExited: function(exitCode) {
      root.saving = false
      secretField.text = ""
      if (exitCode === 0) {
        root.adding = false
        serviceField.text = ""
        accountField.text = ""
        root.setNotice("Saved", false)
        keyCatcher.forceActiveFocus()
        root.refresh()
      } else if (root.notice === "" || !root.noticeIsError) {
        root.setNotice("Save failed", true)
      }
    }
  }

  Process {
    id: delProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") root.setNotice("Delete failed: " + err, true)
      }
    }
    onExited: function(exitCode) {
      root.deleting = false
      var done = exitCode === 0
      root.pendingDeleteService = ""
      root.pendingDeleteAccount = ""
      if (done) {
        root.setNotice("Deleted", false)
        root.refresh()
      } else if (root.notice === "" || !root.noticeIsError) {
        root.setNotice("Delete failed", true)
      }
    }
  }

  // ---- window -------------------------------------------------------------
  PanelWindow {
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-secrets"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.72)
      MouseArea { anchors.fill: parent; onClicked: root.dismiss() }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While a text field or the confirm dialog owns focus, keys belong to it.
      blocked: confirmDialog.opened
        || serviceField.activeFocus || accountField.activeFocus
        || secretField.activeFocus || filterField.activeFocus

      onMoveRequested: function(dx, dy) {
        if (dy === 0 || root.filtered.length === 0) return
        var n = root.filtered.length
        root.selectedIndex = ((root.selectedIndex + dy) % n + n) % n
      }
      onActivateRequested: root.copySelected()
      onReturnRequested: root.copySelected()
      onDeleteRequested: root.requestDeleteSelected()
      onCloseRequested: {
        if (root.vaultOpen) { root.vaultOpen = false; return }
        root.dismiss()
      }
      onTextKey: function(t) {
        if (t === "/") { filterField.forceActiveFocus(); filterField.selectAll() }
        else if (t === "a") root.startAdd()
        else if (t === "r") root.refresh()
        else if (t === "v") root.cycleVault()
        else if (t === "s") root.cycleSort()
      }

      // Centered themed card; swallows clicks so only the scrim dismisses.
      Item {
        anchors.centerIn: parent
        width: card.width
        height: card.height
        scale: Math.min(1,
          (keyCatcher.width - Style.space(32)) / Math.max(1, width),
          (keyCatcher.height - Style.space(32)) / Math.max(1, height))

        MouseArea { anchors.fill: parent; onClicked: {} }

        BorderSurface {
          id: card
          width: Math.min(Style.space(560), keyCatcher.width - Style.space(48))
          height: Math.min(Style.space(480), keyCatcher.height - Style.space(48))
          color: Color.background
          borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
          padding: Style.space(20)
          radius: Style.cornerRadius

          ColumnLayout {
            anchors.fill: parent
            anchors.topMargin: card.contentTopInset
            anchors.rightMargin: card.contentRightInset
            anchors.bottomMargin: card.contentBottomInset
            anchors.leftMargin: card.contentLeftInset
            spacing: Style.space(10)

            RowLayout {
              Layout.fillWidth: true
              Text {
                textFormat: Text.PlainText
                text: "SECRETS"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 2
              }
              Item { Layout.fillWidth: true }
              Text {
                textFormat: Text.PlainText
                text: root.loading ? "…" : root.filtered.length + " item" + (root.filtered.length === 1 ? "" : "s")
                color: Util.alpha(Color.foreground, 0.55)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Button {
                id: vaultButton
                Layout.fillWidth: true
                text: root.vaultLabel() + "  ▾"
                focusable: false
                onClicked: root.vaultOpen = !root.vaultOpen
              }

              Button {
                text: root.sortMode === "name" ? "Name" : "Recent"
                focusable: false
                onClicked: root.cycleSort()
              }
            }

            // Vault picker overlays the list while open; Escape/v close it.
            Column {
              visible: root.vaultOpen
              Layout.fillWidth: true
              spacing: Style.space(2)

              Repeater {
                model: root.vaultOpen
                  ? [{ service: "*", count: root.items.length }].concat(root.vaults)
                  : []

                Item {
                  required property var modelData
                  width: parent ? parent.width : 0
                  height: Style.space(26)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: modelData.service === root.vault
                      ? Util.alpha(Color.accent, 0.18)
                      : "transparent"
                  }

                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(10)
                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: modelData.service === "*" ? "All vaults" : modelData.service
                      color: Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: modelData.count
                      color: Util.alpha(Color.foreground, 0.45)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectVault(modelData.service)
                  }
                }
              }
            }

            TextField {
              id: filterField
              Layout.fillWidth: true
              placeholderText: "Filter…   ( / )"
              onTextChanged: {
                root.filter = text
                root.selectedIndex = 0
              }
              Keys.onEscapePressed: function(event) {
                if (text !== "") { text = ""; event.accepted = true; return }
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
              Keys.onDownPressed: function(event) {
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
            }

            Item {
              Layout.fillWidth: true
              Layout.fillHeight: true

              // Empty states share one slot; the list sits on top.
              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                visible: !root.loading && root.filtered.length === 0
                text: root.items.length === 0
                  ? (root.notice !== "" && root.noticeIsError ? "" : "No secrets stored")
                  : "No matches"
                color: Util.alpha(Color.foreground, 0.55)
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                horizontalAlignment: Text.AlignHCenter
              }

              Flickable {
                anchors.fill: parent
                clip: true
                contentHeight: rowColumn.implicitHeight
                boundsBehavior: Flickable.StopAtBounds

                Column {
                  id: rowColumn
                  width: parent.width
                  spacing: Style.space(2)

                  Repeater {
                    model: root.vaultOpen ? [] : root.filtered

                    Item {
                      required property int index
                      required property var modelData

                      width: rowColumn.width
                      height: Style.space(34)

                      readonly property bool isSelected: index === root.selectedIndex
                      readonly property bool isActionable: root.actionable(modelData)
                      readonly property bool isExternal: modelData.app !== "omarchy"

                      Rectangle {
                        anchors.fill: parent
                        radius: Style.cornerRadius
                        color: isSelected ? Util.alpha(Color.accent, 0.18) : "transparent"
                      }

                      RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(10)
                        anchors.rightMargin: Style.space(10)
                        spacing: Style.space(8)

                        Text {
                          Layout.fillWidth: true
                          textFormat: Text.PlainText
                          text: isActionable
                            ? modelData.service + " / " + modelData.account
                            : (modelData.label || "(unnamed)")
                          color: isActionable
                            ? (isSelected ? Color.foreground : Util.alpha(Color.foreground, 0.85))
                            : Util.alpha(Color.foreground, 0.45)
                          font.family: Style.font.family
                          font.pixelSize: Style.font.bodySmall
                          elide: Text.ElideRight
                        }

                        Text {
                          visible: !isActionable || isExternal
                          textFormat: Text.PlainText
                          text: isActionable ? "ext" : "other app"
                          color: Util.alpha(Color.foreground, 0.35)
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                        }

                        Text {
                          visible: isActionable && isSelected
                          textFormat: Text.PlainText
                          text: "copy"
                          color: Color.accent
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: isActionable ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onEntered: root.selectedIndex = index
                        // copySelected() explains itself for foreign rows.
                        onClicked: root.copySelected()
                      }
                    }
                  }
                }
              }
            }

            // Add form slides in under the list.
            ColumnLayout {
              visible: root.adding
              Layout.fillWidth: true
              spacing: Style.space(6)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)
                TextField {
                  id: serviceField
                  Layout.fillWidth: true
                  placeholderText: "service"
                  Keys.onReturnPressed: accountField.forceActiveFocus()
                  Keys.onEscapePressed: root.cancelAdd()
                }
                TextField {
                  id: accountField
                  Layout.fillWidth: true
                  placeholderText: "account"
                  Keys.onReturnPressed: secretField.forceActiveFocus()
                  Keys.onEscapePressed: root.cancelAdd()
                }
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)
                TextField {
                  id: secretField
                  Layout.fillWidth: true
                  placeholderText: "secret"
                  password: true
                  Keys.onReturnPressed: root.submitAdd()
                  Keys.onEscapePressed: root.cancelAdd()
                }
                Button {
                  text: root.saving ? "…" : "Save"
                  focusable: false
                  onClicked: root.submitAdd()
                }
                Button {
                  text: "Cancel"
                  focusable: false
                  onClicked: root.cancelAdd()
                }
              }
            }

            Text {
              visible: root.notice !== ""
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.notice
              color: root.noticeIsError ? Color.urgent : Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: "j/k move   enter copy   x delete   / filter   v vault   s sort   a add   r refresh   esc close"
              color: Util.alpha(Color.foreground, 0.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        confirmText: "Delete"
        Keys.onPressed: function(event) {
          if (handleKey(event)) event.accepted = true
        }
        onCanceled: {
          opened = false
          root.pendingDeleteService = ""
          root.pendingDeleteAccount = ""
          keyCatcher.forceActiveFocus()
        }
        onConfirmed: {
          opened = false
          if (root.pendingDeleteService === "") { keyCatcher.forceActiveFocus(); return }
          root.deleting = true
          delProc.command = ["omarchy-secrets-delete", root.pendingDeleteService, root.pendingDeleteAccount]
          delProc.running = true
          keyCatcher.forceActiveFocus()
        }
      }
    }
  }
}
