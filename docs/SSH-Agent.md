# SSH Agent

On the Mac, Vault's SSH agent lets `ssh`, `git` and the other programs you run sign with a Secure Enclave key, for as
long as you choose, and asks you before each signature.

<!-- platforms: macos -->

The agent is off until you turn it on. While it's off, only the v57 apps use your keys: `ssh` and `git` in Terminal
can't. It runs inside Vault, with no helper or login item. Quitting Vault stops it and removes its socket, and after
Vault opens again it's off.

## Turn it on

1. Open **SSH Agent** in the sidebar's Keys section. Its row shows **Off**, **On** or the time left.
2. Under **Turn on for**, click a length: **10 sec**, **10 min**, **1 hour**, **8 hours**, **24 hours** or **Until
   turned off**.

The screen shows the time left. While it's on, **Restart for** starts the clock again from now with the length you
click, and **Stop Now** turns it off. It also stops by itself when its time is up.

The first time you turn it on, Vault asks **Use the agent from Terminal too?** **Add Line** sets that up (see below);
**Not Now** leaves your `~/.ssh/config` alone. It's asked only once.

## Use it from Terminal

For `ssh` and `git` in Terminal to find the agent, turn on **ssh and git in Terminal** on the SSH Agent screen, or
**Settings ▸ SSH Agent ▸ Use from Terminal**. Vault then:

- puts one line, `Include ~/.ssh/vault.conf`, at the top of `~/.ssh/config` (it makes the file if there's none);
- writes `~/.ssh/vault.conf`, which sends the agent's hosts to Vault's socket, and keeps it up to date when you change
  the hosts. The screen shows the file, with **Show in Finder**.

The file applies only while Vault's socket exists, so with Vault quit `ssh` uses your own keys as before. The rest of
your `~/.ssh/config` applies as it did. If your config is a link (to a dotfiles folder, say), Vault writes where it
points.

Turning the switch off takes the line out and deletes `vault.conf`.

If your config also names another agent (1Password, Secretive and so on), Vault shows its line. Vault's line comes
first, so the hosts you give Vault use Vault and the rest keep the other agent.

## Choose the hosts

Under **Hosts**, list the servers `ssh` should reach through the agent. Type a name such as `github.com` and click
**Add**, or click a suggestion: GitHub, GitLab and your [SSH hosts](SSH-Hosts.md). The minus button removes one. With
no host listed, no server reaches the agent.

Turn on **Every host** to use the agent for every server instead. Your other servers keep your own keys while it's off.

## Choose the key

- **Agent key** (the default): a second Secure Enclave key, made for the agent only. Add its public key to the servers
  `ssh` should reach. Turning the agent off never locks Shell or Git out.
- **This Mac’s key**: the key Shell, Git and Database sign in with. Every server that trusts this Mac is then open to
  what the agent lets in.

The screen shows the key's fingerprint, and **Copy Public Key** copies the line for a server's `authorized_keys`. Both
are ECDSA P-256 keys (`ecdsa-sha2-nistp256`).

The agent key is made in this Mac's Secure Enclave the first time it's needed and never leaves it. It doesn't sync, and
the other v57 apps can't use it. Where the Mac has a password, it signs only after you confirm it's you.

To make a new agent key, choose **Settings ▸ SSH Agent ▸ Replace…**, then **Replace**. The agent stops, and every
server that trusted the old key needs the new one.

## When it asks

By default each signature asks. A panel shows over your apps without taking you away from the one you're in. It says
who asked, the programs that led to it (such as `zsh › git push › ssh`), what for (signing in to a server, signing a
commit) and with which key.

- Touch the sensor to allow, or click **Use Password…**. On a Mac without Touch ID, click **Allow** and confirm.
- **Deny**, or Esc, says no.
- **Don’t ask again for** an app lets it sign without asking until the agent stops.
- Requests that arrive together wait for the panel before them.

To be asked only once, set **Touch ID** to **Once per turn-on** (on the screen or in **Settings ▸ SSH Agent**). Vault
then asks when you turn the agent on, and that yes covers its whole length.

**AI agents always ask.** When a request was started by an AI coding agent (Claude Code, Codex, Gemini CLI, Cursor
Agent, Aider and others Vault knows), the panel asks every time and warns that you didn't type it. It doesn't offer
**Don’t ask again** for those. You can turn this off in **Settings ▸ SSH Agent**.

The agent also stops when the Mac locks, sleeps or switches to another user, unless you turn off **Stop when the Mac
locks**. Stopping forgets every yes.

## Requests

**Requests** lists what used the agent since Vault opened: the time, the app and its programs, the server or what was
signed, and the result (**Signed**, **Denied**, **Listed**, **Agent was off** or **Failed**). The list isn't saved.

After the agent stops, its card shows when it stopped, how long it was on, and how many signatures it gave and denied.

## While it's off

Once the agent has been on, Vault keeps its socket open while it runs. While the agent is off it offers no key, so
`ssh` goes on to your own keys.

When something asks while it's off, a panel says which app asked and offers **Turn On for 10 min**, **Ignore** and
**Open Vault**. It goes away by itself after 20 seconds, and comes at most once an hour for each app. Turn it off with
**Settings ▸ SSH Agent ▸ Offer to turn on when asked while off**.

## The menu bar

Once the agent has been on, a key shows in the menu bar while Vault runs, with the time left while it's on. Its menu
has the state, **Stop Now**, the lengths to turn it on (or restart it) for, the key, **Touch ID for Each Signature**
and **Open SSH Agent…**. Turn it off with **Settings ▸ SSH Agent ▸ Show in menu bar**.

## Privacy

The agent's socket is a file beside your vault's store, in the folder the v57 apps share, that only your user can
open. Vault also checks that each connection comes from your user. Vault reads which programs started a request from the system, to show them and to
spot AI agents. The agent sends nothing over the network itself: `ssh` makes the connection.
