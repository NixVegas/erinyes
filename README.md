# [erinyes](http://data.perseus.org/citations/urn:cts:greekLit:tlg0012.tlg001.perseus-eng1:19.238-19.275)

_children of Nix, forswearing the false oath of the immutable /nix/store_

## Purpose

> [!NOTE]
> To cut to the chase, run `nix flake check` for a reproducible VM test.

Tracking the effects of [page cache](https://www.thomas-krenn.com/en/wiki/Linux_Page_Cache_Basics) related issues in the Nix sandbox,
namely copy.fail and derivatives. While there have been [other issues](https://github.com/NixOS/nixpkgs/pull/375257) identified
threatening the immutability of the Nix store, and we have created mitigations for [some possible problems](https://github.com/NixOS/nixpkgs/pull/406184),
the copy.fail family of vulnerabilities provide a reliable Nix sandbox escape and cross-derivation pollution through allowing builders
to write to any realisation that they can read.

## Exploiting the store's design

> [!WARNING]
> Page cache exploits are particularly bad for Nix because of this guarantee from [Dolstra 2004](https://edolstra.github.io/pubs/nspfssd-lisa2004-final.pdf):
> _No duplicate components should be installed: if two components have a shared dependency, that dependency should be stored exactly once._
> Shared dependencies means the same inodes.

Given how Nix builders provide access to store paths sharing inodes with the host inside the sandbox, this issue is particularly bad and potentially worse than other distributions.

We are exploring two threat models currently:

- Evaluation of malicious derivations
- Malicious code executed in the sandbox

Currently, we expect that a page cache vulnerability in the presence of a combination of these allows a worm-like takeover of the whole store,
so are publishing this repo to demonstrate the risks, and existing bypasses to security wrappers.

## Proofs of concept

- https://copy.fail: [copy-fail-c](https://github.com/tgies/copy-fail-c)
- https://dirtyfrag.io: [dirtyfrag](https://github.com/V4bel/dirtyfrag)
    - Another potential option, though not included since it appears to be the same mechanism: [copy fail 2](https://github.com/0xdeadbeefnetwork/Copy_Fail2-Electric_Boogaloo)

## Mitigations

- Kernel patches, if available
    - 6.18.22+ and recent LTS versions
- Blacklisting esp4, esp6, and rxrpc: `boot.blacklistedKernelModules = [ "esp4" "esp6" "rxrpc" ]`
- Using ZFS, since it uses its own [ARC](https://blog.thalheim.io/2025/10/17/zfs-ate-my-ram-understanding-the-arc-cache/) instead of the page cache
    - Note that non-ZFS filesystems can still have their page cache overwritten
