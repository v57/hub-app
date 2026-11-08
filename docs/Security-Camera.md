# Security Camera

Any iPhone, iPad or Mac with Hub can be a security camera for a hub, for example an old iPhone that stays at home. It
watches for motion and records clips. Your other devices on the hub’s Hub Network watch it live, browse its clips and
get motion alerts. There is no camera service in the cloud: the picture goes between your own devices.

Cameras need [Hub Network](Hub-Network.md) on both the camera and the device that watches it. Cameras aren’t
available on Linux.

## The Cameras page

Open a hub’s **Cameras** page:

- With no cameras yet, it says **No Cameras on …**, with **Use This iPhone as a Camera** (or iPad, Mac).
- With cameras, it shows a live tile for each, the motion events, and where clips are kept. On iPad and the Mac, an
  **Add Camera** tile and the bar’s **Add Camera** add one; on iPhone, the bar has **Camera**.

If Hub Network is off on this device, a banner says **Cameras need Hub Network**, with **Open Network**.

## Turn a device into a camera

On the device that will be the camera:

1. Open the hub, then **Cameras**.
2. Choose **Camera** (iPhone) or **Add Camera ▸ Set Up…** (iPad and the Mac). The page **This iPhone as a Camera**
   opens.
3. Turn on **Use as a Security Camera**. The first time, the system asks for the camera.

Only the hub’s devices on Hub Network that know the camera’s password can watch. A device can be a camera for one hub
at a time: turning it on for another hub moves it.

The page’s bar has **Turn On** and **Turn Off**.

On iPhone and iPad, Hub has to stay open for the camera to work. **Camera Screen** in the bar turns the screen black to save
power and heat. Touch it to see the status (network, battery, microphone off, temperature and where clips go), and
choose **Preview**, **Back to Hub** or **Stop Camera**. The screen turns black again after 30 seconds.

On the Mac, the camera stays on while the Mac is awake.

When Hub opens again on the camera’s device, the camera comes back on where it was.

## Camera settings

Each lens on the device is its own camera, with its own name, video, motion and clips. **Cameras** lists them; more of
them on means more heat and more data.

- **Preview** with the motion zone: **Add Zone…** or **Edit Zone…**, set the area, then **Save Zone**. **Whole
  Picture** watches the whole picture again.
- **Motion**: **Sensitivity** sets how much of the picture (or zone) has to change before a clip records. The live
  level shows against the line.
- **Video**: **Name** (the place it watches, such as Front Door), **Resolution**, **Frame Rate**, **Codec** (**H.264**
  plays everywhere, **HEVC** uses about 40% less data) and **Bitrate**. **Microphone** isn’t available yet: live view
  and clips are silent.
- **Picture and Power**: a profile, **Best Picture**, **Balanced** or **Low Power**, or your own mix of
  **Stabilization**, **Focus**, **Exposure** and **White Balance** (**Auto**, **Slow** or **Locked**). **Lock Now**
  locks focus, exposure and colour where they are. The **Budget** shows the cost in heat and CPU.
- **Expected Usage**: an estimate of the data for live view, clip uploads and clips kept, for this camera or **All
  Cameras**.
- **Clips**: **Keep Clips On** this device or the hub’s storage, **Delete After** (1 to 90 days) and **Size Limit**
  (the oldest clips go first). With the hub’s storage, each clip goes there when it ends, and the device keeps a
  thumbnail. If the hub’s storage can’t be reached, a banner says **Clips stay on this iPhone**.
- **Access**: the camera’s **Password**, with **Show**, **Copy** and **Change…**. Devices that watch it sign in again
  with a new password. **Shared** shows how many devices are watching.
- **Apple Home** comes in a later version.

On iPhone, **Picture and Power** and **Expected Usage** open as their own pages under **More**.

### When to record (Mac)

On the Mac, **When to Record** has **Record Clips**: **Always** or **When I’m Away**. When you’re away means no keyboard
or mouse for the time in **Away After**; a locked or sleeping Mac counts at once. **Live View While Paused** keeps the
picture for viewers while no clips record. **Record for 1 Hour** records even while you’re there; **Stop** ends it.
Hub checks only whether the Mac is in use; nothing about that leaves the Mac. Viewers see that clips are paused.

## Watch a camera

On another device on the hub:

1. Open **Cameras** and tap a camera’s tile.
2. The first time, type the camera’s password and choose **Watch**.

A camera’s page shows the live picture, the day’s motion events and a timeline. Tap an event to play its clip:

- **Previous Event** and **Next Event**
- **Save…** and **Share**
- **Delete Clip**: deletes it from the camera and wherever its clips are kept, for everyone who watches it.
- **Live** goes back to the live picture. **Settings** opens the camera’s settings on its own device.

**Motion Events** on the Cameras page lists **Today** or the **Week**. Tap one to see its clip.

On iPad with a keyboard and on the Mac, ⌘[ goes back to Cameras.

## Motion alerts

On a camera’s page, choose **Motion Alerts**. The first time, the system asks to allow notifications. When the camera
sees motion, this device shows **Motion at …** with a picture; tap it to open the camera’s page. Choose **Motion
Alerts On** to stop.

Alerts come straight from the camera over Hub Network, with no push service. On iPhone and iPad with iOS 18 or
later, they also arrive while Hub is in the background, as long as Hub Network is on.

If notifications are off for Hub, it says **Notifications are off for Hub. Turn them on in Settings, then try again.**
