# Hubs

Every hub you add appears in the sidebar and on **All Hubs**. This page covers finding your hubs, a hub’s menu, and
what Hub shows when a hub can’t be used.

## The sidebar

- The **Hubs** card lists **All Hubs** and each hub, with a status dot or a count of requests waiting for you. Its
  line says how many hubs are online.
- **Search Hubs** filters the hubs by name. Offline hubs that are hidden show while you search.
- **Sort Hubs** (⇅) orders them by **Recent** or **Name**, and **Show Offline Hubs** / **Hide Offline Hubs** shows or
  hides the ones you can’t reach. A **Show N More** row reveals hidden hubs. Hub keeps the order after a relaunch.
- The page rows show counts: services, apps, launcher updates, devices and those waiting, requests, connections,
  groups, Lockdown **On** or **Off**, and cameras.
- **Copy My Key** copies this device’s key for the open hub (on **All Hubs**, the shared key). The button reads
  **Copied** for a moment.
- **Connect to a Hub** adds another hub.

On iPad, once a hub is open the Hubs card makes room for that hub’s pages. Use **Switch Hub** in the hub’s header to
go to **All Hubs**, another hub, or **Show N More** for the rest.

On iPhone, tap a hub to see its pages as cards: the hub’s own pages, **Access**, and **Hub Network**.

## All Hubs

**All Hubs** shows a card per hub. An unreachable hub shrinks to its header. A reachable hub’s card shows:

- up to three launcher apps with their CPU and memory, and a ▶ or ⏸ button to start or stop each one (hub-server
  itself has no button);
- the widgets its services publish (tap one to open its app);
- tiles for the pages you use most and for its apps, with **+N More** for the rest;
- a **N requests** chip when a device or a service is waiting. Tap it to open **Devices** or **Requests**.

On iPad and the Mac, the bar has a search field for hubs, apps and devices. **Connect** adds a hub.

## A hub’s menu

Touch and hold a hub in the sidebar or on **All Hubs**, or use its **…** button. The menu has:

- **Open**
- **Copy Address**
- **Trust New Hub Key**, only when the hub was refused because its key changed (see below)
- **Remove…**

## Remove a hub

Choose **Remove…** in the hub’s menu, then **Remove**. Hub forgets the hub and its address on this device. The hub
keeps your key until an owner removes it. Your other devices keep the hub.

## When a hub can’t be used

A hub’s pages tell you why it isn’t available:

- **Connecting to …** shows the address while Hub connects, with **Remove…**. These pages keep their title bar, so
  **Back** on iPhone stays.
- **… Isn’t Reachable**: Hub keeps trying the address, and the pages show what they last loaded. Use **Copy Address**
  to check it, or **Remove…**.
- **… Needs an Update**: the hub runs an old version that can’t prove who it is, so this device sends it nothing.
  **Copy Update Command** copies `hub update`. Run it on the hub’s machine. For Docker, pull `v57dev/hub` again and
  recreate the container.
- **… Refused This iPhone** (or iPad, Mac): the hub said no. The reason is shown, for example:
  - the hub’s key changed since this device first connected, or another server answers at this address;
  - this device’s key was revoked, or the device’s clock is wrong;
  - the hub only accepts devices it already knows;
  - the address isn’t encrypted and isn’t on this network. Use a `wss://` address.

### Trust a new hub key

If you reinstalled hub-server, the hub has a new key and Hub refuses it. If you know why the key changed, choose
**Trust New Hub Key** on the hub’s page or in its menu. Hub accepts the key the hub shows now. If the hub used the
keys this device shares with older hubs, it now sees this device as a new device, and an owner approves it again.

Don’t trust a new key you didn’t expect. Another server may be answering at that address.

## Not encrypted

A hub on your local network can use a plain `ws://` address. Its line under the hub’s name then says **Not
encrypted**. Hub refuses a plain address anywhere else. Through Hub Network the connection is encrypted underneath.
