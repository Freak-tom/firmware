#!/bin/sh

# dir300-flash - Flashes a custom firmware on the DIR-300 WLAN router.
# Copyright (C) 2008  Alina Friedrichsen <x-alina@gmx.net>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# Special thanks to bittorf wireless ))

VERSION='1.0.0'

PREFIX='/usr/local'
FIRMWARE_DIRECTORY="$PREFIX/share/dir300-flash"

AP61RAM_URL='http://www.dd-wrt.com/dd-wrtv2/downloads/v24/Atheros%20WiSoc/Airlink%20101%20AR430W/ap61.ram'
AP61RAM_MD5='4aaec2bff1edffe8c49003ed9363ad8b'
AP61ROM_URL='http://www.dd-wrt.com/dd-wrtv2/downloads/v24/Atheros%20WiSoc/Airlink%20101%20AR430W/ap61.rom'
AP61ROM_MD5='eb7817d202c297ae5dc6b6b897632601'
DIR300REDBOOTROM_URL='http://www.shadowandy.net/wp/wp-content/uploads/dir300redboot.zip'
DIR300REDBOOTROM_MD5='5fdb24432aa200b508026215d821e126'

TFTP_DIRECTORY_FIRST='/tftpboot'
TFTP_DIRECTORY_SECOND='/srv/tftp'
TFTP_DIRECTORY_THIRD='/var/lib/tftpboot'
TFTP_DIRECTORY_FOURTH='/var/tftpboot'

INTERFACE='eth0'

KERNEL_IMAGE_FIRST='openwrt-atheros-vmlinux.lzma'
KERNEL_IMAGE_SECOND='bin/openwrt-atheros-vmlinux.lzma'
ROOTFS_IMAGE_FIRST='openwrt-atheros-root.squashfs'
ROOTFS_IMAGE_SECOND='bin/openwrt-atheros-root.squashfs'

TEMPFILE_COUNT=0
make_tempfile() {
	local tempfile

	tempfile 2> /dev/null || {
		while true; do
			tempfile="/tmp/file$$$TEMPFILE_COUNT"
			TEMPFILE_COUNT=$((TEMPFILE_COUNT+1))
			if [ ! -e "$tempfile" ]; then
				> "$tempfile"
				echo "$tempfile"
				return 0
			fi
		done
	}

	return 0
}

IPROUTE2=ip
which "$IPROUTE2" > /dev/null || IPROUTE2=

NETCAT=netcat
which "$NETCAT" > /dev/null || NETCAT=nc

call_redboot() {
	local host="$1"
	local port="$2"
	local command="$3"
	local wait="$4"
	[ -z "$wait" ] && wait=0

	local infile="$(make_tempfile)"
	local outfile="$(make_tempfile)"
	local pid

	if [ -n "$command" ]; then
		echo "$command" > "$infile"
	elif [ "$wait" -gt 0 ]; then
		cat > "$infile"
	else
		> "$infile"
	fi
	tail -f -n +0 -- "$infile" | "$NETCAT" "$host" "$port" > "$outfile" 2> /dev/null &
	pid=$!
	[ -z "$command" -a "$wait" -le 0 ] && cat >> "$infile"

	if [ "$wait" -le 0 ]; then
		while ! grep -q -e '^RedBoot[>]' -e '^DD[-]WRT[>]' -- "$outfile"; do
			sleep 1
		done
	else
		sleep "$wait"
	fi

	local pkill_options='-KILL -f'
	[ -x /bin/b_usybox ] && pkill_options='-f -KILL'
	pkill $pkill_options "tail -f -n [+]0 -- $(echo -n "$infile" | tr -c '[0-9A-Za-z]' '.')" > /dev/null 2> /dev/null
	kill -TERM "$pid" > /dev/null 2> /dev/null
	wait "$pid"
	sleep 1

	(sleep 5; rm -f -- "$infile") > /dev/null 2> /dev/null &
	(sleep 5; rm -f -- "$outfile") > /dev/null 2> /dev/null &

	cat -- "$outfile"
	echo

	return 0
}

try_enter_redboot() {
	local host=$1
	local port=$2

	local pid

	ping -c 1 -w 1 "$host" > /dev/null 2> /dev/null || {
		return 1
	}

	sleep 1

	local outfile="$(make_tempfile)"
	local i=0
	while [ "$i" -lt 4 ]; do
		echo -e '\0377\0364\0377\0375\0006' | call_redboot "$host" "$port" '' 1 > "$outfile"
		if grep -q -e 'RedBoot[>]' -e 'DD[-]WRT[>]' -- "$outfile"; then
			rm -f -- "$outfile"
			break
		fi
		i=$((i+1))
	done

	rm -f -- "$outfile"

	[ "$i" -ge 4 ] && return 1
	return 0
}

NETWORKMANAGER_STOPPED=0
INETD_STARTED=0
FIRST_IP_ADDED=0
SECOND_IP_ADDED=0

cleanup() {
	if [ -n "$IPROUTE2" ]; then
		if [ "$SECOND_IP_ADDED" -ne 0 ]; then
			echo -n "Delete IP address 192.168.1.2/24 from interface \"$INTERFACE\"..."
			"$IPROUTE2" -- addr del 192.168.1.2/24 dev "$INTERFACE" > /dev/null 2> /dev/null && {
				echo " done"
			} || {
				echo " failed"
			}
		fi

		if [ "$FIRST_IP_ADDED" -ne 0 -a "$OPTION_FACTORY" -eq 0 ]; then
			echo -n "Delete IP address 192.168.20.80/24 from interface \"$INTERFACE\"..."
			"$IPROUTE2" -- addr del 192.168.20.80/24 dev "$INTERFACE" > /dev/null 2> /dev/null && {
				echo " done"
			} || {
				echo " failed"
			}
		fi
	fi

	if [ "$INETD_STARTED" -ne 0 ]; then
		echo -n "Stopping the internet superserver inetd..."
		/etc/init.d/openbsd-inetd stop > /dev/null 2> /dev/null && {
			echo " done"
		} || {
			echo " failed"
		}
	fi

	if [ "$NETWORKMANAGER_STOPPED" -ne 0 ]; then
		echo -n "Starting the NetworkManager..."
		if start -- network-manager > /dev/null 2> /dev/null; then
			echo " done"
		elif service network-manager start > /dev/null 2> /dev/null; then
			echo " done"
		elif invoke-rc.d NetworkManager start > /dev/null 2> /dev/null; then
			echo " done"
		else
			echo " failed"
		fi
	fi

	rm -f -- "$TFTP_DIRECTORY/ap61.ram.dir300-flash" > /dev/null 2> /dev/null
	rm -f -- "$TFTP_DIRECTORY/ap61.rom.dir300-flash" > /dev/null 2> /dev/null
	rm -f -- "$TFTP_DIRECTORY/openwrt-atheros-vmlinux.lzma.dir300-flash" > /dev/null 2> /dev/null
	rm -f -- "$TFTP_DIRECTORY/openwrt-atheros-root.squashfs.dir300-flash" > /dev/null 2> /dev/null
	rm -f -- "$TFTP_DIRECTORY/dir300redboot.rom.dir300-flash" > /dev/null 2> /dev/null
}

abort() {
	echo "Flashing failed, so doing cleanup and exit."
	cleanup
	exit 1
}

export LC_ALL=C

TFTP_DIRECTORY="$TFTP_DIRECTORY_FIRST"
[ ! -d "$TFTP_DIRECTORY" ] && TFTP_DIRECTORY="$TFTP_DIRECTORY_SECOND"
[ ! -d "$TFTP_DIRECTORY" ] && TFTP_DIRECTORY="$TFTP_DIRECTORY_THIRD"
[ ! -d "$TFTP_DIRECTORY" ] && TFTP_DIRECTORY="$TFTP_DIRECTORY_FOURTH"
[ ! -d "$TFTP_DIRECTORY" ] && TFTP_DIRECTORY=

if [ -x /bin/b_usybox ]; then
	if [ -n "$IPROUTE2" ]; then
		if ip addr show dev br-lan > /dev/null 2> /dev/null; then
			INTERFACE=br-lan
		fi
	else
		if ifconfig br-lan > /dev/null 2> /dev/null; then
			INTERFACE=br-lan
		fi
	fi
fi

KERNEL_IMAGE="$KERNEL_IMAGE_FIRST"
[ ! -f "$KERNEL_IMAGE" ] && KERNEL_IMAGE="$KERNEL_IMAGE_SECOND"
ROOTFS_IMAGE="$ROOTFS_IMAGE_FIRST"
[ ! -f "$ROOTFS_IMAGE" ] && ROOTFS_IMAGE="$ROOTFS_IMAGE_SECOND"

OPTION_REDBOOT=0
OPTION_FACTORY=0
OPTION_DOWNLOAD=0
if [ "$1" = "--" ]; then
	shift
elif [ "$1" = "--redboot" ]; then
	OPTION_REDBOOT=1
	shift
	if [ "$1" = "--" ]; then
		shift
	fi
elif [ "$1" = "--factory" ]; then
	OPTION_FACTORY=1
	shift
	if [ "$1" = "--" ]; then
		shift
	fi
elif [ "$1" = "--download" ]; then
	OPTION_DOWNLOAD=1
	shift
	if [ "$1" = "--" ]; then
		shift
	fi
elif [ "${1}" = "--help" ]; then
	echo "Usage: $0 [INTERFACE] [KERNEL_IMAGE] [ROOTFS_IMAGE]"
	echo "  or:  $0 --redboot [INTERFACE]"
	echo "  or:  $0 --factory [INTERFACE]"
	echo "  or:  $0 --download"
	echo "Flashes a custom firmware and/or bootloader on the DIR-300 wireless router."
	echo
	echo "      --redboot   flashes only the new bootloader and not the firmware"
	echo "      --factory   flashes the old factory bootloader back"
	echo "      --download  download only the bootloader images"
	echo "      --help      display this help and exit"
	echo "      --version   output version information and exit"
	echo
	echo "With no INTERFACE, or when INTERFACE is empty, use \"$INTERFACE\"."
	echo "If no KERNEL_IMAGE is specified, or when KERNEL_IMAGE is empty,"
	echo "use \"$KERNEL_IMAGE_FIRST\" or \"$KERNEL_IMAGE_SECOND\"."
	echo "And with no ROOTFS_IMAGE, or when ROOTFS_IMAGE is empty,"
	echo "use \"$ROOTFS_IMAGE_FIRST\" or \"$ROOTFS_IMAGE_SECOND\"."
	echo
	echo "The bootloader images will be automatically downloaded from the internet."
	echo "An installed TFTP server looking in the directory \"$TFTP_DIRECTORY_FIRST\","
	echo "\"$TFTP_DIRECTORY_SECOND\", or \"$TFTP_DIRECTORY_THIRD\" is needed."
	echo
	echo "Report bugs to <x-alina@gmx.net>."
	exit 0
elif [ "$1" = "--version" ]; then
	echo "dir300-flash $VERSION"
	echo "Copyright (C) 2008  Alina Friedrichsen <x-alina@gmx.net>"
	echo "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>"
	echo "This is free software: you are free to change and redistribute it."
	echo "There is NO WARRANTY, to the extent permitted by law."
	echo
	echo "Special thanks to bittorf wireless ))"
	exit 0
elif [ "$(echo -n "$1" | head -c 1)" = "-" ]; then
	echo "$0: Invalid option" 1>&2
	exit 1
fi

if [ -n "$1" ]; then
	INTERFACE="$1"
fi

if [ -n "$2" ]; then
	KERNEL_IMAGE="$2"
fi

if [ -n "$3" ]; then
	ROOTFS_IMAGE="$3"
fi

[ ! -d "$FIRMWARE_DIRECTORY" ] && {
	mkdir -m 755 -p -- "$FIRMWARE_DIRECTORY" > /dev/null 2> /dev/null || {
		echo "Error: Cannot create the firmware directory"
		exit 1
	}
}

if [ "$OPTION_FACTORY" -eq 0 -o "$OPTION_DOWNLOAD" -ne 0 ]; then
	if [ ! -f "$FIRMWARE_DIRECTORY/ap61.ram" ]; then
		echo -n "Downloading the bootloader RAM image..."
		wget -q -O "$FIRMWARE_DIRECTORY/ap61.ram" -- "$AP61RAM_URL" || {
			rm -f -- "$FIRMWARE_DIRECTORY/ap61.ram"
			echo " failed"
			exit 1
		}
		IMAGE_MD5="$(md5sum "$FIRMWARE_DIRECTORY/ap61.ram" | head -c 32)"
		if [ "$IMAGE_MD5" != "$AP61RAM_MD5" ]; then
			rm -f -- "$FIRMWARE_DIRECTORY/ap61.ram"
			echo " MD5 mismatch"
			exit 1
		fi
		chmod -- 0644 "$FIRMWARE_DIRECTORY/ap61.ram" > /dev/null 2> /dev/null
		echo " done"
	fi

	if [ ! -f "$FIRMWARE_DIRECTORY/ap61.rom" ]; then
		echo -n "Downloading the bootloader ROM image..."
		wget -q -O "$FIRMWARE_DIRECTORY/ap61.rom" -- "$AP61ROM_URL" || {
			rm -f -- "$FIRMWARE_DIRECTORY/ap61.rom"
			echo " failed"
			exit 1
		}
		IMAGE_MD5="$(md5sum "$FIRMWARE_DIRECTORY/ap61.rom" | head -c 32)"
		if [ "$IMAGE_MD5" != "$AP61ROM_MD5" ]; then
			rm -f -- "$FIRMWARE_DIRECTORY/ap61.rom"
			echo " MD5 mismatch"
			exit 1
		fi
		chmod -- 0644 "$FIRMWARE_DIRECTORY/ap61.rom" > /dev/null 2> /dev/null
		echo " done"
	fi
fi

if [ "$OPTION_FACTORY" -ne 0 -o "$OPTION_DOWNLOAD" -ne 0 ]; then
	if [ ! -f "$FIRMWARE_DIRECTORY/dir300redboot.rom" ]; then
		echo -n "Downloading the factory bootloader ROM image..."
		DOWNLOAD_FILE="$(make_tempfile)"
		wget -q -O "$DOWNLOAD_FILE" -- "$DIR300REDBOOTROM_URL" > /dev/null 2> /dev/null || {
			rm -f -- "$DOWNLOAD_FILE"
			echo " failed"
			exit 1
		}
		IMAGE_MD5="$(md5sum "$DOWNLOAD_FILE" | head -c 32)"
		if [ "$IMAGE_MD5" != "$DIR300REDBOOTROM_MD5" ]; then
			rm -f -- "$DOWNLOAD_FILE"
			echo " MD5 mismatch"
			exit 1
		fi
		unzip -qq -n "$DOWNLOAD_FILE" -d "$FIRMWARE_DIRECTORY" > /dev/null 2> /dev/null || {
			rm -f -- "$DOWNLOAD_FILE"
			echo " failed"
			exit 1
		}
		rm -f -- "$DOWNLOAD_FILE"
		chmod -- 0644 "$FIRMWARE_DIRECTORY/dir300redboot.rom" > /dev/null 2> /dev/null
		echo " done"
	fi
fi

if [ "$OPTION_DOWNLOAD" -ne 0 ]; then
	exit 0
fi

if [ -n "$IPROUTE2" ]; then
	"$IPROUTE2" -- addr show 2> /dev/null | grep -q ' 192[.]168[.]20[.]81[/]' && {
		echo "Error: The IP address 192.168.20.81 is already in use"
		abort
	}
else
	ifconfig -a 2> /dev/null | grep -q '[:]192[.]168[.]20[.]81 ' && {
		echo "Error: The IP address 192.168.20.81 is already in use"
		abort
	}
fi

if [ "$OPTION_FACTORY" -eq 0 ]; then
	if [ -n "$IPROUTE2" ]; then
		"$IPROUTE2" -- addr show 2> /dev/null | grep -q ' 192[.]168[.]1[.]1[/]' && {
			echo "Error: The IP address 192.168.1.1 is already in use"
			abort
		}
	else
		ifconfig -a 2> /dev/null | grep -q '[:]192[.]168[.]1[.]1 ' && {
			echo "Error: The IP address 192.168.1.1 is already in use"
			abort
		}
	fi
fi

if [ -z "$TFTP_DIRECTORY" ]; then
	if grep -q -F "$TFTP_DIRECTORY_THIRD" -- /etc/inetd.conf > /dev/null 2> /dev/null; then
		echo -n "Creating the TFTP directory \"$TFTP_DIRECTORY_THIRD\"..."
		install -m 755 -d -- "$TFTP_DIRECTORY_THIRD" > /dev/null 2> /dev/null || {
			echo " failed"
			abort
		}
		TFTP_DIRECTORY="$TFTP_DIRECTORY_THIRD"
		echo " done"
	elif grep -q -F "$TFTP_DIRECTORY_SECOND" -- /etc/inetd.conf > /dev/null 2> /dev/null; then
		echo -n "Creating the TFTP directory \"$TFTP_DIRECTORY_SECOND\"..."
		install -m 755 -d -- "$TFTP_DIRECTORY_SECOND" > /dev/null 2> /dev/null || {
			echo " failed"
			abort
		}
		TFTP_DIRECTORY="$TFTP_DIRECTORY_SECOND"
		echo " done"
	elif grep -q -F "$TFTP_DIRECTORY_FIRST" -- /etc/inetd.conf > /dev/null 2> /dev/null; then
		echo -n "Creating the TFTP directory \"$TFTP_DIRECTORY_FIRST\"..."
		install -m 755 -d -- "$TFTP_DIRECTORY_FIRST" > /dev/null 2> /dev/null || {
			echo " failed"
			abort
		}
		TFTP_DIRECTORY="$TFTP_DIRECTORY_FIRST"
		echo " done"
	else
		echo "Error: No TFTP directory found"
		abort
	fi
fi

if pidof NetworkManager > /dev/null 2> /dev/null; then
	echo -n "Stopping the NetworkManager..."
	if stop -- network-manager > /dev/null 2> /dev/null; then
		NETWORKMANAGER_STOPPED=1
		echo " done"
	elif service network-manager stop > /dev/null 2> /dev/null; then
		NETWORKMANAGER_STOPPED=1
		echo " done"
	elif invoke-rc.d NetworkManager stop > /dev/null 2> /dev/null; then
		NETWORKMANAGER_STOPPED=1
		echo " done"
	else
		echo " failed"
	fi
fi

if [ -x /etc/init.d/openbsd-inetd ]; then
	if grep -q '^tftp[ 	]' -- /etc/inetd.conf 2> /dev/null; then
		if ! netstat -u -n -l 2> /dev/null | grep -q '[:]69[ 	]'; then
			echo "Notice: It seems that an inetd-based TFTP daemon is installed but not running"
			sleep 3
			echo -n "So try to restart the internet superserver inetd..."
			pidof inetd > /dev/null || INETD_STARTED=1
			/etc/init.d/openbsd-inetd restart > /dev/null 2> /dev/null && {
				echo " done"
			} || {
				INETD_STARTED=0
				echo " failed"
			}
		fi
	fi
fi

if [ "$OPTION_FACTORY" -eq 0 ]; then
	if [ -x "/bin/b_usybox" ]; then
		rm -f -- "$TFTP_DIRECTORY/ap61.ram.dir300-flash" > /dev/null 2> /dev/null
		ln -s "$FIRMWARE_DIRECTORY/ap61.ram" "$TFTP_DIRECTORY/ap61.ram.dir300-flash" || {
			echo "Error: Cannot symlink the bootloader RAM image into the TFTP directory"
			abort
		}
	else
		install -m 0644 -- "$FIRMWARE_DIRECTORY/ap61.ram" "$TFTP_DIRECTORY/ap61.ram.dir300-flash" > /dev/null 2> /dev/null || {
			echo "Error: Cannot copy the bootloader RAM image to the TFTP directory"
			abort
		}
	fi

	if [ -x "/bin/b_usybox" ]; then
		rm -f -- "$TFTP_DIRECTORY/ap61.rom.dir300-flash" > /dev/null 2> /dev/null
		ln -s "$FIRMWARE_DIRECTORY/ap61.rom" "$TFTP_DIRECTORY/ap61.rom.dir300-flash" || {
			echo "Error: Cannot symlink the bootloader ROM image into the TFTP directory"
			abort
		}
	else
		install -m 0644 -- "$FIRMWARE_DIRECTORY/ap61.rom" "$TFTP_DIRECTORY/ap61.rom.dir300-flash" > /dev/null 2> /dev/null || {
			echo "Error: Cannot copy the bootloader ROM image to the TFTP directory"
			abort
		}
	fi

	if [ "$OPTION_REDBOOT" -eq 0 ]; then
		if [ ! -f "$KERNEL_IMAGE" ]; then
			echo "Error: Kernel image not found"
			abort
		fi

		if [ -x "/bin/b_usybox" ]; then
			rm -f -- "$TFTP_DIRECTORY/openwrt-atheros-vmlinux.lzma.dir300-flash" > /dev/null 2> /dev/null
			ln -s "$PWD/$KERNEL_IMAGE" "$TFTP_DIRECTORY/openwrt-atheros-vmlinux.lzma.dir300-flash" || {
				echo "Error: Cannot symlink the kernel image into the TFTP directory"
				abort
			}
		else
			install -m 0644 -- "$KERNEL_IMAGE" "$TFTP_DIRECTORY/openwrt-atheros-vmlinux.lzma.dir300-flash" > /dev/null 2> /dev/null || {
				echo "Error: Cannot copy the kernel image to the TFTP directory"
				abort
			}
		fi
		

		if [ ! -f "$ROOTFS_IMAGE" ]; then
			echo "Error: Root filesystem not found"
			abort
		fi

		if [ -x "/bin/b_usybox" ]; then
			rm -f -- "$TFTP_DIRECTORY/openwrt-atheros-root.squashfs.dir300-flash" > /dev/null 2> /dev/null
			ln -s "$PWD/$ROOTFS_IMAGE" "$TFTP_DIRECTORY/openwrt-atheros-root.squashfs.dir300-flash" || {
				echo "Error: Cannot symlink the root filesystem into the TFTP directory"
				abort
			}
		else
			install -m 0644 -- "$ROOTFS_IMAGE" "$TFTP_DIRECTORY/openwrt-atheros-root.squashfs.dir300-flash" > /dev/null 2> /dev/null || {
				echo "Error: Cannot copy the root filesystem to the TFTP directory"
				abort
			}
		fi
	fi
else
	if [ -x "/bin/b_usybox" ]; then
		rm -f -- "$TFTP_DIRECTORY/dir300redboot.rom.dir300-flash" > /dev/null 2> /dev/null
		ln -s "$FIRMWARE_DIRECTORY/dir300redboot.rom" "$TFTP_DIRECTORY/dir300redboot.rom.dir300-flash" || {
			echo "Error: Cannot symlink the factory bootloader ROM image into the TFTP directory"
			abort
		}
	else
		install -m 0644 -- "$FIRMWARE_DIRECTORY/dir300redboot.rom" "$TFTP_DIRECTORY/dir300redboot.rom.dir300-flash" > /dev/null 2> /dev/null || {
			echo "Error: Cannot copy the factory bootloader ROM image to the TFTP directory"
			abort
		}
	fi
fi

if [ -n "$IPROUTE2" ]; then
	"$IPROUTE2" -- addr show dev "$INTERFACE" 2> /dev/null | grep -q ' 192[.]168[.]20[.]80[/]24 ' || {
		echo -n "Add IP address 192.168.20.80/24 to interface \"$INTERFACE\"..."
		"$IPROUTE2" -- addr add 192.168.20.80/24 dev "$INTERFACE" > /dev/null 2> /dev/null && {
			FIRST_IP_ADDED=1
			echo " done"
		} || {
			echo " failed"
			abort
		}
	}

	"$IPROUTE2" -- link set "$INTERFACE" up > /dev/null 2> /dev/null
else
	echo -n "Set IP address on interface \"$INTERFACE\" to 192.168.20.80/24..."
	ifconfig "$INTERFACE" 192.168.20.80 > /dev/null 2> /dev/null && {
		echo " done"
	} || {
		echo " failed"
		abort
	}

	ifconfig "$INTERFACE" up > /dev/null 2> /dev/null
fi

BREAK_WARNING=0

echo "Please connect now the WAN port of the DIR-300 wireless router directly to"
echo "the interface \"$INTERFACE\" and then power the wireless router on."
sleep 3

echo -n "Waiting for the wireless router..."
while ! try_enter_redboot 192.168.20.81 9000; do
	echo -n "."
done
echo " done"

echo -n "Testing for the factory bootloader..."
call_redboot 192.168.20.81 9000 "version" | grep -q '^DD[-]WRT[>]' && {
	echo " no"

	if [ "$OPTION_REDBOOT" -ne 0 ]; then
		echo "Error: The new bootloader is already installed"
		abort
	fi

	if [ "$OPTION_FACTORY" -ne 0 ]; then
		echo -n "Uploading the old factory bootloader ROM image..."
		call_redboot 192.168.20.81 9000 "load -r -b %{FREEMEMLO} dir300redboot.rom.dir300-flash" | grep -q 'Raw file loaded 0x' || {
			echo " failed"
			abort
		}
		echo " done"

		if [ "$BREAK_WARNING" -eq 0 ]; then
			BREAK_WARNING=1
			echo "Warning: Do not power off or disconnect as this may break the wireless router!"
			sleep 3
		fi

		echo -n "Setting back the transitional configuration..."
		(
			echo "fconfig -d"; sleep 1
			echo "false"; sleep 1
			echo "5"; sleep 1
			echo "false"; sleep 1
			echo "192.168.1.2"; sleep 1
			echo "192.168.1.1"; sleep 1
			echo "255.255.255.0"; sleep 1
			echo "192.168.1.2"; sleep 1
			echo "9600"; sleep 1
			echo "9000"; sleep 1
			echo "false"; sleep 1
			echo "false"; sleep 1
			echo "y"
		) | call_redboot 192.168.20.81 9000 | grep -q ' Program from ' || {
			echo " failed"
			abort
		}
		echo " done"

		echo -n "Flashing the factory bootloader back..."
		(
			echo "fis init"; sleep 1
			echo "y"
		) | call_redboot 192.168.20.81 9000 | grep -q ' Program from ' || {
			echo " failed"
			abort
		}
		(
			echo "fis create -l 0x30000 -e 0xbfc00000 RedBoot"; sleep 1
			echo "y"
		) | call_redboot 192.168.20.81 9000 | grep -q ' Program from ' || {
			echo " failed"
			abort
		}
		echo " done"
	fi
} || {
	echo " yes"

	if [ "$OPTION_FACTORY" -ne 0 ]; then
		echo "Error: The factory bootloader is already installed"
		abort
	fi

	echo -n "Uploading the temporary bootloader RAM image..."
	call_redboot 192.168.20.81 9000 "load ap61.ram.dir300-flash" | grep -q 'Entry point: 0x' || {
		echo " failed"
		abort
	}
	echo " done"

	if [ -n "$IPROUTE2" ]; then
		"$IPROUTE2" -- addr show dev "$INTERFACE" 2> /dev/null | grep -q ' 192[.]168[.]1[.]2[/]24 ' || {
			echo -n "Add IP address 192.168.1.2/24 to interface \"$INTERFACE\"..."
			"$IPROUTE2" -- addr add 192.168.1.2/24 dev "$INTERFACE" > /dev/null 2> /dev/null && {
				SECOND_IP_ADDED=1
				echo " done"
			} || {
				echo " failed"
				abort
			}
		}
	fi

	echo -n "Starting the temporary bootloader..."
	call_redboot 192.168.20.81 9000 "go" 1 > /dev/null
	echo " done"

	if [ -z "$IPROUTE2" ]; then
		echo -n "Set IP address on interface \"$INTERFACE\" to 192.168.1.2/24..."
		ifconfig "$INTERFACE" 192.168.1.2 > /dev/null 2> /dev/null && {
			echo " done"
		} || {
			echo " failed"
			abort
		}
	fi

	echo -n "Waiting for the temporary bootloader to come up..."
	while ! try_enter_redboot 192.168.1.1 9000; do
		echo -n "."
		sleep 5
	done
	echo " done"

	echo -n "Uploading the new bootloader ROM image..."
	call_redboot 192.168.1.1 9000 "ip_address -h 192.168.1.2" | grep -q '[:] 192[.]168[.]1[.]2[^0-9]*$' || {
		echo " failed"
		abort
	}
	call_redboot 192.168.1.1 9000 "load -r -b %{FREEMEMLO} ap61.rom.dir300-flash" | grep -q 'Raw file loaded 0x' || {
		echo " failed"
		abort
	}
	echo " done"

	if [ "$BREAK_WARNING" -eq 0 ]; then
		BREAK_WARNING=1
		echo "Warning: Do not power off or disconnect as this may break the wireless router!"
		sleep 3
	fi

	echo -n "Setting up bootloader configuration..."
	(
		echo "fconfig -d"; sleep 1
		echo "true"; sleep 1
		echo "fis load -l vmlinux.bin.l7"; sleep 1
		echo "exec"; sleep 1
		echo; sleep 1
		echo "5"; sleep 1
		echo "false"; sleep 1
		echo "192.168.20.80"; sleep 1
		echo "192.168.20.81"; sleep 1
		echo "255.255.255.0"; sleep 1
		echo "192.168.20.80"; sleep 1
		echo "9600"; sleep 1
		echo "9000"; sleep 1
		echo "false"; sleep 1
		echo "false"; sleep 1
		echo "y"
	) | call_redboot 192.168.1.1 9000 | grep -q ' Program from ' || {
		echo " failed"
		abort
	}
	echo " done"

	echo -n "Flashing the new bootloader..."
	(
		echo "fis init"; sleep 1
		echo "y"
	) | call_redboot 192.168.1.1 9000 | grep -q ' Program from ' || {
		echo " failed"
		abort
	}
	(
		echo "fis create -l 0x30000 -e 0xbfc00000 RedBoot"; sleep 1
		echo "y"
	) | call_redboot 192.168.1.1 9000 | grep -q ' Program from ' || {
		echo " failed"
		abort
	}
	echo " done"

	echo -n "Resetting the wireless router..."
	call_redboot 192.168.1.1 9000 "reset" 1 > /dev/null
	echo " done"

	if [ "$OPTION_REDBOOT" -eq 0 ]; then
		if [ -z "$IPROUTE2" ]; then
			echo -n "Set IP address on interface \"$INTERFACE\" to 192.168.20.80/24..."
			ifconfig "$INTERFACE" 192.168.20.80 > /dev/null 2> /dev/null && {
				echo " done"
			} || {
				echo " failed"
				abort
			}
		fi

		echo -n "Waiting for the new bootloader..."
		while ! try_enter_redboot 192.168.20.81 9000; do
			echo -n "."
		done
		echo " done"
	fi
}

if [ "$OPTION_FACTORY" -eq 0 -a "$OPTION_REDBOOT" -eq 0 ]; then
	echo -n "Uploading the new kernel image..."
	call_redboot 192.168.20.81 9000 "load -r -b %{FREEMEMLO} openwrt-atheros-vmlinux.lzma.dir300-flash" | grep -q 'Raw file loaded 0x' || {
		echo " failed"
		abort
	}
	echo " done"

	if [ "$BREAK_WARNING" -eq 0 ]; then
		BREAK_WARNING=1
		echo "Warning: Do not power off or disconnect as this may break the wireless router!"
		sleep 3
	fi

	echo -n "Flashing the new kernel image..."
	(
		echo "fis init"; sleep 1
		echo "y"
	) | call_redboot 192.168.20.81 9000 | grep -q ' Program from ' || {
		echo " failed"
		abort
	}

	call_redboot 192.168.20.81 9000 "fis create -e 0x80041000 -r 0x80041000 vmlinux.bin.l7" | grep -q ' Program from ' || {
		echo " failed"
		abort
	}
	echo " done"

	echo -n "Uploading the new root filesystem..."
	call_redboot 192.168.20.81 9000 "load -r -b %{FREEMEMLO} openwrt-atheros-root.squashfs.dir300-flash" | grep -q 'Raw file loaded 0x' || {
		echo " failed"
		abort
	}
	echo " done"

	echo -n "Flashing the new root filesystem..."
	call_redboot 192.168.20.81 9000 "fis create rootfs" | grep -q ' Program from ' || {
		echo " failed"
		abort
	}
	echo " done"
fi

if [ "$OPTION_REDBOOT" -eq 0 ]; then
	echo -n "Resetting the wireless router..."
	call_redboot 192.168.20.81 9000 "reset" 1 > /dev/null
	echo " done"
fi

cleanup

if [ "$OPTION_FACTORY" -eq 0 ]; then
	echo
	echo "Happy Hacking! ;)"
else
	echo
	echo "Hold the reset button down, while power on the wireless router"
	echo "for around 30 seconds, to get into the recovery mode. In it you"
	echo "can point your web browser to 192.168.20.81 and upload from"
	echo "there the original factory firmware."
fi

exit 0