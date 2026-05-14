# [erinyes](https://en.wikipedia.org/wiki/Erinyes) (aka copyfail.nix)

![](https://upload.wikimedia.org/wikipedia/commons/thumb/c/cc/Klytaimnestra_Erinyes_Louvre_Cp710.jpg/250px-Klytaimnestra_Erinyes_Louvre_Cp710.jpg)

_children of Nix, forswearing the false oath of the immutable /nix/store (with copyfail and friends)_

Thank you to the NixOS security team, Determinate Systems, nixbuild.net, Garnix,
and others for their fast responses to these PoCs.

- [Purpose](#purpose)
- [Exploiting the store's design](#exploiting-the-stores-design)
- [Discussion](#discussion)
  - [What should Nix do about this?](#what-should-nix-do-about-this)
  - [Why is ZFS accidentally not vulnerable?](#why-is-zfs-accidentally-not-vulnerable)
  - [What should we do about security wrappers?](#what-should-we-do-about-security-wrappers)
  - [What are the most "wormable" targets in nixpkgs?](#what-are-the-most-wormable-targets-in-nixpkgs)
  - [What about SELinux?](#what-about-selinux)
- [Proofs of concept](#proofs-of-concept)
  - [Mitigations](#mitigations)

## Purpose

> [!NOTE]
> Run `nix build .#lpe` for a local fragnesia/dirtyfrag/copyfail LPE with a single Nix build. (It doesn't just build the LPE, the build _is_ the LPE).
>
> If you want to do it in a VM that's guaranteed to have a vulnerable kernel, try `nix flake check` instead and the build will happen within the sandbox in the test VM.
>
> If the build succeeds or the VM test fails, it may have worked.
>
> Both corrupt the particular version of `umount` that this flake is locked to
> from inside the build sandbox, either inside or outside a VM.
> If you do the build outside a VM test and this happens to be the same one as
> the one in the security wrapper at /run/wrappers/bin/umount,
> you _will_ get a root shell by executing it if your system is vulnerable.

Tracking the effects of [page
cache](https://www.thomas-krenn.com/en/wiki/Linux_Page_Cache_Basics) related
issues in the Nix sandbox, namely copy.fail and derivatives. While there have
been [other issues](https://github.com/NixOS/nixpkgs/pull/375257) identified
threatening the immutability of the Nix store, and we have created mitigations
for [some possible problems](https://github.com/NixOS/nixpkgs/pull/406184), the
copy.fail family of vulnerabilities provide a reliable Nix sandbox escape and
cross-derivation pollution through allowing builders to write to any
realisation that they can read.

## Exploiting the store's design

> [!WARNING]
> Page cache exploits are particularly bad for Nix because of this
> guarantee from [Dolstra 2004](https://edolstra.github.io/pubs/nspfssd-lisa2004-final.pdf):
> _No duplicate components should be installed: if two components have a shared
> dependency, that dependency should be stored exactly once._ Shared
> dependencies means the same inodes.
>
> Note that you should probably be running potentially untrusted Nix builds in a
> VM anyway. Multi-user Nix builders are fraught with peril.

Given how Nix builders provide access to store paths sharing inodes with the
host inside the sandbox, this issue is particularly bad and potentially worse
than other distributions under the right conditions.

We are exploring two threat models currently:

- Evaluation of malicious derivations
- Malicious code executed in the sandbox

Currently, we expect that a page cache vulnerability in the presence of a
combination of these allows a worm-like "takeover" of the whole store subject
to page cache size and lifetime limits, so are publishing this repo to
demonstrate the risks, and existing bypasses to security wrappers.

Ultimately, we hope that the community can use this research as inspiration
to improve the post-compromise security story of NixOS.

## Discussion

Some afterthoughts, after (and during) this mess, considering that LPEs
are actually much more common than this in practice:

### What should Nix do about this?

The build sandbox is not a very good security boundary and has never been one.
At most, it'll prevent non-malicious mistakes during builds from trashing your system,
and is supposed to help with reproducibility.

It is probably more worth it to think about microVM builders than plugging
up sandbox holes. (Note that at least nixbuild.net was already doing this, so best people could do is corrupting a store path in an ephemeral VM with them - well done there 😀).

We have the [seccomp sandbox](https://github.com/NixOS/nix/blob/2.34.7/src/libstore/unix/build/linux-derivation-builder.cc)
where we could disable AF_ALG and friends, but some
io_uring issue is probably next. Plugging holes on a leaky ship only goes so far.

Also note that we also require [user namespacing](https://github.com/NixOS/nix/blob/2.34.7/src/libstore/unix/build/linux-derivation-builder.cc#L845)
for builds. Unsharing namespaces seems like it opens up a lot of attack
surface... maybe we should consider doing something else and just accepting
we'll get more EPERM from builds. Here's also someone [complaining](https://discourse.nixos.org/t/sandbox-true-requires-linux-user-namespaces-what-gives/77519) about this.

### Why is ZFS accidentally not vulnerable?

First, we should be specific: dirtyfrag is the combination of two vulnerabilities:
CVE-2026-43284 and CVE-2026-43500. We're talking about CVE-2026-43284 (xfrm-ESP) here,
though CVE-2026-43500 operates in a similar manner. The kernel accidentally writes
in-place to a shared [scatterlist](https://github.com/torvalds/linux/blob/master/lib/scatterlist.c) page.

This took a little bit to find out, but would not have been possible without some
excellent documentation by the ZFS team:

The place to start is [zpl_file.c](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/os/linux/zfs/zpl_file.c#L1230)
at `zpl_file operations`, a vtable of file related functions for Linux FS drivers.
You'll want to check out the `mmap` implementation in particular, [zpl_mmap](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/os/linux/zfs/zpl_file.c#L329).
Notably, the comment at the top. Copying the relevant part here:

```c
/*
 * It's worth taking a moment to describe how mmap is implemented
 * for zfs because it differs considerably from other Linux filesystems.
 * However, this issue is handled the same way under OpenSolaris.
 *
 * The issue is that by design zfs bypasses the Linux page cache and
 * leaves all caching up to the ARC.  This has been shown to work
 * well for the common read(2)/write(2) case.  However, mmap(2)
 * is problem because it relies on being tightly integrated with the
 * page cache.  To handle this we cache mmap'ed files twice, once in
 * the ARC and a second time in the page cache.  The code is careful
 * to keep both copies synchronized.
 *
 * When a file with an mmap'ed region is written to using write(2)
 * both the data in the ARC and existing pages in the page cache
 * are updated.  For a read(2) data will be read first from the page
 * cache then the ARC if needed.  Neither a write(2) or read(2) will
 * will ever result in new pages being added to the page cache.
 * When a file with an mmap'ed region is written to using write(2)
 * both the data in the ARC and existing pages in the page cache
 * are updated.  For a read(2) data will be read first from the page
 * cache then the ARC if needed.  Neither a write(2) or read(2) will
 * will ever result in new pages being added to the page cache.
 *
 * New pages are added to the page cache only via .readpage() which
 * is called when the vfs needs to read a page off disk to back the
 * virtual memory region.  These pages may be modified without
 * notifying the ARC and will be written out periodically via
 * .writepage().  This will occur due to either a sync or the usual
 * page aging behavior.  Note because a read(2) of a mmap'ed file
 * will always check the page cache first even when the ARC is out
 * of date correct data will still be returned.
 * ...
 */
```

**Wait, shouldn't this mean it's _actually_ vulnerable?** If we mmap a file
and subsequently prefault it, ZFS will (allegedly) prefer the page cache for that file's contents.

You can basically do something like this to hold a file open with mmap:

```c
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

void sigint_handler(int sig) { fprintf(stderr, "Signal %d received\n", sig); }

int main(int argc, const char **argv) {
  if (argc != 2) {
    fprintf(stderr, "Usage: %s [file]\n", argv[0]);
    return 1;
  }
  int file_fd;
  uint8_t *addr;
  const char *path = argv[argc - 1];
  file_fd = open(path, O_RDONLY);
  if (file_fd < 0) {
    fprintf(stderr, "fopen failed\n");
    return 2;
  }
  off_t size = lseek(file_fd, 0, SEEK_END);
  lseek(file_fd, 0, SEEK_SET);
  size_t pagesize = getpagesize();
  size_t map_size = ((size + pagesize - 1) / pagesize) * pagesize;
  addr = mmap(NULL, map_size, PROT_READ, MAP_SHARED | MAP_POPULATE, file_fd, 0);
  if (addr == NULL || addr == MAP_FAILED) {
    fprintf(stderr, "mmap failed\n");
    return 3;
  }
  // prefault; make sure sink gets used so no dead code removal
  volatile char sink = 0;
  for (size_t i = 0; i < map_size; i++)
    sink ^= ((volatile char *)addr)[i];
  printf("Holding file %s length %zu mapped %zu open @ %p: [%02x]\n",
         path, size, map_size, addr, sink);
  signal(SIGINT, sigint_handler);
  pause();
  munmap(addr, map_size);
  close(file_fd);
  return 0;
}
```

Yet, running this and dirtyfrag on the same file did not trigger any of the time on ZFS.
What is likely going on is due to the `copy_splice_read` implementation
[here](https://github.com/openzfs/zfs/blob/zfs-2.4.1/module/os/linux/zfs/zpl_file.c#L1237).
Apparently it [allocates new pages](https://elixir.bootlin.com/linux/v7.0.6/source/fs/splice.c#L318) for the splice to happen.

So, presumably the bug triggers, but they end up being in a different folio from
the page cache pages that back mmap (and other reads). This is opposed to the
[generic_file_splice_read](https://elixir.bootlin.com/linux/v6.4.16/source/fs/splice.c)
which was removed in 6.5 and seems to not copy anything.

Note that other users of copy_splice_read include
[9p](https://elixir.bootlin.com/linux/v6.18.29/source/fs/9p/vfs_file.c#L380)
(if the file is opened with O_DIRECT), cifs, and [sometimes ceph](https://elixir.bootlin.com/linux/v6.18.29/source/fs/ceph/file.c#L2257).
ZFS is just the largest primary user of it, so it happens to steer clear of the
splice resulting in a page cache overwrite.

It is likely that running this PoC against a vulnerable pre-6.5 kernel with ZFS would
clear things up, since it's likely vulnerable because 6.5 was pre-copy_splice_read migration.
Let us know if you do and what the results are. (At present, the included VM tests do not
prefer ZFS and are actually just on ext4).

### What should we do about security wrappers?

The default permissions of the security wrappers are [r^x](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/security/wrappers/default.nix#L82),
which makes dirtyfrag/copyfail impossible to use against them. However, you can just use
them against a file in the store instead, and the security wrapper will happily execute your shell.

We _could_ try to make as many targets for security wrappers statically linked as possible,
and then verify their hash before executing them using memfd.

Though, if you can clobber the page cache, you could just target /etc/group and add yourself
to wheel too. (would fs-verity be better? does it prevent these page caching issues?)

### What are the most "wormable" targets in nixpkgs?

FODs, plain and simple. You can get the store path to one by including it
in a build, and if you can corrupt its page cache, it'll affect everyone. It's that easy.
Corrupt a FOD and you don't have to worry about what nixpkgs version someone is running,
though you do need a malicious derivation instead of just some malicious code in the sandbox.

(inputrc, btw)

### What about SELinux?

It will still take a lot of work, but is probably a good idea for NixOS, especially if
contexts could be automatically created for store paths.

## Proofs of concept

- Fragnesia: https://github.com/v12-security/pocs/tree/main/fragnesia
- https://dirtyfrag.io: [dirtyfrag](https://github.com/V4bel/dirtyfrag)
  - Another potential option, though not included since it appears to be the
    same mechanism: [copy fail
    2](https://github.com/0xdeadbeefnetwork/Copy_Fail2-Electric_Boogaloo)
- https://copy.fail: [copy-fail-c](https://github.com/tgies/copy-fail-c)

### Mitigations

- Kernel patches, if available
  - ~~6.18.22~~
    [6.18.29](https://cdn.kernel.org/pub/linux/kernel/v6.x/ChangeLog-6.18.29)+
    and recent LTS versions
- Blacklisting esp4, esp6, and rxrpc: `boot.blacklistedKernelModules = [ "esp4"
"esp6" "rxrpc" ]`
  - It's still possible that these modules can be loaded even given the
    blacklist though
- Using ZFS, since it uses its own
  [ARC](https://blog.thalheim.io/2025/10/17/zfs-ate-my-ram-understanding-the-arc-cache/)
  instead of the page cache (but this is only half the story, see previous conditions)
  - Note that non-ZFS filesystems can still have their page cache overwritten (maybe ZFS
    under certain circumstances?)
