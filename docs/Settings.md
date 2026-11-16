# Settings

Hub keeps its settings on the device. Most of them sit next to what they change; the **Settings** page under this
device holds the ones that apply to the whole app.

## The Settings page

Open the sidebar’s **This iPhone** card (or iPad, Mac), then **Settings**. It holds:

- **Use iCloud** (iPhone, iPad and the Mac): on or off for every v57 app on this device. It’s on at first. Turning it
  off asks **Turn Off iCloud?**: every v57 app on this device stops syncing through iCloud and iCloud Keychain.
  What’s already there stays, and your other devices keep it.
- A card for each hub with **Your Key**, **Device Key** and **Safety Code**. While an owner hasn’t approved this
  device yet, the card says so: an owner compares this code and approves this device.
- **Open Ports** (below).
- **Shared Keys**: **Your Key** and **Device Key** for older hubs and the hub this device runs.
- **Reset Data** (below).

### Open Ports

Over Hub Network, a hub can only open a port on this device that you share from it or list here, whatever the hub
signs.

- Type a port such as `tcp/8080` (or `udp/…`) and choose **Allow**. Remove one with ✕.
- On the Mac, **SSH (port 22)** lets your devices reach this Mac’s Remote Login over Hub Network. It’s off until you
  turn it on.

### Reset Data

**Reset Data** removes your hubs, settings and caches, Hub Network membership and its VPN profile, and the hub this
device runs with its data. Hub starts over at the welcome. Your keys stay, so hubs that know this device still know
it. This can’t be undone.

## Settings in other places

| Setting | Where | At first |
|---|---|---|
| **Sort Hubs** (**Recent** or **Name**) | The sidebar’s **Hubs** card. See [Hubs](Hubs.md) | Recent |
| Run a hub on this device, and its **Port** | **Run a Hub**. See [This Device](This-Device.md#run-a-hub) | Off, port 1997 |
| Share a service with a hub | **Shared Services**. See [This Device](This-Device.md#shared-services) | Off |
| Share this device’s storage, its hub and size limit | **Storage**. See [This Device](This-Device.md#storage) | Off |
| **If … stops answering**: **Use My Own** or **Wait** | A device on the Hub Network page. See [Hub Network](Hub-Network.md#use-another-devices-internet) | Wait |
| **Keep this Mac awake while sharing** (Mac) | The Hub Network page, under **Internet**. See [Hub Network](Hub-Network.md#keep-this-mac-awake-while-sharing) | Off |
| A camera’s picture, recording, clips and access | The camera’s settings. See [Security Camera](Security-Camera.md#camera-settings) | 720p, 24 fps, H.264 |
| Loading the store’s list of apps | **Get More** on a launcher. See [Launcher](Launcher.md#get-more-apps) | Not allowed until you choose **Allow** |

Farm’s settings (minimum battery, brightness, overlay) start over each time you open Hub. A hub’s own settings, such
as its load balancers and permissions, live on the hub, not in the app: see [Services and Apps](Services-and-Apps.md)
and [Devices and Access](Devices-and-Access.md).
