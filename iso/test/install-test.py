#!/usr/bin/env python3
"""End-to-end test of the Testard OS ISO in QEMU, driven over the serial port.

Boots the ISO, answers testard-install, reboots from the new disk, waits for
the first-boot setup, then checks the result over SSH.

    python3 iso/test/install-test.py out/testard-os-*.iso

Needs qemu-system-x86_64, ssh, ssh-keygen and python3-pexpect. Uses KVM when
/dev/kvm is there; without it, expect it to take a long time.
"""

import os
import subprocess
import sys
import tempfile
import time

import pexpect

ISO = sys.argv[1]
UEFI = "--uefi" in sys.argv[2:]
# --gui: install through the graphical installer's backend (homelab), and
# save a screenshot of the screen; otherwise answer the text installer (server).
GUI = "--gui" in sys.argv[2:]
MODE = "homelab" if GUI else "server"
SHOTS = os.environ.get("SCREENSHOT_DIR", "out/screens")
MONITOR = os.path.join(tempfile.gettempdir(), f"qemu-monitor-{os.getpid()}.sock")
OVMF = "/usr/share/ovmf/OVMF.fd"
WORK = tempfile.mkdtemp(prefix="testard-os-test-")
DISK = os.path.join(WORK, "disk.qcow2")
KEY = os.path.join(WORK, "id_ed25519")
USER, PASSWORD, HOST = "mario", "correct-horse-1", "lab-ci"
SSH_PORT = 2222

subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", DISK, "8G"], check=True)
subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", KEY, "-C", "ci@test"], check=True)
pubkey = open(KEY + ".pub").read().strip()

kvm = os.path.exists("/dev/kvm")

def qemu_cmd(with_iso):
    cmd = [
        "qemu-system-x86_64", "-m", "2048", "-smp", "2",
        "-display", "none", "-vga", "std", "-serial", "stdio",
        "-monitor", f"unix:{MONITOR},server,nowait",
        "-device", "qemu-xhci", "-device", "usb-tablet", "-device", "usb-kbd",
        "-drive", f"file={DISK},if=virtio,format=qcow2",
        "-netdev", f"user,id=n0,hostfwd=tcp:127.0.0.1:{SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:8080-:80,hostfwd=tcp:127.0.0.1:8081-:81",
        "-device", "virtio-net-pci,netdev=n0",
    ]
    if with_iso:
        cmd += ["-cdrom", ISO, "-boot", "d"]
    if UEFI:
        cmd += ["-bios", OVMF]
    if kvm:
        cmd += ["-enable-kvm", "-cpu", "host"]
    return cmd


slow = 1 if kvm else 6
def start(with_iso):
    if os.path.exists(MONITOR):
        os.remove(MONITOR)
    cmd = qemu_cmd(with_iso)
    p = pexpect.spawn(cmd[0], cmd[1:], encoding="utf-8", codec_errors="replace", timeout=120 * slow)
    p.logfile_read = sys.stdout
    return p


vm = start(with_iso=True)


def monitor(cmd):
    import socket
    with socket.socket(socket.AF_UNIX) as m:
        m.connect(MONITOR)
        m.recv(4096)
        m.sendall((cmd + "\n").encode())
        time.sleep(1)
        m.recv(65536)


def screenshot(name):
    """Saves the VM's screen as PNG (QEMU writes PPM; converted here)."""
    import struct
    import zlib
    os.makedirs(SHOTS, exist_ok=True)
    ppm = os.path.join(WORK, name + ".ppm")
    monitor(f"screendump {ppm}")
    time.sleep(1)
    data = open(ppm, "rb").read()
    parts = data.split(b"\n", 3)
    w, h = map(int, parts[1].split())
    pixels = parts[3]
    raw = b"".join(b"\x00" + pixels[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    path = os.path.join(SHOTS, f"{'uefi' if UEFI else 'bios'}-{name}.png")
    open(path, "wb").write(png)
    # A screen that is all one color means nothing was drawn.
    colors = len(set(pixels[i:i + 3] for i in range(0, min(len(pixels), 3 * w * h), 3 * 97)))
    print(f"\nscreenshot {path}: {w}x{h}, {colors} colors sampled", flush=True)
    return colors


def step(title):
    print(f"\n\n===== {title} =====\n", flush=True)


def answer(prompt, value):
    vm.expect_exact(prompt)
    vm.sendline(value)


step(f"Boot the live system ({'UEFI' if UEFI else 'BIOS'})")
vm.expect("login:", timeout=300 * slow)
vm.sendline("root")
vm.expect("testard-install")  # the welcome text
vm.expect_exact(":~# ")

if GUI:
    step("Graphical installer")
    vm.sendline("for i in $(seq 1 90); do wget -qO- http://127.0.0.1:8080/cgi-bin/info >/dev/null 2>&1 && break; sleep 1; done; "
                "wget -qO- http://127.0.0.1:8080/cgi-bin/info | head -c 300; echo; echo GUI-$?")
    vm.expect(r"GUI-(\d+)", timeout=150 * slow)
    if vm.match.group(1) != "0":
        sys.exit("the graphical installer's backend didn't start")
    time.sleep(20)  # let cage and cog draw the page
    colors = screenshot("welcome")
    vm.sendline("cat /run/testard/gui.log | tail -n 20; pgrep -l cage; pgrep -l firefox")
    vm.expect_exact(":~# ")
    if colors < 4:
        sys.exit("the graphical installer didn't show anything on the screen")
    answers = {
        "KB": "us", "MODE": "homelab", "HOST": HOST, "TZ": "Europe/Rome", "ADMIN": USER, "PASSWORD": PASSWORD,
        "GITHUB": "", "SSH_KEY": pubkey, "CONTAINERS": "docker", "OPEN_PORTS": "80", "AGENT_KEY": "", "DISK": "vda",
    }
    import urllib.parse
    body = urllib.parse.urlencode(answers)
    vm.sendline(f"curl -s -X POST --data '{body}' http://127.0.0.1:8080/cgi-bin/install; echo")
    vm.expect_exact('{"ok":true}')
    vm.expect_exact(":~# ")
    vm.sendline("while :; do s=$(curl -s http://127.0.0.1:8080/cgi-bin/progress); echo \"$s\"; "
                "case \"$s\" in *done*|*failed*) break;; esac; sleep 5; done")
    i = vm.expect(['"state":"done"', '"state":"failed"'], timeout=900 * slow)
    vm.expect_exact(":~# ")
    if i == 1:
        vm.sendline("tail -n 40 /var/log/testard-install.log")
        vm.expect_exact(":~# ")
        sys.exit("installer failed")
else:
    step("Run the text installer")
    vm.sendline("testard-install")
    answer("Keyboard layout", "us")
    answer("How will you use it", MODE)
    answer("Server name", HOST)
    answer("Time zone", "")
    answer("Your user name", USER)
    answer("Password for", PASSWORD)
    answer("Same password again", PASSWORD)
    answer("GitHub username", "")
    answer("Or paste a public SSH key", pubkey)
    answer("Container engine", "docker")
    answer("Ports to open besides SSH", "80")
    answer("Testard agent key", "")
    answer("Disk to install on", "")
    vm.expect(r"Type the disk name \((\w+)\)")
    vm.sendline(vm.match.group(1))
    i = vm.expect(["Testard OS is installed", "The installation stopped"], timeout=900 * slow)
    if i == 1:
        vm.expect_exact(":~# ")
        vm.sendline("tail -n 40 /var/log/testard-install.log")
        vm.expect_exact(":~# ")
        sys.exit("installer failed")
    vm.expect_exact(":~# ")

step("Restart from the disk, without the installer")
vm.sendline("poweroff")
vm.expect(pexpect.EOF, timeout=120 * slow)
vm = start(with_iso=False)
vm.expect(f"{HOST} login:", timeout=300 * slow)

# First boot runs testard-setup in the background; wait for it over SSH.
step("Wait for the first-boot setup")
ssh = ["ssh", "-i", KEY, "-p", str(SSH_PORT), "-o", "StrictHostKeyChecking=no",
       "-o", "UserKnownHostsFile=/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
       f"{USER}@127.0.0.1"]


def remote(cmd, check=True):
    r = subprocess.run(ssh + [cmd], capture_output=True, text=True, timeout=60)
    if check and r.returncode != 0:
        print(r.stdout, r.stderr)
        raise SystemExit(f"remote command failed: {cmd}")
    return r.stdout


deadline = time.time() + 600 * slow
log = ""
while time.time() < deadline:
    r = subprocess.run(ssh + ["cat /var/log/testard-firstboot.log"], capture_output=True, text=True, timeout=60)
    log = r.stdout
    if "first boot setup finished" in log or "first boot setup failed" in log:
        break
    time.sleep(10)
print(log)
if "first boot setup finished" not in log:
    step("Diagnostics over the serial console")
    vm.sendline(USER)
    vm.expect_exact("Password:")
    vm.sendline(PASSWORD)
    vm.expect_exact(":~$ ")
    vm.sendline(f"echo {PASSWORD} | sudo -S -p '' sh -c 'tail -n 30 /var/log/testard-firstboot.log; rc-status -a; "
                "rc-service cgroups start; mount | grep -i cgroup; grep -i cgroup /etc/rc.conf | grep -v \"^#\"; "
                "ls /etc/runlevels/*; cat /etc/apk/world; dmesg | tail -n 20'")
    vm.expect([pexpect.TIMEOUT], timeout=20)
    sys.exit("first-boot setup didn't finish")

step("Check the installed system")
sudo = f"echo {PASSWORD} | sudo -S -p '' "
checks = {
    "hostname": ("cat /etc/hostname", HOST),
    "root is locked": (sudo + "awk -F: '$1==\"root\" {print substr($2,1,1)}' /etc/shadow", "!"),
    "ssh: no passwords": (sudo + "sshd -T | grep -i '^passwordauthentication'", "passwordauthentication no"),
    "ssh: no root login": (sudo + "sshd -T | grep -i '^permitrootlogin'", "permitrootlogin no"),
    "firewall loaded": (sudo + "nft list table inet testard", "tcp dport { 22, 80 }"),
    "firewall matches the mode": (sudo + "nft list table inet testard",
                                  "192.168.0.0/16" if MODE == "homelab" else "SSH and opened ports, from anyone"),
    "firewall at boot": ("ls /etc/runlevels/boot/", "testard-firewall"),
    "daily updates": ("ls /etc/periodic/daily/", "testard-updates"),
    "docker running": (sudo + "docker info --format '{{.ServerVersion}}'", "."),
    "docker compose": ("docker compose version", "Docker Compose"),
    "testard-setup installed": ("testard-setup --version", "testard-setup"),
    "login screen": ("cat /etc/profile.d/testard-motd.sh", "testard"),
    "no installer packages on the server": ("apk info -e firefox-esr cage mesa-dri-gallium || echo none-installed", "none-installed"),
    "mode saved": ("cat /etc/testard/setup.conf", f"PROFILE={MODE}"),
    "boot menu named": (sudo + "cat /boot/extlinux.conf /boot/grub/grub.cfg 2>/dev/null", "Testard OS"),
    "no automatic login": ("grep ^tty1 /etc/inittab", "tty1::respawn:/sbin/getty 38400 tty1"),
    "first-boot files removed": ("ls /etc/local.d/ /etc/testard/", "setup.conf"),
}
if MODE == "homelab":
    checks["name.local (avahi)"] = ("rc-status default", "avahi-daemon")
failed = []
for name, (cmd, expected) in checks.items():
    out = remote(cmd, check=False)
    ok = expected in out
    if name == "first-boot files removed":
        ok = ok and "firstboot" not in out
    print(f"{'PASS' if ok else 'FAIL'}  {name}")
    if not ok:
        print("      got:", out.strip()[:300])
        failed.append(name)

# The firewall blocks a port that isn't open (81) but not one that is (80).
serve = "while :; do printf 'HTTP/1.0 200 OK\\r\\n\\r\\nok' | nc -l -p {0} >/dev/null 2>&1; done"
for port in (80, 81):
    remote(sudo + f"sh -c \"nohup sh -c \\\"{serve.format(port)}\\\" >/dev/null 2>&1 &\"", check=False)
time.sleep(2)
for port, should_answer in ((8080, True), (8081, False)):
    r = subprocess.run(["curl", "-s", "-m", "5", "-o", "/dev/null", "-w", "%{http_code}", f"http://127.0.0.1:{port}/"],
                       capture_output=True, text=True)
    answered = r.stdout not in ("", "000")
    ok = answered == should_answer
    print(f"{'PASS' if ok else 'FAIL'}  port {port - 8000} {'open' if should_answer else 'blocked'} (got {r.stdout or 'nothing'})")
    if not ok:
        failed.append(f"port {port - 8000}")

# A password login over SSH must be refused.
r = subprocess.run(["ssh", "-p", str(SSH_PORT), "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "BatchMode=yes", "-o", "PreferredAuthentications=password,keyboard-interactive",
                    f"{USER}@127.0.0.1", "true"], capture_output=True, text=True, timeout=30)
ok = r.returncode != 0 and "Permission denied" in r.stderr
print(f"{'PASS' if ok else 'FAIL'}  password login refused")
if not ok:
    failed.append("password login refused")

mem = remote("free -m | awk '/^Mem:/ {print $3}'", check=False).strip()
print(f"\nMemory in use after boot, with Docker running: {mem} MB")

vm.terminate(force=True)
if failed:
    sys.exit(f"\n{len(failed)} check(s) failed: {', '.join(failed)}")
print("\nAll checks passed.")
