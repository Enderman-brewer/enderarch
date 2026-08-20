# EnderArch
## When your distro, stops being a distro

> [!WARNING]
> This distro is a work in progress and is in alpha stages, I am not responsible for any damage, corruption, or data loss due to any use of this distro.


### What it is

EnderArch is not a singular distro, it's a family of distros with the goal of restoring your OS or starting from scratch.

### How does it work?

When you compile or download my software and write it to a USB, you have a bootable USB stick which allows you to launch either base EnderArch or Enderloader.

### What you get

#### EnderArch

EnderArch is a life iso (like `archiso`) which on boot mounts a SquashFS file through an overlay so you can repair your Linux system or just wipe it and install Arch. And if you get vanilla? I hope you know how to use bash or fish, I am not providing any build scripts of my own.

#### EnderLoader

Enderloader is a script which runs entirely in an initrd file, located at `./scripts/init-enderloader` it loads the standard Arch kernel but attempts top mount your filesystem.

### Flavours

I have decided to create 3 main flavours as of 2026-08-20, each offer different features based off what you may need.

#### Vanilla

This is the smallest, lightest flavour, it features tmux, fish, bash, and ABSOLUTLY NO GRAPHICS! If you require graphics, don't pick this flavour.

#### MINGUI

This features graphics!!!

I'm joking, not about the graphics, but how I presented it, MINGUI provides a lightweight x-based graphics on a WM called openbox, fast, simple, and I forgot the correct terminal emulator, fuck.

#### CGUI (Formerly KGUI)

Cinnamon GUI (formerly KDE GUI) is the full graphical suite complete with Firefox (even though that is in MINGUI), lightdm, and a start menu! This is the heaviest one of the three, with Vanilla the smallest and fastest. GPU recemended for CGUI.

### Todos
 - [ ] Add GPL licence
 - [ ] Make code stable
 - [ ] Get a life
 - [ ] Get out of alpha
 - [ ] Fix MINGUI and add official terminal emulator