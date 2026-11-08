# Hub

A Hub is a small server you run yourself, on a Mac, a home server or a VPS, with the
[Hub app](https://github.com/v57/hub-app/blob/main/docs/README.md). Connecting Vault to your Hub lets you:

- see all your devices, Linux, Windows and Android ones included;
- reach them over SSH by name from Shell, Database and Code: each Hub device becomes an SSH host in every app;
- sync your vault with devices that have no iCloud.

Hub introduces devices and carries sealed envelopes. It never sees your vault: logins, notes and keys stay end-to-end
encrypted. It does see your devices' names and keys, when they're online, which devices share a vault, and the ids,
sizes and times of what each one syncs.

Nothing connects to a Hub until you add one. Each device decides for itself whether it connects.

## Add your Hub

1. Open **Hub** in the sidebar's Keys section and click **Add Hub…**.
2. Type the Hub's **Address**, starting with `wss://`, and a **Name** for it.
3. Click **Connect**.

The device connects while a v57 app is open. The Hub shows as **waiting for approval**, with a safety code.

hub.v57.dev is a public playground for trying Hub out, with no accounts, guarantees or retention. Vault warns you if
you type it. Don't use it for real data.

## Get this device approved

An owner of the Hub approves each new device. In the Hub app, on another device's Vault, or with
`hub device approve`, compare the code shown there with the code on this device. Once it's approved, the status says
**Connected** and the Hub's devices are listed with **Online** or **Offline**.

## Approve another device

When a device asks to join a Hub you own, it shows under the Hub with **Waiting** and its safety code.

1. Check the code on the new device's screen.
2. Click **Approve…**. The dialog shows the code again.
3. Click **Approve** only if the codes match. **Deny** turns the device away.

If the Hub gives no code to compare, or a different code than this device computes, Vault says so in red. Don't
approve a device you can't check; update the Hub first.

## Your Hub's devices

Select a device to see:

- **Device:** its system, what it runs on, whether it's online on the Hub and on Hub Network, and its id.
- **SSH via Hub:** its address, user and host key. A host key signed by the device is trusted without a question;
  otherwise each app asks the first time. The link opens the device's SSH host.
- **Offers:** the tools and services it runs.

## Turn the connection on or off

**Connect from this device** turns this device's connection to the Hub off or on. The Hub stays for your other devices.

## Sync your vault through a Hub

Turn on **Sync vault through it** under a Hub, or **Vault records through** the Hub in **Settings ▸ Sync**. Your
records go to the Hub's vault service sealed with your vault keys. A device with both iCloud and the Hub carries
changes between them. The **Records** line shows how far it got.

## Revoke a device

If you're an owner, select another device, click **Revoke** followed by its name, then **Revoke**. It can't connect to the Hub again, its
services' keys stop working, Hub Network drops it, and its host goes from every app. Use it for a lost or sold device,
along with [Lost Device](Devices-and-People.md#a-lost-or-stolen-device).

## When something's wrong

Vault shows a red banner with **Remove** when:

- this device was revoked on the Hub;
- another server answers at the Hub's address, with a different key. Nothing is sent to it. If you reinstalled the Hub,
  remove it and add it again;
- the address starts with `ws://` and isn't on your local network. Nothing is sent to it; use a `wss://` address. On
  your local network a `ws://` Hub works, but Vault warns that anyone on the network can see the traffic.

## Remove a Hub

Click **Remove…** under the Hub, then **Remove**. Every device stops connecting to it, and the hosts it added go from
every app. The Hub itself keeps running.

**Settings ▸ Hub** lists your Hubs with their status, with **Open Hub**, or **Add Hub…** when there's none.
