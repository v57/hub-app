# Hub Network

Hub Network is a private network between a hub’s devices. Once a device is on it, you reach your other devices from
anywhere, at home or away, and they reach it. Devices find each other through a connection helper, then connect
directly; your traffic doesn’t pass through the helper or anyone else.

On iPhone, iPad and the Mac, Hub adds a VPN configuration for Hub Network. The rest of your internet works as before,
unless you choose to use another device’s internet.

A device is on one hub’s network at a time.

## Turn Hub Network on and off

The **Hub Network** card in the sidebar has a switch. On iPhone it’s under your hubs; on iPad and the Mac it stays at
the bottom of the sidebar. The card’s title opens the hub’s **Hub Network** page, as does **Devices & Apps** in a
hub’s **Hub Network** section.

- Turn the switch on. The first time, your device asks to add a VPN configuration. Choose **Allow**. It’s listed in
  the system’s VPN settings as Hub Network.
- Turn it off when you don’t need it. The VPN disconnects, and your other devices see this one as **Asleep**. The apps
  and internet this device shared come back when you turn it on again.

The card’s status reads **Off**, **Connecting…**, **On · N devices**, **On · internet via …** when you use another
device’s internet, or **Reconnecting…** (see below). **Waiting for …** means the hub’s network isn’t running: when the
Hub app runs the hub, it’s on while Hub is open on that device, so open Hub there, or wake that Mac. An iPhone or iPad
pauses its hub soon after Hub leaves the screen. Otherwise ask the hub’s owner to set up Hub Network on it.

Hub Network comes back on its own after this device or the hub’s machine restarts. If its VPN stops without you turning
it off, for example after an update, Hub starts it again. While Hub restarts it, or when the network stops carrying
anything to the hub, the card reads **Reconnecting…**. If it keeps stopping, the card says why and goes **Off**; turn it
on again to try again.

On iPhone, the network page’s bar has the same switch, and the top card has **Turn On**, or **Add a Device** once
it’s on. On iPad and the Mac, the bar has **Add a Device** while it’s on, and the top card has **Turn On** and
**Turn Off**.

## Your devices

The network page’s **Devices** section shows each device on the network as a tile: **Online**, **Asleep**, or
**Can’t reach right now** with a **Why?** link. A device that shares its internet says **Shares its internet** (on
iPhone, **Internet**).

With more than 24 devices, the page shows the three you used last under **Recent**, and the rest in a list you can
search and filter: **All**, **Online**, **Shares internet** (on iPhone, **Internet**), **Can’t reach** and **Asleep**.

Tap or click a device to see what you can do with it:

- **Use …’s internet**, for a device that shares it: browse as if you were where that device is. See [Use another
  device’s internet](#use-another-devices-internet).
- **If … stops answering**: **Use My Own** (this device’s internet until it’s back) or **Wait** (nothing goes out
  until it answers).
- **Apps on …**: the apps that device shares, each with **Open** while it’s online.
- **Copy Address** (on iPhone, **Copy**): the device’s Hub Network address, for apps and terminals.

### When a device can’t be reached

Choose **Why?** to see what Hub knows. A device that can’t be reached is online, but the networks you’re both on won’t
let Hub connect the two; it usually works again once either device changes Wi-Fi. Choose **Try Again**. If the device
shares an app and sits behind a router that blocks direct connections, **Connect Manually…** lets you type the address
and UDP port it answers on, from its own Hub Network page or its router.

## Add a device

1. On the network page, choose **Add a Device**. Hub shows a QR code and three steps.
2. On the other device (a Mac, iPhone or iPad with Hub installed), choose **Connect to a Hub**. On iPhone and iPad,
   choose **Scan** and point it at the code. On a Mac, paste the link (see below) into **Address**.
3. If you’re an owner, the step reads **It joins right away**: your invitation needs no approval, and the device
   appears under **Devices** once it joins. If you’re a member, it reads **An owner approves it**: the device waits
   under **Devices** with a code, and an owner approves it once that code matches the one the device shows. See
   [Approve a device](Devices-and-Access.md#approve-a-device).

Can’t scan? Choose **Send a link instead** or **Copy Link**, and open the link on the other device.

The invitation works once, within seven days. Members of a hub can invite too, but an owner approves each device a
member invites, also when the invitation comes from the hub’s machine. When the device joins, the sheet says so, with
**Add Another** and **Done**.

You can add a device from any device on the network. Away from the hub’s machine, Hub asks that machine for the
invitation, so it has to be on.

On the Mac, **Add a Device** can also invite a phone to browse through this Mac: see [Add a phone that browses
through this Mac](#add-a-phone-that-browses-through-this-mac).

## Join with an invitation

When you open an invitation, scan its code, or paste it into **Connect to a Hub**:

1. Hub asks **Join …’s Network?** and says who invited you (or, for a hub this device doesn’t know yet, which helper it
   finds the hub through), and until when the invitation works. Choose **Join**.
2. **One More Step**, the first time: your device asks to add a VPN. Choose **Continue**, then **Allow** when the
   system asks.
3. Hub checks the invitation, sets up a secure connection and connects. **Joined …** shows **Show Devices**.

If a member invited you, the device waits for an owner after it connects: Hub shows **An owner approves this device in
Hub: code …**. Read that code out to an owner, who approves the device under **Devices** once the codes match. Hub keeps
waiting until the invitation’s time to join runs out.

If joining fails, Hub says why:

- **This invitation was already used** or **This invitation expired**: ask someone in the hub for a new one.
- **Couldn’t reach …**: the Mac that runs the hub may be asleep or offline. Try again once it’s on.
- **You didn’t allow the VPN**: choose **Try Again** and **Allow**.
- **This iPhone is on another hub’s network**: turn that one off first.
- **This iPhone is already on …’s network**: it needs no new invitation. To join again anyway, turn off that hub’s
  network on this device first. It comes back as a new device, and an owner gives it access again.
- **… doesn’t accept this iPhone**: an owner removed it. If that’s a mistake, check this device’s date and time.
- **Couldn’t join …**: **Details** says why, for example that an owner denied this device, or that no owner approved
  it in time. A denied device can ask again once an owner allows it under **Devices**.

## Use another device’s internet

A Mac (or another device whose hub offers it) can share its internet with your devices. Then your phone browses as if
it were at home: sites see your home’s address, and a café’s Wi-Fi sees only an encrypted connection.

To use it:

- On the sidebar’s **Hub Network** card, under **Use internet through**, choose **Use** next to the device. **Stop**
  goes back to this device’s own internet.
- Or on the network page, under **Internet**, choose **Choose…** next to **Use another device’s internet** (or
  **All Devices** on the card). The **Use Internet Through** sheet lists this device’s own internet and every device
  that shares its internet.

While Hub switches over, the device’s row reads **Connecting…** with **Cancel**, which stops waiting and keeps the
internet you had. If the hub doesn’t answer within 20 seconds, Hub gives up and says so.

The device you used last stays on the card: **Last used · available**, **Last used · not sharing now** when it’s online
but stopped sharing its internet, or **Last used · offline** when it’s asleep.

**If … stops answering** decides what happens when that device goes away: **Use My Own** or **Wait**.

While you use another device’s internet, your device keeps the VPN on through restarts.

### Share this device’s internet

On the network page, under **Internet**, turn on **Let your devices use this Mac’s internet** (or this iPhone’s,
where the hub offers it). On the Mac, also turn on [Keep this Mac awake while
sharing](#keep-this-mac-awake-while-sharing).
## Share an app

Share an app that runs on this device, and your devices open it from anywhere.

1. On the network page, under **Apps you share**, choose **Share an App…**.
2. Pick an app Hub found running on this device, or **Another port…** for one that isn’t listed.
3. For another port, type its **Name** and **Port**, and choose its **Kind** (**TCP** or **UDP**).
4. Under **Who can use it**, choose **Change** to pick who may use it.
5. Choose **Share**.

On another device, open this device on the network page and choose **Open** next to the app. The app’s name goes with
it, so your other devices list it by that name. Hub’s own shares show by what they are, for example **Storage** for
this device’s [Storage](This-Device.md#storage).

Each shared app has a menu (**…**, **Who Can Use …**):

- **Everyone in …**, a group, or **Only Me**.
- **Choose People…**: pick the other devices on the network, and the hub’s people where you may see them, one by one,
  then **Save**. Someone the app already allows who isn’t on the network now is listed as **Not on the network now**.
- **Disconnect Everyone Now**: devices that are still allowed can connect again.
- **Stop Sharing**: takes the app off the network.

## Advanced

Expand **Advanced** on the network page for:

- **Connection helper**: the server that helps your devices find each other. It never sees what they send. The default
  is `v57.dev:1964`, run by v57. An owner can choose **Change…** to set another one in the **Coordinator** sheet, or
  **Use v57.dev** to go back to the default, then **Save**. Invitations include the helper’s address.
- This device’s Hub Network addresses (IPv4 and IPv6), its name, and the hub’s address.

## Open ports on this device

A hub can only open a port on this device that you share from it or list here. See [Open
Ports](Settings.md#open-ports).

## On the Mac

### Use This Mac’s Internet Anywhere

The welcome’s **Use This Mac’s Internet Anywhere…** walks through four steps, about a minute in all:

1. Start a private hub on this Mac.
2. Share this Mac’s internet (choose **Allow** when your Mac asks to add a VPN).
3. Keep this Mac awake while sharing.
4. Add your phone: scan a code with it, and it starts browsing through this Mac.

### Add a phone that browses through this Mac

**Add a Device** also has **Use This Mac’s Internet**: the phone that scans the code joins and browses through this
Mac right away. Its code and link are a `hub://browse/…` link, so opened on the phone they go straight to [Browse
Through My Own Internet](#browse-through-your-own-internet). If this Mac doesn’t share its internet yet, choose
**Share It**.

### Keep this Mac awake while sharing

On the network page, under **Internet**, **Keep this Mac awake while sharing** keeps it answering while you’re away;
it can sleep with the lid closed only on power.

## On iPhone and iPad

### Browse through your own internet

The welcome’s **Browse Through My Own Internet** sets up using your Mac’s internet in one go:

1. Read the explainer, then choose **Scan Its Code**.
2. On your Mac, open **Add a Device** in **Use This Mac’s Internet** mode, and scan its code.
3. Choose **Join and Use**, then allow the VPN.
4. **Using …’s Internet** shows **Stop** and **Done**.

Or open the Mac’s link (under **Can’t scan?**) on the phone: Hub asks **Use …’s Internet?** and says which device
invited it. Choose **Join and Use**. Pasted into **Connect to a Hub**, the link does the same.

## On Linux

On Linux, Hub Network runs through the hub-net service. Turning the network on for a hub asks the hub’s machine for
an invitation (on the hub’s own machine, the service serves that hub), and turning it off pauses the membership. The
hub holds this computer until an owner approves it; if you may approve devices on that hub, Hub approves it for you.
The **Advanced** section shows the **hub-net service** state. Using another device’s internet isn’t available on Linux
yet; a Linux computer can share its own.

## Cameras need Hub Network

A hub’s security cameras are reached over Hub Network. See [Security Camera](Security-Camera.md).
