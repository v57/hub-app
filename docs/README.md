# Hub user guide

Hub connects your devices into one hub that you run yourself. A hub is a small server on a Mac, a home server, a VPS,
or on the device you hold: the Hub app can run one. With the app you manage your hubs (their services, devices,
permissions, launcher and files), join Hub Network to reach your devices from anywhere, share a device's work or
internet, and turn an old iPhone, iPad or Mac into a security camera.

## Platforms

- **Mac** (macOS 14 or later): every feature, plus the Mac-only parts of Hub Network: **Use This Mac’s Internet
  Anywhere…** and **Keep this Mac awake while sharing**.
- **iPhone and iPad** (iOS 17 or later): every feature, plus **Browse Through My Own Internet** and the camera
  screen. A hub that an iPhone or iPad runs pauses when Hub leaves the screen.
- **Linux** (an early build): the app runs on a Linux desktop. Hub Network works through the hub-net service there.
  Using another device’s internet, the security camera, the iCloud switch and the Apple Intelligence services aren’t
  available on Linux.

Hub doesn’t run on Windows or Android yet.

## Pages

- [Getting Started](Getting-Started.md): connect to your first hub, pair with a new one, or run one on this device.
- [Hubs](Hubs.md): the sidebar, All Hubs, a hub’s menu and what its states mean.
- [Services and Apps](Services-and-Apps.md): the Overview, Services and Apps pages, and the load balancer.
- [Files](Files.md): connect storage to a hub, then browse, upload and delete files.
- [Launcher](Launcher.md): start, stop, configure and update the apps a hub runs, and get more from the store.
- [Devices and Access](Devices-and-Access.md): approve devices, grant access, permission groups and Lockdown.
- [Hub Network](Hub-Network.md): a private network between your devices, invitations, sharing apps and internet.
- [Security Camera](Security-Camera.md): use a device as a camera, watch it live, motion clips and alerts.
- [This Device](This-Device.md): Run a Hub, Shared Services, Farm and Settings.
- [Privacy and Security](Privacy-and-Security.md): what Hub sends over the network, keys, approval codes and Reset Data.

Hub has no menu commands of its own. In a sheet, Return confirms and Escape cancels. On a camera’s page, ⌘[ goes back
to Cameras.

## Works with other v57 apps

- [Vault](https://github.com/v57/Vault/blob/main/docs/README.md): your hubs are records in the shared vault and sync
  through your iCloud. This device’s Hub key is the same key the other v57 apps use.
- [Shell](https://github.com/v57/Shell/blob/main/Docs/README.md),
  [Database](https://github.com/v57/Database/blob/main/docs/README.md),
  [Code](https://github.com/v57/Code/blob/main/docs/README.md) and
  [Git](https://github.com/v57/Git/blob/main/docs/README.md): the devices on your hubs show up as hosts, so these apps
  reach them over SSH, also through Hub Network.
- [Get](https://github.com/v57/Get/blob/main/docs/README.md): **Download on…** starts a download on one of your hub’s
  devices.
- [Player](https://github.com/v57/Player/blob/main/docs/README.md): **Open from Device** plays a video from one of
  your hub’s devices.

## Network

Hub contacts nothing until you connect to a hub, run one, or turn on Hub Network. The store’s list of services loads
from GitHub only after you choose **Allow**. See [Privacy and Security](Privacy-and-Security.md) for every connection
the app makes.

For developers: [Apple packet tunnel](apple-packet-tunnel.md).
