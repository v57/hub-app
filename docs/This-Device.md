# This Device

The sidebar’s **This iPhone** card (or iPad, Mac; on Linux, this computer) holds what this device does without a hub:
**Run a Hub**, **Shared Services**, **Farm** and **Settings**.

## Run a Hub

The Hub app can be the hub. Your other devices connect to this one, and this device is the hub’s owner. Services,
devices and permissions work as on any hub.

1. Open **Run a Hub** and turn on **Run a Hub on this device**.
2. Hub shows that the hub is running, its addresses (each with **Copy**), the address on this device itself
   (`127.0.0.1` and the port), and the start of the hub’s key. The hub appears in your hubs list.
3. To change the port, turn the hub off first and type the new **Port**. Other devices dial this device’s address with
   this port. The default is 1997.

If this device has no Wi-Fi or Ethernet, Hub says so: other devices can’t reach the hub until it’s on a network.

### Pair another device

A pairing code makes another device an owner of this hub, for example your iPad or Mac.

1. Choose **Show Pairing Code**. Hub shows the code, until when it’s valid (once), and a QR code.
2. On the other device, open **Connect to a Hub** and enter this device’s address and the code, or scan the QR code.
   You can also use **Copy Link** or **Share** to send the `hub://pair` link.
3. When it’s done, Hub says **Paired. The other device is an owner now.**

**New Code** makes another code, and **Hide** hides it.

### More on this page

- **Hub Network**: devices you invite join a private network hosted by this hub. **Open Hub Network** opens its page.
  Hub Network needs the hub on port 1997; on another port Hub warns you.
- **Connected**: the devices and services connected to this hub, by device or name.

### How long it runs

- On iPhone and iPad, iOS pauses the hub shortly after Hub leaves the screen, and it starts again when you come back.
  To keep serving, leave Hub open: **Open Farm** keeps the screen awake.
- On the Mac, the hub runs while Hub is open. Farm keeps the Mac from sleeping.

Turn **Run a Hub on this device** off to stop the hub. It leaves your hubs list.

## Shared Services

This device can work for your hubs: compress images and videos, check images for sensitive content, translate text
and chat with an on-device model. **Shared Services** shows a card per service:

- **Image encoder**: compresses images by converting them to HEIC.
- **Video encoder**: compresses videos by converting them to HEVC.
- **Detect sensitive content**: checks whether an image or video contains sensitive content, to help with moderation.
- **Apple Intelligence Translate**: translates text on this device. Needs iOS 18 or macOS 15 or later.
- **Apple Intelligence Chat**: chats with Apple Intelligence’s on-device model. Needs iOS 26 or macOS 26 or later, on
  a device with Apple Intelligence.

Each card has a **Share with …** switch for every hub you’re connected to. Turn it on, and the hub lists the service’s
APIs with this device as a provider. Turn it off to stop. With no hubs, the card says **Connect to a hub to share
it.**

All of these run on this device; none needs the internet.

### Try a service

Choose **Try It** on a card. On iPhone it opens as a page; on iPad and the Mac, as a sheet with **Done**.

- **Image encoder**: pick a format under **Convert to**, choose **including metadata** or **removing metadata**, and
  set the quality. Pick photos (or drop images), and see each result’s size. **Export** shares the results.
- **Video encoder**: set the quality, pick videos, and **Export** the results.
- **Detect sensitive content**: pick images, or drop files on iPad and the Mac. Each one is marked.
- **Translate**: pick the two languages, type in **Text to translate**. **Switch** swaps them, **Refresh** checks the
  languages again. A language downloads the first time you use it.
- **Chat**: type a message and choose **Send**. There’s no chat history.

On a system that’s too old for a service, its page says **Service not available**.

## Farm

Farm keeps this device awake so it keeps serving your hubs.

- Set the minimum battery level with the slider. Farm runs while charging or while the battery is above that level.
  At 0 it runs until you turn it off. Below the level, Hub asks you to charge the device or change the level.
- **Lower brightness**: lowers the screen to its minimum until Farm stops.
- **Black overlay**: a black screen, which saves battery on OLED and XDR displays.
- **Show Activity**: shows requests as they happen.

Choose **Start Farming**. Tap or click the black screen to stop.

On a computer without a battery, the battery level doesn’t show.

## Settings

**Settings** under this device holds:

- **Use iCloud** (iPhone, iPad and the Mac): on or off for every v57 app on this device. Turning it off asks **Turn Off
  iCloud?**: every v57 app on this device stops syncing through iCloud and iCloud Keychain. What’s already there stays,
  and your other devices keep it.
- A card for each hub with **Your Key**, **Device Key** and **Safety Code**. While an owner hasn’t approved this
  device yet, the card says so: an owner compares this code and approves this device.
- **Open Ports** (see below).
- **Shared Keys**: **Your Key** and **Device Key** for older hubs and the hub this device runs.
- **Reset Data** (see below).

### Open Ports

Over Hub Network, a hub can only open a port on this device that you share from it or list here, whatever the hub
signs.

- Type a port such as `tcp/8080` and choose **Allow**. Remove one with ✕.
- On the Mac, **SSH (port 22)** lets your devices reach this Mac’s Remote Login over Hub Network. It’s off until you
  turn it on.

### Reset Data

**Reset Data** removes your hubs, settings and caches, Hub Network membership and its VPN profile, and the hub this
device runs with its data. Hub starts over at the welcome. Your keys stay, so hubs that know this device still know
it. This can’t be undone.
