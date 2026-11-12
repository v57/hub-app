# Devices and Access

A hub decides who may connect and what each device may call. The pages under **Access** show the hub’s devices,
the requests waiting for you, the open connections, permission groups and Lockdown. You see each page only if the
hub gives your device the permission for it; owners see them all.

## Devices

**Devices** shows each device on the hub: its battery, CPU and memory (computers only), and its Hub Network address.
Filter with **All**, **Phones**, **Computers**, **Other** or **Offline**.

- On iPad and the Mac, switch between a grid and a list, search by name or kind, and select a device to see its
  details beside the list.
- On iPhone, tap a device to open its details.

**Invite** (or **Invite…** on an empty hub) opens the hub’s Hub Network page to add a device. See
[Add a Device](Hub-Network.md#add-a-device).

### A device’s details

- **System**, **Attached to**, **Hub Network**, **Safety code**, **Key** and **Internet**.
- **Resources**: live **CPU**, **Memory**, **Disk** and **Battery**.
- **Services** the device runs.
- **Rename**: choose the pencil, type the new name, then **Rename**. The name changes everywhere on the hub.

### Approve a device

When a device connects without a pairing code, it waits for an owner. The Devices page shows a banner:
**… wants to join …**, with the device’s system, when it asked, and its safety code.

1. On the device that asks, open **Settings** under **This iPhone** (or iPad, Mac). Under the hub, it shows a **Safety
   Code**.
2. On your device, choose **Approve…**. Hub asks **Does … Show …?** with the code.
3. If the codes match, choose **Codes Match, Approve**. If they don’t, choose **Cancel** and deny the device.

On iPad and the Mac, **Deny** turns the request down: the device moves to **Denied** and can’t ask again until you
allow it (an older hub only removes the request, so a device that stays connected asks again). On iPhone, leave the
request or revoke the device later.

If the banner is red and says **no safety code checks, so this may not be your device**, the hub gives no code that
checks against its key. This happens with older hubs. Anyone who reaches the hub can ask to join under any name.
Approve it only if you just asked from your own device and no one else could have: choose **Approve…**, then **Approve
Without a Code**.

A device that a member invited to Hub Network also waits here until an owner approves it. A device an owner invited
joins at once.

### Denied devices

**Denied** lists the devices whose request was turned down: they **can’t ask to join until you allow it**, and the
device’s own page says an owner denied it.

- **Allow to Ask Again**: the device asks again, with a new safety code to compare, and **Approve…** admits it.
- **Revoke…**, then **Revoke**: it can never ask to join this hub again, and it leaves the list.

### Attach a device

A device can ask to attach to yours, for example a service that runs on it. The banner reads **… wants to attach to
this iPhone** (or iPad, Mac), with its safety code. An attached device starts with nothing; you choose what it gets.

- Check the code on that device, then choose **Attach** (on iPad and the Mac, **Attach…**). Hub signs for it with this
  device’s key.
- On iPad and the Mac, **Deny** dismisses the request.
- Without a safety code to check, Hub doesn’t offer Attach.

### Grants and links

An owner can give a device access to API paths directly, and link what attached devices get:

- **Access**: choose **Grant** (+), type a path such as `s3/read` or `s3/*`, then **Grant**. Turn on **Passes down**
  to pass it on to attached devices. **Remove** takes it back.
- **Link to parent**: **Gets linked grants** lets an attached device get what its parent passes down.
- **Attached**: the devices attached below this one, each with a **Linked** switch.
- **Detach from Parent**, then **Detach**: what the device got through the link goes. It stays approved with what you
  gave it directly.

### Revoke a device

For a lost or compromised device: open it, choose **Revoke …**, then **Revoke**. Its connections close, its service
keys are revoked, its grants and Hub Network peers are removed, and it can never be approved again. Devices
attached below it are revoked too. You can’t revoke the device you’re using.

## Requests

When a service asks to post APIs on the hub, it waits on **Requests**. Each request shows the service’s key and the
APIs it wants to post. Choose **Allow** to let it post exactly those APIs. Devices waiting to join are listed here too.

With nothing waiting, the page says **Nothing Waiting**. A waiting request also shows as a count on the hub’s card.

## Connections

**Connections** lists everything connected to the hub: a device or service by name, or **Unauthorized** for a
connection without a key, with its group. On iPad and the Mac, switch between a grid and a list and search by name
or key. **Lockdown** in the bar opens the Lockdown page.

Select a connection to see:

- **Key**, with **Copy Key**.
- **Group**: tap a group to put the connection in it, or **No group**. **Remove from …** takes it out.
- **Lockdown**: **Can connect in Lockdown**. This app and the hub’s owners are always trusted, as on the Lockdown page:
  their connections say **Always trusted**.

A device’s own connection carries the name **Devices** gives it, for example **iPhone-2** when the hub made a second
**iPhone** unique.

A connection without a key can only call the APIs anyone may call.

## Permission groups

**Permissions** is a table of permissions (rows) and groups (columns). A group gives its connections the permissions
you tick. Owners always have every permission.

1. Tick or untick boxes. A section’s box shows when only some of its permissions are on. A permission’s row lists the
   APIs it stands for, and ticking it gives all of them; for example **Manage Proxy Hubs** is `hub/proxy/add` and
   `hub/proxy/remove`. Search finds a permission by its name or by an API’s path.
2. Edited groups say **edited**, and the page counts unsaved changes.
3. Open the group (select its header; on iPhone, tap it) and choose **Save**, or **Revert** to drop the changes.

Members get the new permissions when you save. To add a group, choose **New Group**, type a name, then **Create**.
To delete one, open it, choose **Delete …**, then **Delete**; its members lose its permissions.

Put a connection in a group on [Connections](#connections).

## Lockdown

With Lockdown off, any device with a key can connect and ask for APIs. With Lockdown on, only trusted devices connect,
and the rest are refused until you trust them.

- Turn **Lockdown** on or off at the top.
- **Trusted** lists the devices that connect during Lockdown; **Not trusted** lists the rest. Use each device’s
  **Trusted** switch.
- When turning Lockdown on would refuse connections, a banner says so with **Trust** or **Trust All**.
- This device and the hub’s owners are always trusted: their rows say **You · always trusted** and **Owner · always
  trusted**.

## What owners control

Services installed on a hub allow only its owners by default. Give a group the permissions for a service, or grant
them to a device, before another device can use it.
