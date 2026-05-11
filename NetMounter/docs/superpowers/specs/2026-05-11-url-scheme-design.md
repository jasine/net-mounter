# URL Scheme Import & Share

## Problem

No way to share server configurations between team members or devices. Users must manually type host/path/protocol for each server.

## Solution

Register a `netmounter://` URL scheme. Users can share server configs as links, and generate those links from existing configs via a "Share" button.

## URL Format

```
netmounter://add?host=192.168.1.100&proto=smb&share=shared&alias=NAS
```

| Parameter | Required | Description | Default |
|-----------|----------|-------------|---------|
| `host` | Yes | Hostname or IP | — |
| `proto` | No | `smb`, `afp`, `nfs`, `webdav` | `smb` |
| `share` | No | Share path | empty |
| `alias` | No | Display name | host value |

Credentials are never included in URLs — users configure them in-app after import.

## Import Flow

1. User clicks `netmounter://add?...` link in browser, Slack, email, etc.
2. macOS launches NetMounter; `NSAppleEventManager` dispatches `kAEGetURL` event
3. App parses URL parameters, validates `host` is present
4. Checks for duplicate (same host + protocol + share path) — shows "already exists" alert if found
5. Shows `NSAlert` confirmation dialog with server details
6. User confirms → `ServerConfig` created → `appState.addServer()`
7. User cancels → no action

## Share Flow

1. User clicks share (link icon) button on the server card in `ServerListView`
2. App generates `netmounter://` URL from `ServerConfig.shareURL`
3. URL copied to system clipboard (`NSPasteboard`)
4. Toast overlay shows "Share link copied" with fade animation, auto-dismisses after 2 seconds

## URL Scheme Registration

Add `CFBundleURLTypes` to Info.plist in `package_app.sh`:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>netmounter</string>
        </array>
        <key>CFBundleURLName</key>
        <string>com.netmounter.app</string>
    </dict>
</array>
```

## File Changes

| File | Change |
|------|--------|
| `Models/ServerConfig.swift` | Add `shareURL` computed property |
| `Views/ServerListView.swift` | Add share button on each server card with toast overlay |
| `AppDelegate.swift` | Register `NSAppleEventManager` handler for URL parsing, dedup check, and confirmation alert |
| `package_app.sh` | Add `CFBundleURLTypes` to generated Info.plist |

## Security

- Confirmation dialog prevents malicious links from silently injecting configs
- No credentials in URLs — only structural server info (host, protocol, share, alias)
- Invalid or missing `host` parameter → URL silently ignored
