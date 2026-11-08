# Hub Network

Hub Network is a private network between a hub’s devices. Once a device is on it, you reach your other devices from
anywhere, at home or away, and they reach it. Devices find each other through a connection helper, then connect
directly; your traffic doesn’t pass through the helper or anyone else.

On iPhone, iPad and the Mac, Hub adds a VPN configuration for Hub Network. The rest of your internet works as before,
unless you choose to use another device’s internet.

A device is on one hub’s network at a time.

## Turn Hub Network on and off

The **Hub Network** card in the sidebar has a switch. On iPhone it’s under your hubs; on iPad it stays at the bottom
of the sidebar. The card’s title and its **Devices & Apps** row open the hub’s **Hub Network** page.

- Turn the switch on. The first time, your device asks to add a VPN configuration. Choose **Allow**. On iPhone and
  iPad it’s listed in the system’s VPN settings as Hub.
- Turn it off to leave. The VPN disconnects, and your other devices see this one as **Asleep**.

The card’s status reads **Off**, **Connecting…**, **On · N devices**, or **On · internet via …** when you use another
device’s internet. **Waiting for …** means the hub’s network isn’t running: when the Hub app on a Mac runs the hub, it’s
on whenever Hub is open there, so open Hub on that Mac or wake it. Otherwise ask the hub’s owner to set up Hub Network
on it.

Hub Network comes back on its own after this device or the hub’s machine restarts.

On iPhone, the network page’s bar has the same switch. On iPad and the Mac, the bar has **Add a Device** instead, and
the page has **Turn On** and **Turn Off** buttons.

## Your devices

The network page’s **Devices** section shows each device on the network as a tile: **Online**, **Asleep**, or
**Can’t reach right now** with a **Why?** link. A device that shares its internet says **Shares its internet** (on
iPhone, **Internet**).

With many devices, the page shows the ones you used last under **Recent**, and the rest in a list you can search and
filter: **All**, **Online**, **Shares internet**, **Can’t reach** and **Asleep**.

Tap or click a device to see what you can do with it:

- **Use …’s internet**: browse as if you were where that device is. See [Use another device’s
  internet](#use-another-devices-internet).
- **If … stops answering**: **Use My Own** (this device’s internet until it’s back) or **Wait** (nothing goes out
  until it answers).
- **Apps on …**: the apps that device shares, each with **Open**.
- **Copy Address**: the device’s Hub Network address, for apps and terminals.

### When a device can’t be reached

Choose **Why?** to see what Hub knows: the device may be asleep, offline, or Hub Network may be off here. Choose
**Try Again**. If the device sits behind a router that blocks direct connections, **Connect Manually…** lets you type
the address and UDP port it answers on, from its own Hub Network page or its router.

## Add a device

1. On the network page, choose **Add a Device**. Hub shows a QR code and three steps.
2. On the other device (a Mac, iPhone or iPad with Hub installed), choose **Connect to a Hub**. On iPhone and iPad,
   choose **Scan** and point it at the code. On a Mac, paste the link (see below) into **Address**.
3. An owner approves the new device. It waits under **Devices** with a code; approve it once that code matches the one
   the device shows. See [Approve a device](Devices-and-Access.md#approve-a-device).

Can’t scan? Choose **Send a link instead** or **Copy Link**, and open the link on the other device.

The invitation works once, within seven days. Members of a hub can invite too, but an owner still approves each new
device. When the device joins, the sheet says so, with **Add Another** and **Done**.

On the Mac, **Add a Device** also has **Use This Mac’s Internet**: the phone that scans the code joins and browses
through this Mac right away. If this Mac doesn’t share its internet yet, choose **Share It**.

## Join with an invitation

When you open an invitation, scan its code, or paste it into **Connect to a Hub**:

1. Hub asks **Join …’s Network?** and says who invited you, which helper it finds the hub through, and until when the
   invitation works. Choose **Join**.
2. **One More Step**: your device asks to add a VPN. Choose **Continue**, then **Allow** when the system asks.
3. Hub checks the invitation, sets up a secure connection and connects. **Joined …** shows **Show Devices**.

If joining fails, Hub says why:

- **This invitation was already used** or **This invitation expired**: ask someone in the hub for a new one.
- **Couldn’t reach …**: the Mac that runs the hub may be asleep or offline. Try again once it’s on.
- **You didn’t allow the VPN**: choose **Try Again** and **Allow**.
- **This iPhone is on another hub’s network**: turn that one off first.
- **… doesn’t accept this iPhone**: an owner removed it. If that’s a mistake, check this device’s date and time.

## Use another device’s internet

A Mac (or another device whose hub offers it) can share its internet with your devices. Then your phone browses as if
it were at home: sites see your home’s address, and a café’s Wi-Fi sees only an encrypted connection.

To use it:

- On the sidebar’s **Hub Network** card, under **Use internet through**, choose **Use** next to the device. **Stop**
  goes back to this device’s own internet.
- Or on the network page, under **Internet**, choose **Choose…** next to **Use another device’s internet**. The
  **Use Internet Through** sheet lists this device’s own internet and every device that shares its internet.

**If … stops answering** decides what happens when that device goes away: **Use My Own** or **Wait**.

While you use another device’s internet, your device keeps the VPN on through restarts.

### Share this device’s internet

On the network page, under **Internet**, turn on **Let your devices use this Mac’s internet** (or this iPhone’s,
where the hub offers it). On the Mac, **Keep this Mac awake while sharing** keeps it answering while you’re away; it
can sleep with the lid closed only on power.

### Browse through your own internet

On iPhone and iPad, the welcome’s **Browse Through My Own Internet** sets this up in one go:

1. Read the explainer, then choose **Scan Its Code**.
2. On your Mac, open **Add a Device** in **Use This Mac’s Internet** mode, and scan its code.
3. Choose **Join and Use**, then allow the VPN.
4. **Using …’s Internet** shows **Stop** and **Done**.

### Use This Mac’s Internet Anywhere (Mac)

On the Mac, the welcome’s **Use This Mac’s Internet Anywhere…** walks through four steps, about a minute in all:

1. Start a private hub on this Mac.
2. Share this Mac’s internet (choose **Allow** when your Mac asks to add a VPN).
3. Keep this Mac awake while sharing.
4. Add your phone: scan a code with it, and it starts browsing through this Mac.

## Share an app

Share an app that runs on this device, and your devices open it from anywhere.

1. On the network page, under **Apps you share**, choose **Share an App…**.
2. Pick an app Hub found running on this device, or **Another port…** for one that isn’t listed.
3. Check its **Name**, **Port** and **Kind** (**TCP** or **UDP**).
4. Under **Who can use it**, choose **Change** to pick who may use it.
5. Choose **Share**.

On another device, open this device on the network page and choose **Open** next to the app.

Each shared app has a menu (**…**, **Who Can Use …**):

- **Everyone in …**, a group, or **Only Me**.
- **Choose People…**: pick people one by one, then **Save**.
- **Disconnect Everyone Now**: devices that are still allowed can connect again.
- **Stop Sharing**: takes the app off the network.

## Advanced

Expand **Advanced** on the network page for:

- **Connection helper**: the server that helps your devices find each other. It never sees what they send. The default
  is `v57.dev:1964`, run by v57. An owner can choose **Change…** to set another one in the **Coordinator** sheet, or
  **Use v57.dev** to go back to the default. Invitations include the helper’s address.
- This device’s Hub Network addresses (IPv4 and IPv6), its name, and the hub’s address.

## Open ports on this device

A hub can only open a port on this device that you share from it or list here. See [Open
Ports](This-Device.md#open-ports).

## On Linux

On Linux, Hub Network runs through the hub-net service. Turning the network on for a hub asks the hub’s machine for
an invitation, and turning it off pauses the membership. The **Advanced** section shows the service’s state. Using
another device’s internet isn’t available on Linux yet; a Linux computer can share its own.

## Cameras need Hub Network

A hub’s security cameras are reached over Hub Network. See [Security Camera](Security-Camera.md).
