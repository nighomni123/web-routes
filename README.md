# Web Routes

Web Routes is a macOS menu bar app that lets you choose Wi-Fi or Android USB tethering for individual Firefox windows. You can also open a separate Firefox profile for each connection or copy a Safari window’s web tabs into a routed Firefox profile.

## Requirements

- macOS 12 or later with Xcode Command Line Tools and `/usr/bin/python3`.
- Firefox in `/Applications`. The window companion requires Firefox 140 or later.
- An active macOS network interface for each route you want to use. For Android phones that expose RNDIS, install a compatible driver such as [usb-android-tethering](https://github.com/frosty-universe/usb-android-tethering) and enable USB tethering on the phone.

## Build and launch

```sh
/bin/sh build.sh
open "$HOME/Applications/Web Routes.app"
```

The build installs the app in your user Applications folder and registers its Firefox native messaging host for your macOS account.

The default interfaces are `en0` for Wi-Fi and `feth7070` for USB tethering. If your Mac uses other names, find them in `networksetup -listallhardwareports` or `ifconfig -l`, then set the relevant preferences and reopen Web Routes.

```sh
defaults write local.web-routes WiFiInterface -string en0
defaults write local.web-routes USBInterface -string feth7070
```

## Use the menu

- **Open Wi-Fi Browser** or **Open USB Browser** opens a dedicated Firefox profile. Each profile has its own cookies and sign-ins.
- **Firefox Windows** lists regular windows in profiles with the companion installed. Choose **Use Wi-Fi**, **Use USB**, or **Use Firefox Default**. The selection applies to new requests Firefox associates with that window. Reload the tab to start new connections.
- **Safari Windows** lists open Safari windows after you grant macOS Automation access. The route actions open copies of the selected window’s HTTP and HTTPS URLs in a routed Firefox profile. Safari keeps its original tabs, sign-ins, and form entries.

## Install the Firefox companion

For a temporary installation, open **Web Routes → Firefox Windows → Connect Firefox…** and follow the instructions to load `Companion/manifest.json` from Firefox’s **Load Temporary Add-on** picker. A temporary add-on expires when Firefox quits.

For a permanent installation, use a [Mozilla-signed package](https://extensionworkshop.com/documentation/publish/signing-and-distribution-overview/) or build a local unsigned package from this source.

```sh
(cd Companion && zip -j ../web-routes-companion.xpi manifest.json windows.js)
```

[Firefox ESR supports local unsigned installation](https://extensionworkshop.com/documentation/enterprise/enterprise-distribution/) when `xpinstall.signatures.required` is set to `false` in `about:config`. In that profile, choose **Add-ons and themes → gear menu → Install Add-on From File** and select the packaged extension. This profile-level preference permits other unsigned extensions, too.

## Routing and data

Web Routes listens on `127.0.0.1` ports `48771` and `48772`. The SOCKS5 proxy binds outbound IPv4 connections and Cloudflare DNS-over-HTTPS queries to the selected interface. Proxied requests fail when that interface is unavailable. Firefox requests without a window association follow Firefox’s normal routing. The dedicated launch profiles disable WebRTC.

The Firefox companion sends regular window IDs and active-tab titles to the local native host so the menu can identify windows. The host stores this data under the current user’s Application Support folder while the browser is connected. Route selections are scoped to the running Firefox session.
