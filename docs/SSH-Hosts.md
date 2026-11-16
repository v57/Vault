# SSH Hosts

Your SSH hosts are the servers and computers the v57 apps sign in to. [Shell](https://github.com/v57/Shell/blob/main/Docs/README.md),
[Database](https://github.com/v57/Database/blob/main/docs/README.md), [Code](https://github.com/v57/Code/blob/main/docs/README.md)
and [Git](https://github.com/v57/Git/blob/main/docs/README.md) all use the same list. On the Mac, Vault's
[SSH agent](SSH-Agent.md) can also lend a key to `ssh` and `git` in Terminal.

## See your hosts

Open **SSH Hosts**. On iPad and the Mac they show in a table with the name, address, user, how they sign in, the jump
host and which apps use them. On iPhone each row shows the user and address, with a **Device key**, **Password**,
**Imported key** or **Via Hub** chip.

- **Filter:** **All**, **Device Key** or **Password**.
- **Search:** type part of a name, address or user.

Select a host to see:

- **Connection:** the host, its fallback addresses, the user, the port and the jump host.
- **Device keys**, for a host that signs in with them: each of your devices signs in with its own Secure Enclave key.
  The list shows every device's fingerprint, with **Copy Public Key** to add it to the server.
- **Password**, if the host signs in with one: **Show** and **Copy**, after the app lock, and whether it's saved or
  asked each time.
- **Known host:** the server's key that your apps trust, with its fingerprint.
- **Via Hub:** for a device your Hub added (see [Hub](Hub.md)).
- **Linked:** the database connections and logins that use this host.

**Copy SSH Command** copies a command like `ssh -p 2222 user@my-server` to paste into a terminal. On iPhone, the **…**
menu also has **Copy Host** and **Copy User**.

The status line under the list counts your hosts, how many sign in with this device's key, and how many come through a
Hub.

## Add a host

1. Click **+** in the SSH Hosts toolbar, or choose **New SSH Host…** from the New menu.
2. Fill in **Name**, **Address**, **User** and **Port** (22 unless you change it). You can add
   [fallback addresses](#fallback-addresses) here too.
3. Leave **Sign in with each device’s own key (Secure Enclave)** on to sign in without a password. Each device then
   has its own key for this server; add each device's public key to the server's `authorized_keys`. Turned off, the
   host signs in with a password; the sheet has no password field.
4. Click **Save**. Shell and Database see it at once.

## Edit a host

Select the host and click **Edit**. The **Edit SSH Host** sheet opens with its values. Change them and click **Save**.

### Fallback addresses

A host can have other addresses to try, in order, when its address doesn't answer: for example a name on your home
network and another away from it.

1. In Edit SSH Host, under **Fallback Addresses**, click **Add Address**.
2. Type the address. Vault marks one with a space in it, and one that's tried already (the host's address or a row
   above), which it leaves out when you save.
3. Click the minus button to remove an address.

For one of your own devices, Vault also lists the addresses it finds itself, marked **Automatic**. You can't edit those.

## Server keys

The first time any v57 app connects to a server, it asks **Trust this server's key?** and shows the key's fingerprint.
Nothing has been sent to the server yet. Choose **Trust and Connect** only if this is the server's key. The key is then
pinned and every app shares it.

A fallback address is trusted only for a server whose key is already pinned: the question is asked only when the
host's own address answers.

GitHub, GitLab and Bitbucket never ask: the v57 apps know their published keys and refuse any other.

If a server later answers with a different key, every app refuses it without asking. That's what happens when someone
pretends to be your server, but also when the server was reinstalled. Once you know why the key changed:

1. Select the host in Vault.
2. In **Known host**, click **Forget Key**.
3. Connect again from Shell, Code or another app. It asks about the key as on a first connection.

## Deleting a host

Vault doesn't delete hosts yet. Delete one in Shell; it goes from every app.
