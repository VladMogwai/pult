# MediaCast — DLNA Media Controller for iOS

Stream local video files to any Samsung Smart TV (or other DLNA/UPnP renderer)
directly from your iPhone.

## Requirements

| Item | Version |
|------|---------|
| Xcode | 15+ |
| iOS deployment target | 16.0+ |
| Swift | 5.9+ |

---

## Xcode Project Setup

### 1. Create a new iOS App project

1. **File → New → Project → iOS → App**
2. Product Name: `MediaCast`
3. Interface: **SwiftUI**
4. Language: **Swift**
5. Uncheck "Include Tests" (optional)

### 2. Add source files

Delete the generated `ContentView.swift` and `<AppName>App.swift`.

Drag the following folders into the Xcode project navigator
(select **"Copy items if needed"** + **"Create groups"**):

```
MediaCast/App/
MediaCast/Services/
MediaCast/Views/
MediaCast/Utilities/
```

### 3. Replace Info.plist

Open your target's **Info** tab (or the raw `Info.plist`) and add:

| Key | Type | Value |
|-----|------|-------|
| `NSLocalNetworkUsageDescription` | String | `MediaCast discovers DLNA/UPnP renderers on your local Wi-Fi to stream video to your TV.` |
| `NSBonjourServices` | Array | `_ssdp._udp`, `_upnp._tcp`, `_http._tcp` |
| `NSAppTransportSecurity` → `NSAllowsLocalNetworking` | Boolean | YES |

Alternatively, drag `MediaCast/Resources/Info.plist` in and use it as
the project's custom Info.plist (set the path in Build Settings →
**Info.plist File**).

### 4. Add GCDWebServer via Swift Package Manager

1. **File → Add Package Dependencies…**
2. Enter URL: `https://github.com/swisspol/GCDWebServer`
3. Dependency Rule: **Up to Next Major Version** `3.5.4`
4. Add **GCDWebServer** product to your app target.

Because GCDWebServer is Objective-C, Xcode will generate a bridging
header automatically when you first add it. If it doesn't:

- **File → New → File → Objective-C File** (name anything, then delete it)
- Accept the bridging header offer.
- The generated header will be at `MediaCast/MediaCast-Bridging-Header.h`
  — it can stay empty.

### 5. Set the deployment target

Target → **General → Minimum Deployments → iOS 16.0**

### 6. Build & Run

Connect a real device (SSDP multicast does not work in the iOS Simulator).

---

## How It Works

```
Phone                           Local Wi-Fi              Samsung TV
  │                                  │                       │
  │──── SSDP M-SEARCH multicast ────►│──────────────────────►│
  │◄─── HTTP 200 (LOCATION: …) ──────│◄──────────────────────│
  │──── GET device description ──────│──────────────────────►│
  │◄─── XML (control URLs) ──────────│◄──────────────────────│
  │                                  │                       │
  │  [user picks file + device]      │                       │
  │                                  │                       │
  │  GCDWebServer starts on :8080    │                       │
  │──── SOAP SetAVTransportURI ──────│──────────────────────►│ (sends http://phone-ip:8080/video/…)
  │──── SOAP Play ───────────────────│──────────────────────►│
  │                                  │                       │
  │◄── TV pulls video via HTTP ──────│◄──────────────────────│
  │                                  │                       │
  │  (every 2 s) SOAP GetPositionInfo│                       │
  │──────────────────────────────────│──────────────────────►│
  │◄── RelTime / TrackDuration ──────│◄──────────────────────│
```

### Key design decisions

- **No third-party UPnP library** — SSDP is done with BSD sockets
  (`socket` / `sendto` / `recv`) run on a `DispatchQueue`, and SOAP
  requests use plain `URLSession`.
- **GCDWebServer** handles HTTP range requests automatically, which is
  required for seek-by-byte on the TV side.
- **`@MainActor`** on `DLNAController` and `SSDPDiscovery` means all
  published-property mutations are safe without manual `DispatchQueue.main`.
- The video URL always uses the phone's real Wi-Fi IP (`en0`), never
  `localhost` — the TV must be able to reach the phone.

---

## Tab overview

| Tab | Purpose |
|-----|---------|
| **Devices** | SSDP discovery — tap a TV to select it |
| **Files** | Pick a local video via the document picker |
| **Remote** | Cast, Play/Pause, Stop, Seek, Volume |

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| No devices found | Make sure phone and TV are on the same Wi-Fi network. Tap ↺ to rescan. |
| "Could not determine local IP" | Go to Settings → Wi-Fi and confirm you are connected. |
| TV plays audio but no video | The TV may not support the container. Re-encode to H.264/MP4. |
| App crashes on Simulator | SSDP multicast requires a real device. |
| HTTP 500 from TV on SetAVTransportURI | Check that `NSAllowsLocalNetworking` is set in Info.plist. |
