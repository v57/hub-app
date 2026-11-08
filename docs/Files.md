# Files

A hub can store files once a storage service runs on it. **Files** shows that storage, or helps you connect some.

## Connect storage

If a hub runs the launcher but has no storage yet, **Files** opens **Connect Storage** with three tabs:

- **Local**: shares one folder on the hub’s machine, `~/Hub/Files`. Only this folder is shared.
  1. Choose **Create**. The launcher installs the storage service.
  2. Choose **Allow** to let the service post its APIs on the hub.
  3. Choose **Test**, then **Open Files**.
- **Cloud**: steps for a cloud storage provider (Wasabi): create an account, a bucket and an access key on its
  website, then type the **Bucket Name**, **Server Region**, **Access Key** and **Secret Key**. Use **Start**,
  **Continue** and **Back** to move through the steps, then **Create**, **Allow** and **Test** as for Local.
- **Connect**: your own S3-compatible storage. Fill in **Endpoint**, **Region (optional)**, **Bucket name**,
  **Access Key** and **Secret Key**, then **Create**, **Allow Access** and **Test**. Later, **Update** changes them.

Installing storage needs permission to install apps on the hub. Without it, Hub says **You don't have permissions to
install services**. If you can install but not allow, ask the hub’s owner to give access to the storage service.

The keys you type for your own S3 storage go to the hub’s launcher, which keeps them as the service’s secrets.

## Browse files

- When a hub has several storage places, pick one from the cards at the top.
- Use the path at the top or **Back** to move up. Double-tap a folder to open it.
- The table shows **Name**, **Kind**, **Size** and **Modified**. On iPad and the Mac you can search.

Select a file to see its **Folder**, **Modified** and **Size**. **Copy Link** copies a link to the file from the
hub’s storage.

## Upload files

- Choose **Upload** in the bar and pick one or more files.
- On iPad, you can also drag files from the Files app onto the list.

An empty folder says **Empty Folder** and **Drop files here to upload them**.

## Delete a file

Select the file, choose **Delete…**, then **Delete**. It’s removed from the hub’s storage for everyone.

## Who can use storage

Storage services allow only the hub’s owners by default. To let another device use files, give its group the storage
permissions on [Permissions](Devices-and-Access.md#permission-groups), or grant them to the device directly.
