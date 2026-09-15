#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const panelSource = fs.readFileSync(root + '/shell/plugins/secrets/Panel.qml', 'utf8')
const manifest = JSON.parse(fs.readFileSync(root + '/shell/plugins/secrets/manifest.json', 'utf8'))

assert(manifest.id === 'omarchy.secrets', 'plugin id is omarchy.secrets')
assert(manifest.entryPoints.panel === 'Panel.qml', 'panel entry point resolves')

// Backend: every secret operation routes through the native commands; the
// panel never touches Secret Service or wl-copy directly beyond the copy pipe.
assert(/command: \["omarchy-secrets-list"\]/.test(panelSource), 'list uses omarchy-secrets-list')
assert(/omarchy-secrets-get \\\"\$1\\\" \\\"\$2\\\" \| wl-copy --sensitive/.test(panelSource), 'copy pipes get into wl-copy --sensitive')
assert(/setProc\.command = \["omarchy-secrets-set", service, account\]/.test(panelSource), 'add uses omarchy-secrets-set')
assert(/delProc\.command = \["omarchy-secrets-delete", root\.pendingDeleteService, root\.pendingDeleteAccount\]/.test(panelSource), 'delete acts on service/account identity, never a row index')
assert(/clipProc\.command = \["omarchy-secrets-clipclear", root\.copiedService, root\.copiedAccount\]/.test(panelSource), 'timed clear uses omarchy-secrets-clipclear')

// The secret value must never land in a QML property: it is piped on copy and
// written to the child's stdin from the started handler on add.
assert(/stdinEnabled: true[\s\S]*onStarted: \{\s*write\(secretField\.text\)/.test(panelSource), 'add writes the secret to stdin after started')

// Clipboard hygiene: --sensitive skips clipboard history; the 30s timer arms
// the conditional clear against the identity captured at copy time.
assert(/wl-copy --sensitive/.test(panelSource), 'copy marks the clipboard sensitive')
assert(/interval: 30000/.test(panelSource), 'clipboard clears after 30s')
assert(/copyingService[\s\S]*copyProc\.command/.test(panelSource), 'copy captures identity before the async exit')

// Keyboard contract.
assert(/onMoveRequested/.test(panelSource), 'arrows/jk move the selection')
assert(/onReturnRequested: root\.copySelected/.test(panelSource), 'enter copies')
assert(/onDeleteRequested: root\.requestDeleteSelected/.test(panelSource), 'x requests deletion')
assert(/t === "\/"/.test(panelSource), '/ focuses the filter')
assert(/t === "v"[\s\S]*cycleVault/.test(panelSource), 'v cycles vaults')
assert(/t === "s"[\s\S]*cycleSort/.test(panelSource), 's cycles sort')
assert(/t === "r"[\s\S]*refresh/.test(panelSource), 'r refreshes')
assert(/if \(root\.vaultOpen\) \{ root\.vaultOpen = false; return \}/.test(panelSource), 'escape closes the vault picker before the panel')

// Organization: vault dropdown with per-service counts, name/recent sort,
// and provenance badges.
assert(/property string vault: "\*"/.test(panelSource), 'vaults default to all')
assert(/sortMode === "recent"[\s\S]*b\.modified \|\| 0\) - \(a\.modified/.test(panelSource), 'recent sort uses modified timestamps')
assert(/modelData\.app !== "omarchy"/.test(panelSource), 'external badge reads the app attribute')
assert(/text: isActionable \? "ext" : "other app"/.test(panelSource), 'rows badge foreign credentials')

// Safety: delete goes through the confirm dialog; close() wipes fields and
// pending identities; coalesced copy/delete/refresh guards exist.
assert(/ConfirmDialog[\s\S]*confirmText: "Delete"/.test(panelSource), 'deletion confirms first')
assert(/root\.copiedService = ""[\s\S]*clipTimer\.stop\(\)/.test(panelSource), 'close() wipes pending clipboard identity and stops the timer')
assert(/if \(copyProc\.running\) \{ root\.pendingCopy = true; return \}/.test(panelSource), 'copy coalesces while one is in flight')
assert(/if \(listProc\.running\) \{ root\.refreshPending = true; return \}/.test(panelSource), 'refresh queues behind a running list')
assert(/if \(!it \|\| !actionable\(it\) \|\| root\.deleting\) return/.test(panelSource), 'delete is guarded')
JS
