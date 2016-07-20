# Keyslime: Key & Ticket Distribution for Server Fleets

## Table of Contents
 * [Introduction](#introduction)
 * [Moving Parts](#moving-parts)
   * [Master Key Server](#master-key-server)
   * [Key Clients](#key-clients)
 * [Miscellaneous Implementation Notes](#miscellaneous-implementation-notes)
 * [Requirements and Installation](#requirements-and-installation)
 * [Authors](#authors)
 * [Footnotes](#footnotes)

## Introduction
Keyslime was created to distribute shared TLS Session Ticket keys across a fleet
of front-end web servers.  It implements a model roughly equivalent to
[Twitter's solution described here](https://blog.twitter.com/2013/forward-secrecy-at-twitter-0).

You can read about the problem Keyslime attempts to solve
[in this article by Google's Adam Langley](https://www.imperialviolet.org/2013/06/27/botchingpfs.html).

As a side-effect of its design, it's also great for generally oozing down your
HTTPS private keys from a central server to TLS termination endpoints.  

It keeps the keys it generates in non-swappable RAM, so they never touch the
disk (You can decide against this to survive reboots, but do so informed).

The system consists of two components:
  1. `keyslime-louis`, generates TLS Session Ticket keys, rotates them, and
     sets up a directory that clients can pull from.
  2. `keyslime-dana` runs on nodes that need access to the keys.  It
     periodically connects to `keyslime-louis` and fetches keys.

With something this security-sensitive, the devil is in the details.  We rely on
Unix fundamentals as much as possible, using Unix user accounts and permissions
for authentication and access control, SSH + key authorization for data
transfer, and systemd for running the whole thing.

## Moving Parts
Here's a breakdown of how it's implemented, on the master key server and
clients:

### Master Key Server
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
physical media, so key can't survive a reboot.  This is a feature.  However,
because they're in memory, the last 24 hours of session ticket keys are at risk
to anyone that gains unauthorized access to the server.  This can defeat
forward-secrecy for any transmissions that occurred with those keys.  Read Adam
Langley's article linked at the start of this document to get a grasp on the
implications of this.

### Key Clients
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

The contents of that file should been exceedingly clear and short.  This is
where you send `HUP`s and `reload`s to anything that needs to know that the
keys have updated.  Typically, only `root` can send such signals, hence the
requirement.

Because keys are stored on a ramdisk, they are lost on a power-outage.  This
means the keys are only vulnerable to bad actors while the machine is on, and
they never touch the disk (not even swap).

## Miscellaneous Implementation Notes
Here are just a few random notes gathered about the implementation:

  * By default, `keyslime-louis` is scheduled to run every 57 minutes, and
    `keyslime-dana` is scheduled to run every 60 minutes.  This is to prevent
    pathological cases of each of them being perfectly synchronized, and the
    client being denied access to her files while `keyslime-louis` is
    manipulating them.  Occasionally, the two may clash.  That's fine: There's a
    retry-with-back-off in place.  The future keys will get you by.
  * To prevent "thundering herd" problems, `keyslime-dana` sleeps a random
    amount of time between 0 seconds and 3 minutes when it wakes up before
    retrieving keys.
  * `keyslime-louis` generates 24 hours of past keys on first launch (or
    whenever they don't exist).  This is to avoid special cases in both
    component's code, and to allow for stable configuration.  (e.g., an nginx
    configuration file referencing 24 symlinks instead of a variable amount of
    symlinks, some of which won't exist and will stop nginx from launching.)  
    These key files, which are only 48 bytes of random data, are harmless unless
    you're the type of person who worries about the SHAs of git commits
    *accidentally* colliding.
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

Keyslime relies on systemd for configuration-after-installation, boot-time
activation, and cron-style scheduling.  This offloads a lot of complicated stuff
to systemd.  Check out the unit files.  There are no plans to add support for
other init systems, but isolated PRs will be happily received if they are
non-intrusive and don't change how the system works architecturally.  Be warned,
however: half of the implementation is orchestrated by systemd.  It'd be cool to
see a launchd version.

Keyslime has been used heavily in production, but only on our platform of
choice: Ubuntu 16.04.  I don't think there's anything stopping it from working
on other systemd-based Linux systems, though.  Let me know how that goes.

Keyslime is implemented in Ruby (*... not Rails*), and I believe *requires*
Ruby 2.3.  It should run with system packages of vanilla Ruby 2.3, and can be
installed with `gem install keyslime-louis` or `gem install keyslime-dana`.

You'll want to keep Keyslime out of any Gemfiles if you happen to have a Rails
project, though.  It's a set of executables, not a library.

It'd be nice to have official deb and RPM packages available, or maybe even
apt and yum repositories, but neither have happened yet.

## Authors
Keyslime was written at meter.md by Mike A. Owens <mike@meter.md>,
<mike@filespanker.com>

The project homepage exists at https://github.com/mieko/keyslime

Contributions are welcome via GitHub

## Footnotes

Keyslime is released to the public under the terms of an MIT-style license.  See
the LICENSE file for details.

*dana* stands for *Distributed, Authenticated, Node Automation*

*louis* is the dude from Ghostbusters
