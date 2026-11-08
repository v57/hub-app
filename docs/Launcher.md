# Launcher

hub-launcher runs apps on the hub’s machine: hub-server itself, services and any other program. It restarts them when
they crash and updates them. The **Launcher** page controls it. You see the page only if the hub lets your device see
the launcher.

Changes on this page (installing, uninstalling, updating, settings and instances) need an owner of the hub.

## See what runs

**Launcher** lists each app with its status: CPU, memory and uptime, **Stopped**, **Not running** or **Updating**. An
app with an update shows **Update**.

- On iPad and the Mac, switch between a grid and a list. Select an app to see its details beside the list.
- On iPhone, tap an app to open its details.

A hub with no apps says **No Apps Yet**, with **Get More…** and **New App…**.

## Start, stop and restart

- Use ▶ or ⏸ on an app’s card to start or stop it.
- In an app’s details, **Restart** restarts it.

## Change an app’s settings

In an app’s details:

- **Instances**: how many copies run.
- **Restart on crash**: shown as **On** or **Off**.
- **Environment values**: names and values the app reads. Choose **Add Value** for another one.
- **Secret keys**: values such as API keys. Choose **Add Secret**. hub-launcher keeps them and never shows them again.

Choose **Save**. The app restarts with the new settings.

## Uninstall an app

In an app’s details, choose **Uninstall**, then **Uninstall** again. hub-launcher stops it and removes its files.
hub-server itself can’t be uninstalled here.

## Update apps

When updates are available:

- the app’s card shows **Update**;
- the bar shows **Update All** with the number of updates;
- the hub’s Overview banner offers **Update** or **Update All**.

## Add your own app

Choose **New App** and pick **Shell** or **Bun**:

- **Name**
- **Repository**: cloned into `~/Hub/apps` on the hub’s machine.
- **Directory**
- **Install**: one command a line.
- **Start command**
- **Restart on crash**

Choose **Create**. The app appears in the list and starts.

## Get more apps

Choose **Get More** to open the store, the list of apps hub-launcher can install.

The first time, Hub asks before it loads the list: **App needs to download the list of services from GitHub**, with
the address it loads. Choose **Allow**. Hub remembers your answer, and this is the only request Hub makes for this
list. If loading fails, choose **Retry**.

- Filter the list by kind, or **All**.
- Choose **Get** on an app. It reads **Installing**, then **Installed**, and the app shows on the Launcher page.
- **Change Store** opens another list: type its address in **Store URL** and choose **Open**. **Go to Main Store**
  goes back.

The hub’s machine downloads and installs the app, not this device.
