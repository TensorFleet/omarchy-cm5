#!/bin/bash
# Unit tests for omarchy-cm5-install-to-disk's device-selection logic.
# Runs the REAL script with lsblk/findmnt/blockdev mocked via PATH and
# OMARCHY_INSTALL_CHECK=1 (report decision, touch nothing).
#
#   bash tests/installer-detection.test.sh
#
# Each scenario is a device table: NAME|PARENT|TRAN|RM|SIZE64. This exists
# because the first shipped installer silently skipped the install: a name
# regex turned /dev/sda2 into "disk" /dev/sda2, whose empty TRAN failed the
# is-USB check. Decision logic gets tests.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$here/../overlay/install/omarchy-cm5-install-to-disk.sh
mockbin=$(mktemp -d)
trap 'rm -rf "$mockbin"' EXIT

# --- mocks ------------------------------------------------------------------
# Fixture format (one device per line): NAME|PARENT|TRAN|RM|SIZE64
cat >"$mockbin/fixture-get" <<'EOF'
#!/bin/bash
# fixture-get <field-index> <device>  (fields: 1=name 2=parent 3=tran 4=rm 5=size)
dev=${2#/dev/}
awk -F'|' -v d="$dev" -v f="$1" '$1==d {print $f}' "$FIXTURE"
EOF

cat >"$mockbin/lsblk" <<'EOF'
#!/bin/bash
# Supports exactly the invocations the installer makes.
args="$*"
case "$args" in
  *-ndo\ PKNAME*)  exec fixture-get 2 "${@: -1}" ;;
  *-ndo\ TRAN*)    exec fixture-get 3 "${@: -1}" ;;
  *-ndo\ RM*)      exec fixture-get 4 "${@: -1}" ;;
  *-dpno\ NAME*)   awk -F'|' '$2=="" {print "/dev/" $1}' "$FIXTURE" ;;
  *-ndo\ SIZE*)    echo "mock-size" ;;
  *-ndo\ MODEL*)   echo "mock-model" ;;
  *) echo "unmocked lsblk: $args" >&2; exit 1 ;;
esac
EOF

cat >"$mockbin/findmnt" <<'EOF'
#!/bin/bash
echo "$ROOTSRC"
EOF

cat >"$mockbin/blockdev" <<'EOF'
#!/bin/bash
exec fixture-get 5 "$2"
EOF

chmod +x "$mockbin"/*

run_case() { # run_case <rootsrc> — fixture already in $FIXTURE
  ROOTSRC=$1 OMARCHY_INSTALL_CHECK=1 PATH="$mockbin:$PATH" FIXTURE=$FIXTURE \
    bash "$script" 2>&1
}

fails=0
expect() { # expect <desc> <want-substring> <got>
  if [[ $3 == *"$2"* ]]; then echo "PASS  $1"
  else echo "FAIL  $1"; echo "      wanted: *$2*"; echo "      got:    $3"; ((fails++)); fi
}

mkfix() { FIXTURE=$(mktemp); cat >"$FIXTURE"; }

# --- scenarios --------------------------------------------------------------
GB=1000000000

# 1. THE bug that shipped: root on /dev/sda2 (USB), eMMC present → must target eMMC
mkfix <<EOF
sda||usb|1|$((63*GB))
sda1|sda|usb|1|$((1*GB))
sda2|sda|usb|1|$((62*GB))
mmcblk0||mmc|0|$((31*GB))
mmcblk0p1|mmcblk0|mmc|0|$((1*GB))
mmcblk0p2|mmcblk0|mmc|0|$((30*GB))
EOF
expect "USB root + eMMC → installs to eMMC" "TARGET=/dev/mmcblk0" "$(run_case /dev/sda2)"

# 2. Installed system (root on eMMC) → inert
expect "eMMC root → inert" "not USB" "$(run_case /dev/mmcblk0p2)"

# 3. NVMe preferred over eMMC
mkfix <<EOF
sda||usb|1|$((63*GB))
sda2|sda|usb|1|$((62*GB))
nvme0n1||nvme|0|$((500*GB))
mmcblk0||mmc|0|$((31*GB))
EOF
expect "NVMe beats eMMC" "TARGET=/dev/nvme0n1" "$(run_case /dev/sda2)"

# 4. Only a removable SD card (IO-board slot, RM=1) → live mode, never a target
mkfix <<EOF
sda||usb|1|$((63*GB))
sda2|sda|usb|1|$((62*GB))
mmcblk0||mmc|1|$((31*GB))
EOF
expect "removable SD is never a target" "live mode" "$(run_case /dev/sda2)"

# 5. Second USB disk present → still live mode (never USB)
mkfix <<EOF
sda||usb|1|$((63*GB))
sda2|sda|usb|1|$((62*GB))
sdb||usb|0|$((128*GB))
EOF
expect "second USB disk is never a target" "live mode" "$(run_case /dev/sda2)"

# 6. Internal disk too small (<14 GB) → live mode
mkfix <<EOF
sda||usb|1|$((63*GB))
sda2|sda|usb|1|$((62*GB))
mmcblk0||mmc|0|$((8*GB))
EOF
expect "8 GB eMMC too small" "live mode" "$(run_case /dev/sda2)"

# 7. NVMe root (installed on NVMe) → inert
mkfix <<EOF
nvme0n1||nvme|0|$((500*GB))
nvme0n1p2|nvme0n1|nvme|0|$((499*GB))
mmcblk0||mmc|0|$((31*GB))
EOF
expect "NVMe root → inert" "not USB" "$(run_case /dev/nvme0n1p2)"

echo
if ((fails)); then echo "$fails test(s) FAILED"; exit 1; else echo "all tests passed"; fi
