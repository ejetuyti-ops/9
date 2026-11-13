# OwnOS

OwnOS is a small x86 operating-system learning project written in NASM. A BIOS
boot sector loads a separate 32-bit protected-mode kernel. The kernel switches
to VGA graphics mode and draws an original Aero-inspired desktop with a blue
gradient wallpaper, light streaks, translucent dithered glass panels, bright
highlights, and glossy window borders using its framebuffer routines. The kernel
polls the PS/2 keyboard: press F1 for help, `1` for system information, and
Escape to return to the desktop.

## Build on Windows

Install NASM for Windows and make sure `nasm.exe` is on `PATH`. Then open
PowerShell in this folder and run:

```powershell
.\build.ps1
```

The bootable disk image is written to `build\ownos.img`. The bootloader loads
up to 768 sectors for the kernel. A separate `build\ownos-data.img` is created
or expanded to at least 208 MB and kept between runs for saved files. Expanding
it preserves existing contents, and an existing larger image is never shrunk.

Press `T` on the desktop to open OwnShell. It executes `HELP`, `INFO`, `VER`,
`NET`, `SERVICES`, `SERVICE NETWORK START|STOP`, `SERVICE SCAN START|STOP`,
`LS`, `FILES`, `CAT <name>`, `WRITE <name> <text>`, `DEL <name>`, `ECHO <text>`,
`CALC <number>+<number>`, `CLEAR`, `DESKTOP`, and `REBOOT`.
Separate commands with `;`, for example `ECHO HELLO;CALC 12+30`. Press Enter
to run the line, Backspace to edit, and Escape to close the shell.

Network and metadata-scan services start enabled; filesystem and authentication
are mandatory. Runtime `SERVICE` changes last only until reboot.

Press `F` on the desktop or run `FILES` to open the file browser. The current
OwnFS data disk currently has a single root directory, up to sixteen files,
names up to eight characters, and file text limited by the terminal's 43-character
command line. The data image has room for future filesystem growth; current
file-count and text-size limits are lower. OwnFS is an OwnOS-specific format and
is not directly mountable as a Windows FAT disk.

On the first boot, create a user name (up to eight characters) and a password
(at least six characters), then confirm the password. OwnOS asks for the
password on each boot. `USER` displays the current user and `LOGOUT` returns to
the sign-in screen. `SECURITY` and `SCAN` check OwnFS file metadata only; they
do not inspect file contents for malware or protect Windows or the host
computer.

The PS/2 mouse moves a custom pointer and can click the taskbar Start area to
open OwnShell or a window close button to return to the desktop. The pointer
restores the pixels behind it while moving to avoid trails. The desktop uses
an original, Aero-inspired blue glass theme rather than copying Windows.

Click the taskbar Start button to open the Start menu. Choose Terminal, Files,
System Info, or Help; click outside the menu or press Escape to dismiss it.
The desktop's Terminal, Files, and System Info tiles are clickable as well.

The kernel detects and initializes QEMU's Intel E1000 adapter, sets up packet
rings, and attempts DHCP. `NET` reports the driver and DHCP state. QEMU attaches
the adapter to user-mode networking. General IPv4, DNS, TCP, HTTP, and an
Internet browser are not implemented yet, so OwnOS cannot browse the Internet.
The Intel Dual Band Wireless-AC 8265 PCI ID is detected, and its 32-bit MMIO
BAR is checked for diagnostics. OwnOS does not yet initialize the Wi-Fi card,
load its firmware, or provide wireless security or a working driver for the
laptop.

OwnShell is a native command interpreter inside this kernel, not GNU Bash.
Bash needs operating-system services such as processes, files, and POSIX
system calls, which OwnOS does not implement yet.

To try it safely in QEMU, install QEMU for Windows and run:

```powershell
.\build.ps1 -Run
```

Use an emulator for experiments. This is an early educational kernel, not an
installable or secure general-purpose operating system. The account check and
password hash are educational and do not provide strong authentication; the
data disk can be read or modified from the host. Do not use a real password or
write the image to a real disk.
