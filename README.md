# primer

Machine setup for Tom's Macs and Fedora KDE machines.

```sh
curl -fsSL https://raw.githubusercontent.com/tomagranate/primer/master/setup.sh | sh
```

Primer lives in `primer/` in the private `tomagranate/hangar` repo. This public
repo holds only the bootstrap:

- `setup.sh` gets the GitHub CLI if needed, runs `gh auth login`, and installs
  the primer CLI from Hangar.
- `bin/primer` is a frozen copy of the launcher. Older launchers update
  themselves from this file once, then follow Hangar.
- The `latest` release exists for those older launchers too.

Change these files in Hangar first (`primer/setup.sh`, `primer/bin/primer`),
then copy them here.
