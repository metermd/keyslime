# Keyslime: Key & Ticket Distribution for Server Fleets

## Table of Contents
 * [Introduction](#introduction)
 * [Moving Parts](#moving-parts)
   * [Master Key Server](#master-key-server-keyslime-louis)
   * [Key Clients](#key-clients-keyslime-dana)
 * [Miscellaneous Implementation Notes](#miscellaneous-implementation-notes)
 * [Requirements and Installation](#requirements-and-installation)
 * [Authors](#authors)
 * [Footnotes](#footnotes)

## Introduction
Keyslime was created to distribute shared TLS Session Ticket keys across a fleet
of front-end web servers.  It implements a model roughly equivalent to
[Twitter's solution described here](1).

You can read about the problem Keyslime attempts to solve
[in this article by Google's Adam Langley](2).

As a side-effect of its design, it's also good for generally oozing down your
HTTPS or other private keys from a central server to TLS termination
endpoints.  It's definitely better than copying a private key in your deployment
scripts or configuration management system.

It uses password-disabled Unix user accounts for access control.  It uses SSH
public-key logins between components to provide authentication and a secure
channel to transport keys.

It keeps the keys it generates or receives in non-swappable RAM, so they never
touch the disk.  This means disk forensics can't break forward secrecy by
finding long-deleted keys in hidden nooks between files on a disk.

There are no long-running processes eating resources, although systemd creates
the illusion that it's a traditional daemon.

If you're hosting on a modern, run-of-the-mill Linux VPS, it has no external
dependencies.  And the software it relies on (Bash, OpenSSH, and systemd) are
already running and in memory regardless.

There are no tunable knobs within Keyslime.  It maintains three keys into the
future, an active key, and 16 expiring keys.  It updates every hour.  Keys are
active for an hour.  The home directories it creates for its users are at
fixed paths.  This keeps the number of branches and substitutions down in the
implementation.  It may not work for your use-case.

The system consists of two components:
  1. `keyslime-louis`, which generates TLS Session Ticket keys, rotates them,
      and manages a directory that clients (`keyslime-dana`) can pull from.
  2. `keyslime-dana` runs on nodes that need access to the keys.  It
     periodically connects to `keyslime-louis` and clones said directory.

After Keyslime is installed on both ends, what's left is:
  1. Give the `keyslime-louis` node some SSH public keys he will allow access
     from, and drop them into `/var/lib/keyslime-louis/authorized_keys.d`.
  2. Make sure each `keyslime-dana` node has a private key that corresponds to
     one of those authorized_keys, and it goes in `/var/lib/keyslime-dana/.ssh/id_rsa`
  3. On each `keyslime-dana` node, make sure the command-line
     `ssh keyslime-louis` actually leads somewhere useful for the
     `keyslime-dana` account.  The best place for that is in
     `/var/lib/keyslime-dana/.ssh/config`.
  4. *Free Bonus*: Know that files placed into `/var/lib/keyslime-louis/extra`
     go along for the ride with the generated TLS Session Tickets, and get the
     same ramdisk treatment on your web-server side.  You can put HTTPS
     certificates and private keys there if you're bored.

Getting this stuff in order is a good job for Chef, Puppet, Ansible, or whatever
you're using to provision your servers.

Optionally, install and configure [rssh](3) on each `keyslime-louis` server and
set the `keylime-dana` account up with it.


## Moving Parts
Here's a breakdown of how it's implemented, on the master key server and
clients:

### Master Key Server (`keyslime-louis`)
This is the authoritative server that generates and serves out The Truth to
clients.

You need to install `keyslime-louis`.  It creates a user named *keyslime-louis*
which has a home directory in `/var/lib/keyslime-louis`.  It also creates an
account for the clients to login as: *keyslime-dana*.  Her home directory lives
in `/var/lib/keyslime-louis/exports`.  This is a 1MB `ramfs` Ramdisk.  
*keyslime-dana* can only read from her home directory, while *keyslime-louis*
can read and write to it.

Periodically, `keyslime-louis` is woken up and examines the exports directory.  
Old keys are removed, and new keys are generated as needed.  `keyslime-louis`
maintains the previous 24 hours of keys, and two keys (two hours) into the
future.  During the time that `keyslime-louis` is manipulating keys,
*keyslime-dana*'s read access to her home directory is revoked to assure she
doesn't log in and fetch inconsistent data.

`keyslime-louis` has a directory: `/var/lib/keyslime-louis/authorized_keys/`.  
It makes sure any SSH public keys contained within are concatenated together to
form the local *keyslime-dana*'s `~/.ssh/authorized_keys` file.  This is how
the clients are allowed to log in.

After each wakeup, if anything is altered,
`/var/lib/keyslime-louis/after-update` is executed if it exists (as the user
*keyslime-louis*).  This gives you an opportunity to create or manipulate any
files in `/var/lib/keyslime-louis/exports`.  `keyslime-dana` clients grab the
entire contents of the directory when they stop by.

The server this runs on needs to be locked down, allowing only SSH access,
and hopefully only from internal networks.  Note: keys are not stored on
physical media, so keys can't survive a reboot.  This is a feature.  However,
because they're in memory, the last 16 hours of session ticket keys are at risk
to anyone that gains unauthorized access to the server.  This can defeat
forward-secrecy for any transmissions that occurred with those keys.  Read Adam
Langley's article linked at the start of this document to get a grasp on the
implications of this.

### Key Clients (`keyslime-dana`)
This is a node that needs to be able to fetch TLS Session Ticket keys from a
server running `keyslime-louis`.  These are typically front-end servers that
terminate TLS connections with nginx or the like.

You need to install `keyslime-dana`.  The package will create a local user
named *keyslime-dana*, with a home directory of `/var/lib/keyslime-dana`.

Inside of this home directory exists `/var/lib/keyslime-dana/keys`.  This is
a 1MB ramdisk (`ramfs`).  *keyslime-dana* can write to it, and all users in the
group *keyslime-access* can read from it.  So the user that, e.g., nginx runs
as needs to be a member of this group.

Periodically, `keyslime-dana` will wake up and connect to the master key
service, using her local SSH keys (i.e., `/var/lib/keyslime-dana/.ssh/id_rsa`).  
She will fetch the contents of the remote keys directory and place it
in `/var/lib/keyslime-dana/keys`.  `keyslime-dana` always connects to the host
`keyslime-louis`.  You can change what this means by altering her ssh config,
with something like so:

```
# /var/lib/keyslime-dana/.ssh/config
Host keyslime-louis

# This user would be the default anyway, but you can change it.
User keyslime-dana

# Here's the physical address keyslime-louis lives at.
HostName 192.168.0.115
```

After a successful fetch, `/var/lib/keyslime-dana/after-update`, if it exists,
is **executed as the root user** (systemd orchestrates this: No other code runs
as root).

The contents of that file should be exceedingly clear and short.  This is
where you send `HUP`s and `reload`s to anything that needs to know that the
keys have updated.  Typically, only `root` can send such signals, hence the
requirement.

Because keys are stored on a ramdisk, they are lost on a power-outage.  This
means the keys are only vulnerable to bad actors while the machine is on, and
they never touch the disk (not even swap).

## Miscellaneous Implementation Notes
Here are just a few random notes gathered about the implementation:

  * Keyslime is implemented in Bash (*... not sh*).  It is written to be as simple
    and procedural as possible.  The goal is to make audits tractable.  Start
    digging at the systemd unit files, and read the scripts it launches like a
    choose-your adventure book.
  * An initial version was implemented in Ruby.  It ended up looking a lot like
    a procedural shell script, so I cut out the middleman.  Bash brings in less
    dependencies, and there's a very good chance you won't have to do anything
    to get it on your servers.
  * By default, `keyslime-louis` is scheduled to run every 57 minutes, and
    `keyslime-dana` is scheduled to run every 60 minutes.  This is to prevent
    pathological cases of each of them being perfectly synchronized, and the
    client being denied access to her files while `keyslime-louis` is
    manipulating them.  Occasionally, the two may clash.  That's fine: There's a
    retry-with-back-off in place.  The future keys will get you by.
  * To prevent "thundering herd" problems, `keyslime-dana` sleeps a random
    amount of time between 0 seconds and 3 minutes when it wakes up before
    retrieving keys.
  * `keyslime-louis` generates 16 hours of past keys on first launch (or
    whenever they don't exist).  This is to avoid corner cases in both
    component's code, and to allow for stable configuration.  (E.g., an nginx
    configuration file referencing 20 symlinks instead of a variable amount of
    symlinks, some of which won't exist.  These key files, which are only 48
    bytes of random data, are harmless unless you're the type of person who
    worries about the SHAs of git commits *accidentally* colliding.
  * Keyslime's functionality is so intertwined with its operating system and
    network environment that it's really hard to add meaningful tests.  Once
    everything is mocked, what's left is too trivial to really do any good.  If
    this is a burning concern of yours, Keyslime may not be for you.
  * We use a 1MB `ramfs` filesystem to store the keys on.  On Linux, `tmpfs` can
    enforce a partition size, but its contents may get swapped to disk.  `ramfs`
    never gets swapped, but will grow to fill its contents, potentially
    exhausting memory if you do anything crazy.  In normal operation, Keyslime
    only uses a few KB of storage on this volume, but if you start generating
    Blu-Ray disk images instead of keys, you'll run into problems.

## Requirements & Installation
Even though all of this sounds pretty complicated, I've tried to keep Keyslime
as simple as possible, in both architecture and implementation.  This is
accomplished by heavily leaning on existing mechanisms of the host operating
system (which currently only includes Linux).

Keyslime relies on systemd for making all of this work.  This offloads a lot of
complicated stuff.  Check out the unit files.  There are no plans to add support
for other init systems, but isolated PRs will be happily received if they are
non-intrusive and don't change how the system works architecturally.  Be warned,
however: half of the implementation is orchestrated by systemd.  It'd be cool to
see a launchd version.

Keyslime has been used heavily in production, but only on our platform of
choice: Ubuntu 16.04.  I don't think there's anything stopping it from working
on other systemd-based Linux systems, though.  Let me know how that goes.


It'd be nice to have official deb and RPM packages available, or maybe even
apt and yum repositories, but neither have happened yet.

## Authors
Keyslime was written at meter.md by Mike A. Owens <mike@meter.md>,
<mike@filespanker.com>

The project homepage exists at https://github.com/mieko/keyslime

Contributions are welcome via GitHub

## Footnotes
  1. Keyslime is released to the public under the terms of the MIT license.
     See the LICENSE file for details.
  2. *dana* stands for *Distributed, Authenticated, Node Automation*
  3. *louis* is the dude from Ghostbusters

[1]: https://blog.twitter.com/2013/forward-secrecy-at-twitter-0 "Forward Secrecy at Twitter"
[2]: https://www.imperialviolet.org/2013/06/27/botchingpfs.html "How to botch TLS forward secrecy"
[3]: http://www.pizzashack.org/rssh/ "rssh - restricted shell for scp/sftp"
