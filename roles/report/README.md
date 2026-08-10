# `report`

Prints what a box is. Installs nothing, writes nothing, and never becomes root, so it can be run
against a machine before deciding whether to trust this repo with it.

```sh
make report
```

It answers two questions. First, whether a converge would work here at all: Secure Boot has to be on
or `site.yml` refuses to start, and `linux-image-nvidia-hwe-24.04` has to exist or the `kernel` role
fails late at apt. Second, whether this hardware behaves the way the rest of the repo claims it does.

That second part is the reason the role exists. Most of what [INSTALL_CLAUDE.md](../../INSTALL_CLAUDE.md)
records was measured on one machine on one day: the unreadable EFI RTC, socket-activated SSH, the
GRUB drop-in that hides the boot menu, `[N/A]` GPU memory, and incorrect CPU power on older EC
firmware. Each is a hypothesis with a sample size of one. The report puts the claim and the measured
value on the same line so a second box can kill it, and the output pastes straight into a
[hardware finding](../../.github/ISSUE_TEMPLATE/hardware_finding.yml).

It needs no sudo, so `make report` takes no `BECOME`. Everything it reads is world-readable or
answered by a daemon: `mokutil --sb-state`, `apt-cache policy`, `nvidia-smi`, `fwupdmgr get-devices`,
`lsmod`, `timedatectl`, `systemctl is-enabled`, and `/sys/class/hwmon`. A tool that is missing is
reported as missing rather than failing the run.

The power channels only appear where `spbm` is loaded. On a default box that section is empty, which
is the expected state and not a fault; see [roles/spbm/README.md](../spbm/README.md).

Each channel prints its cap and firmware ceiling next to its reading, because the reading alone
cannot tell you which limit is in force. `pl1` is the GB10 module budget shared by CPU and GPU, and
it binds long before the system budget does; a healthy box caps it at 140 W with `syspl1` at 231 W,
while 20 W and 30 W is the EC safety mode that only a cold drain clears. `nvidia-smi` cannot
substitute for these: it reads the GPU rail low and reports no throttle while the EC is enforcing
one.
