# Services and Apps

Services are programs that connect to a hub and publish APIs, such as `video/encode/hevc`. Devices and other
services call an API by its path. When several devices publish the same API, the hub splits the requests between
them. Services can also publish apps: pages, widgets and web apps that Hub draws.

## Overview

Open a hub to see its **Overview**:

- **APIs**, **Devices**, **Requests / s** (with a small chart) and **Connections**. Tap a card to open its page.
- A banner when something needs you: a device waiting to join, a service asking to post APIs, or a launcher update.
  - On iPhone, **Review** opens what waits first.
  - On iPad and the Mac, **Update** (on the Mac, **Update** and the app’s name) or **Update All** installs updates,
    and **Review Requests** opens the waiting devices or requests.
- The widgets your services publish, and an **Apps** card with the hub’s service apps.

The bar has **Invite**, which opens the hub’s Hub Network page, and **More** (**…**) for the hub’s menu.

## Services

**Services** lists the hub’s APIs, grouped by the first part of their path. Filter them with **All**, **Online**,
**Needs approval** or **Offline**.

- On iPad and the Mac, the list is a table you can sort and expand, with a search field for a path or a provider.
  The bottom bar says which address you’re connected to and the end of your key.
- On iPhone, the APIs are in sections. Tap one to open it.

An API’s status is **Online**, **Needs approval** (it waits for an owner to allow it, see
[Requests](Devices-and-Access.md#requests)), **Disabled** or **Offline**.

A new hub shows **No Services on …**. Choose **Open Launcher** to install one, or run your own.

### An API’s details

Select an API to see:

- **Providers**: the devices that publish it, and how many are online or disabled.
- **Load balancer**: how requests pick a provider.
- **Requests** since the hub started: **Total**, **Running** and **Pending**.
- **About**, when the service describes the API: what it does, whether it only reads or can change things, and what
  goes in and comes out.
- **Copy Path**, and **Permissions…** to open the hub’s permission groups.

### Choose a load balancer

Owners, and anyone with permission to change it, can pick how an API’s requests go to its providers:

- **Random**: any provider.
- **Round-robin**: each in turn.
- **Queued**: in order.
- **Distributed**: the first free provider.

The hub saves the choice. Without that permission the choice is shown but can’t be changed.

## Apps

**Apps** shows the apps the hub’s services publish. Tap one to open it:

- A service app is a page Hub draws from what the service describes. An app whose service is offline says
  **Offline**.
- A web app opens in a web view inside Hub.

Apps hidden in an earlier version of Hub are listed under **Hidden**. Choose **Show** to bring one back to **All
Hubs** and the Overview.

## Services this device runs

This device can be a provider too: it can compress images and videos, translate text and more for your hubs. See
[Shared Services](This-Device.md#shared-services).
