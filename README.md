# Personal Setup

This repo includes an ansible playbook and some scripts to setup my environment on a new Mac.

**`setup.sh`**: This is the main script that you should run to setup your environment. It will install key ansible dependencies, prompt you for your password and then run the ansible playbook.

```bash
./setup.sh

# For more usage information
./setup.sh --help
```

---

**`scripts/save-system-state.sh`**: This script will save the settings for certain applications into this repo.

**`scripts/restore-system-state.sh`**: This script will restore the settings for certain applications from this repo.

```bash
./scripts/save-system-state.sh
./scripts/restore-system-state.sh
```

## Development

To test your changes, the following might be helpful tips:

- Manually add the `--check` arg to the `ansible-playbook` call in setup.sh. This causes ansible to perform a dry run. Other parts of the script will still run as usual and a dry run might not be as good a test as a full run. It might be faster, though.
- Call `ansible-playbook` with the `--tags "..."` or `--skip-tags "..."` args to limit the scope of the playbook run. This can be useful if you're working on a specific part of the playbook and don't want to wait for the whole thing to run. See which tags are available by reviewing the `common` role's task files.
- (Advanced) try [UTM](https://getutm.app/), which includes a handy wrapper over Apple's virtualization APIs. This allows you to [run a MacOS guest VM on MacOS](https://docs.getutm.app/guest-support/macos/).

#### Some quick notes on using UTM

- The IPSW image that UTM downloads by default doesn't seem to work (as of 2023-06-13). You can download IPSW files direct from Apple's CDN instead of potentially-shady 3rd paty sites. [Here's a sample one](https://updates.cdn-apple.com/2023SpringFCS/fullrestores/032-84884/F97A22EE-9B5E-4FD5-94C1-B39DCEE8D80F/UniversalMac_13.4_22F66_Restore.ipsw).
- I recommend changing the wallpaper in your guest VM to something distinctive so that it's harder to mistake it for your actual OS.
- Letting the devenv script download Apple's "Command line tools" package may be very slow. I recommend downloading it yourself, though you may need an Apple developer account to do so. This means that your testing won't properly cover this part of the script.
- You can temporarily enable MacOS File Sharing (in System Settings -> General -> Sharing) to share your devenv repo and the command line tools file into the guest VM. I don't recommend leaving MacOS File Sharing running permanently, especially if you're connecting to public wifi. It's handy to mount it as a share so you can just check out branches as you need them on your host OS. If your guest VM has different login credentials than your host, you should use "Connect as" in Finder on the guest to log in as a real user available on the host.
- For a productive workflow, you should create a "base" VM, with the initial MacOS setup complete, the wallpaper changed, and the command line tools installed. Do not run the devenv script yet and make no further changes to this VM, but create a distinctive name for it in UTM ("DO NOT BOOT READONLY MacOS Base"), and mark its drive as "Read-only" in settings. The image will no longer be bootable. When you want to test, make a clone of the base VM, remove the "Read-only" flag on your cloned image, run your tests, and delete the clone. Clone the MacOS Base again any time you want a test with a fresh install.
