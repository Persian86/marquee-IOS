# Marquee for iPhone & iPad

The Marquee app for iOS. It opens your Marquee server full screen (just like the Android app) and adds:

- **Downloads that work offline** — they keep downloading when you leave the app, and play with no internet in Apple's own player (picture-in-picture, AirPlay, lock-screen controls). Where you got to is sent back to Marquee when you're online again. Files also show in the **Files** app → On My iPhone → Marquee.
- **"New on Marquee" notifications** with the poster — tap one to open that movie or episode.
- **Music and podcasts keep playing** with the screen locked.
- **Picture-in-picture** button in the player, **AirPlay** to an Apple TV, screen stays on while watching.
- Remembers your server, works with plain `http://` home addresses and Tailscale.

Needs iOS / iPadOS 15 or newer.

## Getting it onto your iPhone (from a Windows PC)

Apple only lets apps be installed from the App Store, TestFlight, or by signing them with your own Apple ID. Two parts: build the app, then install it.

### 1. Build it (free, on GitHub's Macs)

1. Make a free account at github.com if you don't have one, and create a new **private** repository called `marquee-ios`.
2. Upload everything in this folder to it (drag the files onto the repo page → *Commit changes*). Make sure the hidden `.github` folder goes too — GitHub Desktop is easiest for that.
3. Open the repo's **Actions** tab → **Build iOS app** → **Run workflow**. It takes about 5 minutes.
4. Open the finished run and download **Marquee-ipa** at the bottom. Unzip it — you get `Marquee.ipa`.

### 2. Install it

**Free Apple ID (Sideloadly)**
1. On your PC install **iTunes** (the apple.com version, not the Microsoft Store one) and **Sideloadly** (sideloadly.io).
2. Plug in your iPhone by cable, tap *Trust* on the phone.
3. In Sideloadly drag in `Marquee.ipa`, enter your Apple ID, press **Start**.
4. On the iPhone: Settings → General → VPN & Device Management → your Apple ID → **Trust**. On iOS 16+ also turn on Settings → Privacy & Security → **Developer Mode** (the phone restarts).

A free Apple ID's signature lasts **7 days**, then the app won't open until you re-sign it. Sideloadly can refresh it automatically over Wi-Fi when your PC is on, or just run step 3 again — your downloads and sign-in are kept. (AltStore — altstore.io — works the same way and refreshes in the background from the phone.)

**Paid Apple Developer account ($149 AUD/year)**
Signatures last a year, and you can share it with Hayley's phone through **TestFlight** — no cable, no re-signing. This needs a Mac (or a signing setup on GitHub) to upload to App Store Connect once; ask Claude to add that if you go this way.

### 3. First launch: nothing to type

Your server's address is built into the app, so it just opens. It knows two addresses for the same server and picks by itself: **home** (`192.168.80.35:8420`) on your Wi-Fi, **away** (your Tailscale address) everywhere else. It checks again whenever you come back to the app, and you stay signed in on both.

- To set them before building, edit `MARQUEE_HOME` and `MARQUEE_AWAY` near the top of `project.yml`. Leave away empty and the app learns it from the server (**Marquee → Settings → Server addresses**; the server also remembers it by itself the first time an admin opens Marquee at its Tailscale address).
- To change them on the phone: **Marquee → Settings → Change addresses**.
- Away from home the iPhone needs the **Tailscale** app switched on. iOS doesn't let Marquee do that for you, so let Tailscale do it: in Tailscale tap your picture → **VPN On Demand** and set Wi-Fi to *Except On* your home network and Cellular to *Always*. Then it's on whenever you're out and off at home, with nothing to tap. If Marquee can't reach the server it shows an **Open Tailscale** button, and reconnects by itself when you come back.

When iOS asks:
- **"Find devices on your local network"** → *Allow* (needed to reach your ZimaOS box at home).
- **Notifications** → *Allow* for new-arrival alerts.

## Marquee for Mac (MacBook, iMac, Mac mini)

The same project also builds a Mac app. Marquee gets its own window and Dock icon, with:
- new-arrival notifications while it's open (tap one to jump to that movie);
- the screen staying awake while you watch, and the player's full-screen button and AirPlay working;
- menu shortcuts: Reload ⌘R, Back ⌘[, Home ⇧⌘H, Search ⌘F, Change Server ⌘,;
- "Save file" downloads going straight to your Downloads folder.

It needs macOS 13 (Ventura) or newer and runs on both Apple-chip and Intel Macs. You don't need Xcode or an Apple Developer account.

### 1. Build it (free, on GitHub's Macs)
1. Put this folder in a private GitHub repo (the same one as the iPhone app is fine).
2. Open the repo's **Actions** tab → **Build Mac app** → **Run workflow**. It takes about 5 minutes.
3. Open the finished run and download **Marquee-Mac** at the bottom. Do this on the Mac itself if you can.

### 2. Install it
1. Double-click the downloaded `Marquee-Mac.zip`, then double-click `Marquee.dmg` inside it.
2. Drag **Marquee** onto the **Applications** folder in the window that opens.
3. The first time you open it, macOS blocks it because it isn't from the App Store. To allow it:
   - Open **System Settings → Privacy & Security**, scroll down to "Marquee was blocked…", and click **Open Anyway**. Then confirm with your password or Touch ID.
   - On macOS 13 or 14 you can instead right-click Marquee in Applications and choose **Open**, then **Open** again.
   - Or run this once in **Terminal**: `xattr -dr com.apple.quarantine /Applications/Marquee.app`
4. It opens straight to your server (the address is built in). When macOS asks about **local network** and **notifications**, click Allow.

Like the phone app it uses your **home** address on your Wi-Fi and your **away** (Tailscale) address everywhere else, and re-checks when you come back to it or open the lid. Change either under **Marquee → Server Addresses…** (⌘,). To use it away from home, install **Tailscale** on the Mac (from the Mac App Store), sign in with the same account, and turn on **VPN On Demand** in its settings so it switches itself on when you leave home.

### Prefer no install at all?
On macOS 14 (Sonoma) or newer, open Marquee in **Safari**, then choose **File → Add to Dock**. That gives you a Dock icon and its own window, without the notifications and menu shortcuts.

### If you have Xcode on the Mac
Run `brew install xcodegen && xcodegen generate && open Marquee.xcodeproj`, pick the **MarqueeMac** scheme and press ▶.

## If you have a Mac

```
brew install xcodegen
xcodegen generate
open Marquee.xcodeproj
```
Pick your team under *Signing & Capabilities*, plug in the phone and press ▶.

## Notes

- The app is a window onto your server, so every new feature you add to Marquee shows up here automatically — no need to rebuild the app.
- Background notification checks happen when iOS decides (usually a few times an hour if you use the app often); it always checks when you open the app.
- Offline progress: watching a download without internet still counts — it syncs next time Marquee can reach the server.
- Changing addresses: Marquee → Settings → *Change addresses*. If neither address answers the app offers *Try again*, *Open Tailscale*, *Watch your downloads* and *Change addresses*.
- A few small per-device choices (playback quality, sort order, this device's name) are remembered separately for home and away, because browsers keep them per address. Handy for quality: full quality at home, lighter when you're out.
- Apple TV: the home address is pre-filled on its first screen, so it's just *Connect*.
