# Getting Started

Hub needs a hub to talk to. You can connect to one you already run, pair with a new one, or let the app itself be the
hub.

## The welcome

Until you add a hub, Hub opens on **No Hub Yet**. It offers:

- **Connect to a Hub…**: its address and pairing code, or an invitation.
- **Run a Hub on This iPhone** (or iPad, or Mac): this app is the hub, and your other devices pair with it.
- On iPhone and iPad, **Browse Through My Own Internet**: use your home Mac’s internet when you’re away. See
  [Hub Network](Hub-Network.md#browse-through-your-own-internet).
- On the Mac, **Use This Mac’s Internet Anywhere…**: set this Mac up so your phone can browse through it. See
  [Hub Network](Hub-Network.md#use-this-macs-internet-anywhere-mac).

Nothing is contacted until you connect. Once you have hubs, the welcome lists them under **Your Hubs**.

## Get a hub

A hub is a server your devices connect to. You have three choices:

- **Run one in this app.** Choose **Run a Hub on This Mac** (or iPhone, iPad). See [This Device](This-Device.md#run-a-hub).
- **Install hub-server on a computer** you own. On that computer, run `bunx v57/hub` in a terminal. It installs the
  `hub` command and the launcher, which installs and runs hub-server. Then run `hub pair` to get a pairing code and a
  `hub://pair` link. Docker works too: the image is `v57dev/hub`, on port 1997.
- **Connect to a hub someone else runs.** You need its address. An owner approves your device.

## Pair with a new hub

A new hub has no owner yet. The first device that enters its pairing code becomes its owner.

1. On the hub’s machine, get the pairing code: `hub pair`, or **Show Pairing Code** under **Run a Hub** in the Hub
   app there. A code works once, for about an hour.
2. In Hub, choose **Connect to a Hub** (in the sidebar’s bottom bar, or **Connect** on **All Hubs**).
3. Type the hub’s address in **Address**, for example `my-server.local` or `192.0.2.10:1997`.
4. Type the code in **Pairing code**. The button changes from **Connect** to **Pair**.
5. Choose **Pair**. When pairing finishes, this device is an owner and the hub opens.

A wrong or malformed code shows an error under the sheet, and the hub isn’t added.

Faster ways to pair:

- **Open the link.** Open the `hub://pair` link on this device, for example from a QR code in the Camera app or a link
  in a note. Hub asks **Pair with this hub?** with the address and code. Choose **Pair**, or **Cancel** to add nothing.
- **Paste the link.** Paste a `hub://pair` link into **Address**. Hub splits it into the address and the code.
- **Scan the code.** On iPhone and iPad, choose **Scan** in the Connect sheet and point the camera at the other
  device’s QR code. A pairing code fills the address and code. An invitation opens the Join flow. Anything else shows
  **Not a pairing code or an invitation**.

## Connect to a hub you already use

1. Choose **Connect to a Hub**.
2. Type the hub’s address and leave **Pairing code** empty.
3. Choose **Connect**.

If the hub doesn’t know this device yet, it waits for an owner to approve it. Open **Settings** under **This iPhone**
(or iPad, Mac) to see this device’s **Safety Code** for that hub, and read it out to the owner. See
[Devices and Access](Devices-and-Access.md#approve-a-device).

## Join with an invitation

An invitation puts this device on a hub’s private network, Hub Network. Paste the `hub://join/…` link or code into
**Address**. The field turns into **Invitation**, and the button reads **Join**. Invitations work once, for seven
days. A `hub://browse/…` link from a Mac’s **Use This Mac’s Internet** joins and switches to that Mac’s internet. See
[Hub Network](Hub-Network.md#join-with-an-invitation).

## Permissions the system asks for

- **Local Network** (iPhone and iPad): the first time you connect to a hub on your network or run one, iOS asks.
  Choose **Allow**, or Hub can’t reach hubs on your network.
- **Camera**: the first time you scan a code or use this device as a security camera.
- **VPN**: the first time you turn on Hub Network. See [Hub Network](Hub-Network.md).
- **Notifications**: the first time you turn on a camera’s **Motion Alerts**.

## Find your way around

- **On the Mac and iPad**, the sidebar lists your hubs, the open hub’s pages, its Hub Network card, and a card for
  this device. On iPad, an open hub’s header has **Switch Hub** to move between hubs.
- **On iPhone**, the main screen lists your hubs. Tap one to see its pages, and tap a page to open it. The **…**
  button in a hub’s bar opens its menu.

The pages are covered in [Hubs](Hubs.md) and the pages that follow it.

## Keyboard

Hub has no menu commands of its own. In a sheet, Return confirms and Escape cancels; this works on iPad with a
keyboard too. On a camera’s page, ⌘[ goes back to Cameras.
