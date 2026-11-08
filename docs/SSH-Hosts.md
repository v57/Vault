# SSH Hosts

Your SSH hosts are the servers and computers the v57 apps sign in to. [Shell](https://github.com/v57/Shell/blob/main/Docs/README.md),
[Database](https://github.com/v57/Database/blob/main/docs/README.md), [Code](https://github.com/v57/Code/blob/main/docs/README.md)
and [Git](https://github.com/v57/Git/blob/main/docs/README.md) all use the same list.

## See your hosts

Open **SSH Hosts**. On iPad and the Mac they show in a table with the name, address, user, how they sign in, the jump
host and which apps use them. On iPhone each row shows the user and address, with a **Device key**, **Password** or
**Via Hub** chip.

- **Filter:** **All**, **Device Key** or **Password**.
- **Search:** type part of a name, address or user.

Select a host to see:

- **Connection:** the host, its fallback addresses, the user, the port and the jump host.
- **Device keys:** each of your devices signs in with its own key. The list shows every device's fingerprint, with
  **Copy Public Key** to add it to the server.
- **Password**, if the host signs in with one: **Show** and **Copy**, after the app lock.
- **Known host:** the server's key that your apps trust, with its fingerprint.
- **Via Hub:** for a device your Hub added (see [Hub](Hub.md)).
- **Linked:** the database connections and logins that use this host.

**Copy SSH Command** copies a command like `ssh -p 2222 user@my-server` to paste into a terminal. On iPhone, the **…**
menu also has **Copy Host** and **Copy User**.

## Add a host

1. Choose **New SSH Host…** from the New menu.
2. Fill in **Name**, **Address**, **User** and **Port**.
3. Leave **Sign in with each device’s own key (Secure Enclave)** on to sign in without a password. Each device then
   has its own key for this server; add each device's public key to the server's `authorized_keys`.
4. Click **Save**. Shell and Database see it at once.

## Edit a host

Select the host and click **Edit**. The **Edit SSH Host** sheet opens with its values. Change them and click **Save**.

### Fallback addresses

A host can have other addresses to try, in order, when its address doesn't answer: for example a name on your home
network and another away from it.

1. In Edit SSH Host, under **Fallback Addresses**, click **Add Address**.
2. Type the address. Vault refuses one with a space or one that's already listed.
3. Click the minus button to remove an address.

For one of your own devices, Vault also lists the addresses it finds itself, marked **Automatic**. You can't edit those.

## Server keys

The first time any v57 app connects to a server, it asks **Trust this server's key?** and shows the key's fingerprint.
Nothing has been sent to the server yet. Choose **Trust and Connect** only if this is the server's key. The key is then
pinned and every app shares it.

A fallback address is trusted only for a server whose key is already pinned.

If a server later answers with a different key, every app refuses it without asking. That's what happens when someone
pretends to be your server, but also when the server was reinstalled. Once you know why the key changed:

1. Select the host in Vault.
2. In **Known host**, click **Forget Key**.
3. Connect again from Shell, Code or another app. It asks about the key as on a first connection.

## Deleting a host

Vault doesn't delete hosts yet. Delete one in Shell; it goes from every app.
