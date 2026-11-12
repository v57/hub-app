# Privacy and Security

Hub talks only to hubs you choose and to your own devices. It contacts nothing at launch, and nothing until you
connect to a hub, run one, or turn on Hub Network.

## What Hub sends over the network

- **Hubs you add.** Hub connects to the address you typed, signs in with this device’s key, and stays connected while
  the hub is in your list (it keeps trying when the hub is away). It tells each hub this device’s name, model, system,
  CPU, memory, storage, battery and network type, which show on the hub’s **Devices** page. It sends the hub the
  calls you make: pages, files you upload, settings you change.
- **A hub this device runs.** With **Run a Hub** on, this device accepts connections from your other devices on the
  local network, on its port (1997 by default).
- **Hub Network.** While it’s on, this device talks to the hub and to the connection helper, which introduces your
  devices to each other. The default helper is `v57.dev:1964`, run by v57; an owner can set another. The helper sees
  which devices are online, not what they send: devices then connect directly, encrypted.
- **Another device’s internet.** When you choose **Use** for another device, all of this device’s traffic goes out
  through that device of yours. Sites see that device’s address.
- **Storage.** With **Share Storage** on, this device keeps the hub’s files in a folder of Hub’s own and answers only
  over Hub Network, for requests the hub signed. See [Storage](This-Device.md#storage).
- **Shared Services.** When you turn on **Share with …**, the hub sends this device the work its callers ask for
  (images, videos, text), and this device sends back the results. The work is done on this device.
- **The store’s list.** **Get More** loads the list of apps from GitHub (`raw.githubusercontent.com`), only after you
  choose **Allow**. Hub remembers your answer. **Change Store** loads a list from the address you type. Installing an
  app is done by the hub’s machine, not this device.
- **Apps and links from your hubs.** Web apps that a hub’s services publish load from those services. **Open** on a
  shared app opens it at the other device’s Hub Network address.
- **Cameras.** Live view, clips and motion alerts go between your devices over Hub Network. Clips go to the hub’s
  storage only if you choose it under **Keep Clips On**. There is no push service.
- **Translation.** The first time you use a language, the system downloads it.
- **iCloud.** With **Use iCloud** on, your hubs are saved in the v57 vault and sync through your own iCloud account,
  like the other v57 apps’ data.

Hub sends nothing else. It has no analytics.

## Encrypted connections

- A `wss://` address is encrypted.
- A plain `ws://` address is allowed only on your local network, and the hub’s line then says **Not encrypted**. A hub
  this device runs is reached that way on your network. Hub refuses a plain address anywhere else.
- Through Hub Network, every connection is encrypted underneath.

## Keys

- **Device key.** Each device has one key. The Hub app shares it with the other v57 apps on this device, so they are one
  device on a hub. It’s kept in the system keychain. Hub keeps no passwords.
- **Your Key** for each hub, and **Shared Keys** for older hubs and the hub this device runs. **Settings** under this
  device shows them. **Copy My Key** copies the open hub’s key.
- **On Linux**, the device key is a file in your home folder, and Hub’s other keys are in the system’s secret store.
  Other programs you run can read them, as with other password stores there.

## Knowing it’s your hub

Hub remembers each hub’s key the first time it connects. If the key changes, Hub refuses the hub and tells you. Choose
**Trust New Hub Key** only if you know why it changed, for example after you reinstalled hub-server.

A hub too old to prove its key shows **Needs an Update**, and this device sends it nothing. Update it with `hub update`
on its machine.

## Who becomes an owner

- The first device to enter a new hub’s pairing code becomes its owner. A code works once and for about an hour. Share
  it only with your own devices.
- Any other device waits until an owner approves it. Compare the **Safety Code** the device shows with the one in the
  approval question before you choose **Codes Match, Approve**.
- When a hub gives no safety code to check, the request is red. Anyone who reaches the hub can ask to join under any
  name. Choose **Approve Without a Code** only if you just asked from your own device.
- A device a member invites to Hub Network waits for an owner’s approval too, also when the invitation comes from the
  hub’s machine. A device an owner invites joins at once.
- **Deny** keeps a device out: it can’t ask again until an owner allows it under **Devices**.

## What other devices may do

- Each device and service gets only what the hub’s permission groups and grants allow. See
  [Devices and Access](Devices-and-Access.md).
- Services installed on a hub allow only its owners until you grant more.
- Installing, uninstalling, updating and configuring launcher apps is for owners.
- **Lockdown** refuses every device you haven’t trusted.
- If a device is lost, **Revoke** it. It can never be approved again.

## Hub Network safety

- **Open Ports** under **Settings** lists the ports a hub may open on this device, besides the apps you share. SSH on
  the Mac stays off until you turn it on.
- Today that list limits the devices linked directly to this one. The hub’s own machine, and the network’s members on
  the Mac that runs the hub, aren’t limited by it yet. Join only the networks of hubs you own or trust.
- When you use another device’s internet, choose **Use My Own** under **If … stops answering** if you’d rather fall
  back to this device’s internet than wait.

## Cameras

- Only the hub’s devices on Hub Network that know a camera’s password can watch it. Change the password under
  **Access** in the camera’s settings; devices that watch it sign in again.
- **Delete Clip** deletes a clip for everyone who watches the camera.
- On the Mac, **When I’m Away** checks only whether the Mac is in use. Nothing about that leaves the Mac.

## Permissions the system asks for

- **Local Network** (iPhone and iPad): to reach hubs on your network and to let your devices reach a hub this device
  runs.
- **Camera**: to scan a pairing code or invitation, and for the security camera.
- **VPN**: for Hub Network. Hub routes only Hub Network’s traffic through it, unless you use another device’s internet.
- **Notifications**: for a camera’s motion alerts.

## Start over

**Settings ▸ Reset Data** removes your hubs, settings and caches, Hub Network membership and its VPN profile, and the
hub this device runs with its data. Your keys stay, so hubs that know this device still recognize it. To stop syncing
through iCloud, turn off **Use iCloud** in the same place.
