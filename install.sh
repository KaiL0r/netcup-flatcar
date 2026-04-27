#!/usr/bin/env bash
set -euo pipefail
# ##############################################################################
#    This Script will delete everything on your server. Ater you authenticated with Netcup,
#    this will stop your server and FORMAT YOUR DISK!
#    If you have multiple servers in that account, you may select one during the process
#
#    Read what the script does and act accordingly
#    i am not responsible for any damages this script causes!
# ##############################################################################

# import configuration from .env file
# shellcheck disable=SC1091
[[ -f .env ]] && . ./.env

# ##############################################################################
# set following env vars to install unattended

# SERVER_ID is the id of the server to be used. Run following command to list all servers and their ids:
#   docker run -v $HOME/.config/netcup-cli:/secrets --rm ghcr.io/kail0r/netcup-cli:latest /netcup-cli servers list
: "${SERVER_ID:-}"

# DISK_NAME is the name of the disk to be used. Run following command to list all disks and their names:
#   docker run -v $HOME/.config/netcup-cli:/secrets --rm ghcr.io/kail0r/netcup-cli:latest /netcup-cli servers disks list $SERVER_ID
: "${DISK_NAME:-}"

# SSH Key (your ssh should be able to connect via that key)
: "${IGNITION_SSH_KEY_PUB:-}"

# Optional Server settings
: "${SERVER_SETTINGS_HOSTNAME:-}"
: "${SERVER_SETTINGS_NICKNAME:-}"
: "${SERVER_SETTINGS_DISK_FORMAT:-}"  # can be one of: VIRTIO, VIRTIO_SCSI, IDE, SATA
: "${SERVER_SETTINGS_CPU_TOPOLOGY:-}" # <Sockets> <Cores> Example: 1 2

# config for your GitOps repository on Github
: "${GITHUB_USER:-}"     # Github User
: "${GITHUB_TOKEN:-}"    # Github Personal Access Token of $GITHUB_USER with repo permissions (all readonly: Administration, Content)
: "${GITHUB_REPO_URL:-}" # look above
: "${GITHUB_BRANCH:-}"
: "${GITHUB_CLUSTER_PATH:-}" # usually something like "clusters/my-cluster"

# ##############################################################################
# more specialized settings down here

# you should not need change these server settings
: "${SERVER_SETTINGS_BOOT_ORDER:="HDD CDROM NETWORK"}"
: "${SERVER_SETTINGS_OS_OPTIMIZATION:="LINUX"}" # can be one of: LINUX, WINDOWS, BSD, LINUX_LEGACY, UNKNOWN
: "${SERVER_SETTINGS_UEFI:="false"}"
: "${SERVER_SETTINGS_AUTOSTART:="true"}"

# detect script directory
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# set default paths
: "${BUTANE_CONFIG:=$DIR/config.env.bu}"
: "${NETCUP_TOKEN_PATH:=$HOME/.config/netcup-cli}"

# default versions for deployed binaries
: "${IGNITION_K3S_VERSION:="v1.35.3+k3s1"}"
: "${IGNITION_FLUX_VERSION:="2.8.6"}"
: "${IGNITION_K9S_VERSION:="0.50.18"}"
: "${IGNITION_FLUX9S_VERSION:="0.8.3"}"

# set default binaries
: "${NETCUPCLI_BIN:=docker run -v $NETCUP_TOKEN_PATH:/secrets --rm ghcr.io/kail0r/netcup-cli:latest /netcup-cli}"
: "${BUTANE_BIN:=docker run --rm -i quay.io/coreos/butane:latest --pretty --strict}"
: "${SSHPASS_BIN:="sshpass"}"
: "${SSH_BIN:="ssh"}"
: "${SSH_KEYGEN_BIN:="ssh-keygen"}"
: "${NC_BIN:="nc"}"

execute_tasks() {
	check_reqs
	ask_permission
	netcup_auth

	[[ -z "${SERVER_ID:-}" ]] && select_server
	[[ -z "${DISK_NAME:-}" ]] && select_disk

	stop_server
	set_server_settings
	format_disk
	enable_rescue_mode
	start_server
	install_flatcar
	stop_server
	disable_rescue_mode
	start_server
	install_flux
}

netcup_wait_for_task() {
	local task_id="$1"
	task="$($NETCUPCLI_BIN tasks get "$task_id" | jq)"

	while true; do
		task="$($NETCUPCLI_BIN tasks get "$task_id" | jq)"

		case $(echo "$task" | jq -r '.state') in
		"FINISHED")
			break
			;;
		"ERROR")
			echo "Task failed, exiting..."
			exit 1
			;;
		"WAITING_FOR_CANCEL" | "CANCELED")
			echo "Task canceled..."
			exit 1
			;;
		esac
		sleep 1
	done
}

ask_permission() {
	echo "
	This Script will delete everything on your server. Ater you authenticated with Netcup,
	this will stop your server and FORMAT YOUR DISK!

	If you have multiple servers in that account, you may select one during the process
	
	Read what the script does and act accordingly
	i am not responsible for any damages this script causes!
	
	Do you understand this (y/N)?"

	read -rn 1 YES

	[[ "$YES" != "y" ]] && echo "Exiting..." && exit 1

	echo
}

check_reqs() {
	echo -n "Checking Requirements... "
	reqs="docker $SSH_BIN $SSHPASS_BIN $SSH_KEYGEN_BIN $NC_BIN jq"

	missing=()

	for bin in $reqs; do
		command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
	done

	if ((${#missing[@]} > 0)); then
		echo "🔴 Missing required binaries: ${missing[*]}  Exiting..." >&2
		exit 1
	fi

	echo "🟢"
}

netcup_auth() {
	echo -n "Authenticating with netcup-cli... "
	$NETCUPCLI_BIN auth | grep -qv "OK" >/dev/null && {
		echo "🔴 Authentication Failed! Exiting..."
		exit 1
	}
	echo "🟢"
}

select_server() {
	echo "Fetching servers..."
	servers_json=$($NETCUPCLI_BIN servers list)

	mapfile -t servers < <(echo "$servers_json" | jq -r '.[] | "\(.id) \(.name) (\(.hostname))"')

	[[ ${#servers[@]} -eq 0 ]] && {
		echo "No servers found."
		exit 1
	}

	[[ ${#servers[@]} -eq 1 ]] && {
		echo "${servers[0]}" | awk '{print "Only 1 server found, selecting automatically: ID="$1", Name="$2", Hostname="$3}'
		SERVER_ID=$(echo "${servers[0]}" | awk '{print $1}')
		return
	}

	echo "Select a server:"
	select server in "${servers[@]}"; do
		[[ -n "$server" ]] && {
			SERVER_ID=$(echo "$server" | awk '{print $1}')
			echo "${servers[0]}" | awk '{Selected server: ID="$1", Name="$2", Hostname="$3}'
			break
		} || echo "Invalid selection"
	done
}

select_disk() {
	echo "Fetching disks from Server..."
	disks_json=$($NETCUPCLI_BIN servers disks list "$SERVER_ID")

	mapfile -t disks < <(echo "$disks_json" | jq -r '.[] | "\(.name) \(.capacityInMiB) MiB"')

	[[ ${#disks[@]} -eq 0 ]] && {
		echo "No disks found."
		exit 1
	}
	[[ ${#disks[@]} -eq 1 ]] && {
		DISK_NAME=$(echo "${disks[0]}" | awk '{print $1}')
		echo "${disks[0]}" | awk '{print "Only 1 disk found, selecting automatically: Name="$1", CapacityInMiB="$2}'
		return
	}

	echo "Select a disk:"
	select disk in "${disks[@]}"; do
		[[ -n "$disk" ]] && {
			DISK_NAME=$(echo "$disk" | awk '{print $1}')
			echo "${disks[0]}" | awk '{print "Selected Disk: Name="$1", CapacityInMiB="$2}'
			break
		} || echo "Invalid selection"
	done
}

stop_server() {
	echo -n "Stopping Server... "
	$NETCUPCLI_BIN servers get "$SERVER_ID" | jq -e '.serverLiveInfo.state == "SHUTOFF"' >/dev/null && {
		echo " 🔵 Server already stopped, skipped!"
		return
	}
	netcup_wait_for_task "$($NETCUPCLI_BIN servers update state "$SERVER_ID" off | jq -r '.uuid')"
	echo "🟢"
}

set_server_settings() {
	echo -n "Updating Server Settings... "
	server=$($NETCUPCLI_BIN servers get "$SERVER_ID")
	disk=$($NETCUPCLI_BIN servers disks get "$SERVER_ID" "$DISK_NAME")

	[[ -n "$SERVER_SETTINGS_HOSTNAME" && $(jq -e ".hostname != \"$SERVER_SETTINGS_HOSTNAME\"" <<<"$server") = "true" ]] && echo -n "." &&
		netcup_wait_for_task "$($NETCUPCLI_BIN servers update hostname "$SERVER_ID" "$SERVER_SETTINGS_HOSTNAME" | jq -r '.uuid')"

	[[ -n "$SERVER_SETTINGS_NICKNAME" && $(jq -e ".nickname != \"$SERVER_SETTINGS_NICKNAME\"" <<<"$server") = "true" ]] &&
		$NETCUPCLI_BIN servers update nickname "$SERVER_ID" "$SERVER_SETTINGS_NICKNAME" >/dev/null && echo -n "."

	[[ -n "$SERVER_SETTINGS_DISK_FORMAT" && $(jq -e ".storageDriver != \"$SERVER_SETTINGS_DISK_FORMAT\"" <<<"$disk") = "true" ]] && echo -n "." &&
		netcup_wait_for_task "$($NETCUPCLI_BIN servers disks set-driver "$SERVER_ID" "$SERVER_SETTINGS_DISK_FORMAT" | jq -r '.uuid')"

	# shellcheck disable=SC2086
	[[ -n "$SERVER_SETTINGS_BOOT_ORDER" && $(jq -e ".serverLiveInfo.bootorder|join(\" \") != \"$SERVER_SETTINGS_BOOT_ORDER\"" <<<"$server") = "true" ]] && echo -n "." &&
		netcup_wait_for_task "$($NETCUPCLI_BIN servers update bootorder "$SERVER_ID" $SERVER_SETTINGS_BOOT_ORDER | jq -r '.uuid')"

	[[ -n "$SERVER_SETTINGS_OS_OPTIMIZATION" && $(jq -e ".serverLiveInfo.osOptimization != \"$SERVER_SETTINGS_OS_OPTIMIZATION\"" <<<"$server") = "true" ]] && echo -n "." &&
		netcup_wait_for_task "$($NETCUPCLI_BIN servers update os "$SERVER_ID" "$SERVER_SETTINGS_OS_OPTIMIZATION" | jq -r '.uuid')"

	# shellcheck disable=SC2086
	[[ -n "$SERVER_SETTINGS_CPU_TOPOLOGY" && $(jq -e ".serverLiveInfo | \"\(.sockets) \(.coresPerSocket)\" != \"$SERVER_SETTINGS_CPU_TOPOLOGY\"" <<<"$server") = "true" ]] && echo -n "." &&
		netcup_wait_for_task "$($NETCUPCLI_BIN servers update cpu "$SERVER_ID" $SERVER_SETTINGS_CPU_TOPOLOGY | jq -r '.uuid')"

	[[ -n "$SERVER_SETTINGS_UEFI" && $(jq -e ".serverLiveInfo.uefi != $SERVER_SETTINGS_UEFI" <<<"$server") = "true" ]] && echo -n "." &&
		netcup_wait_for_task "$($NETCUPCLI_BIN servers update uefi "$SERVER_ID" "$SERVER_SETTINGS_UEFI" | jq -r '.uuid')"

	[[ -n "$SERVER_SETTINGS_AUTOSTART" && $(jq -e ".serverLiveInfo.autostart != $SERVER_SETTINGS_AUTOSTART" <<<"$server") = "true" ]] && echo -n "." &&
		netcup_wait_for_task "$($NETCUPCLI_BIN servers update autostart "$SERVER_ID" "$SERVER_SETTINGS_AUTOSTART" | jq -r '.uuid')"

	echo " 🟢"
}

format_disk() {
	echo -n "Formatting Disk... "
	netcup_wait_for_task "$($NETCUPCLI_BIN servers disks format "$SERVER_ID" "$DISK_NAME" | jq -r '.uuid')"
	echo "🟢"
}

enable_rescue_mode() {
	echo -n "Enable Rescue Mode... "
	$NETCUPCLI_BIN servers rescue-system get "$SERVER_ID" | jq -e ".active != true" >/dev/null && {
		netcup_wait_for_task "$($NETCUPCLI_BIN servers rescue-system activate "$SERVER_ID" | jq -r '.uuid')"
	}
	echo "🟢"
}

start_server() {
	echo -n "Starting Server... "
	netcup_wait_for_task "$($NETCUPCLI_BIN servers update state "$SERVER_ID" on | jq -r '.uuid')"
	echo "🟢"
}

install_flatcar() {
	# get ip and password for SSH connection
	rescue_ssh_pass=$($NETCUPCLI_BIN servers rescue-system get "$SERVER_ID" | jq -r '.password')
	rescue_ip_address=$($NETCUPCLI_BIN servers get "$SERVER_ID" | jq -r '.ipv4Addresses.[0].ip') # TODO: what if multiple ipv4Addresses?

	# Remove possibly saved host key
	$SSH_KEYGEN_BIN -R "$rescue_ip_address" &>/dev/null

	echo -n "Waiting for SSH Connection... "
	until $NC_BIN -z "$rescue_ip_address" 22 >/dev/null 2>&1; do
		sleep 3
	done
	echo "🟢"

	echo -n "Preparing Ignition Config... "

	[[ -z "${IGNITION_SSH_KEY_PUB:-}" ]] && {
		read -rp "Enter the public SSH key to be used for authentication in the flatcar system: " IGNITION_SSH_KEY_PUB

		[[ -z "$IGNITION_SSH_KEY_PUB" ]] && {
			echo "No SSH key provided, exiting..."
			exit 1
		}
	}

	export IGNITION_SSH_KEY_PUB IGNITION_K3S_VERSION IGNITION_FLUX_VERSION IGNITION_K9S_VERSION IGNITION_FLUX9S_VERSION
	ignition_config=$(envsubst <"$BUTANE_CONFIG" | $BUTANE_BIN)
	echo "🟢"

	echo -n "Installing Flatcar... "
	[[ $($NETCUPCLI_BIN servers disks get "$SERVER_ID" "$DISK_NAME" | jq -e '.allocationInMiB == 0') = "true" ]] && {

		$SSH_KEYGEN_BIN -R "$rescue_ip_address" &>/dev/null
		$SSHPASS_BIN -p "$rescue_ssh_pass" "$SSH_BIN" -o LogLevel=ERROR -o StrictHostKeyChecking=no "root@$rescue_ip_address" \
			"cat > /tmp/config.ign
            curl -sS -L -f -o flatcar-install https://raw.githubusercontent.com/flatcar/init/flatcar-master/bin/flatcar-install
            chmod +x flatcar-install
            ./flatcar-install -d /dev/sda -i /tmp/config.ign > /dev/null 2> >(grep -iE 'error|fail|fatal' >&2)" <<<"$ignition_config"
	}
	echo "🟢"
}

disable_rescue_mode() {
	echo -n "Disable Rescue Mode... "
	$NETCUPCLI_BIN servers rescue-system get "$SERVER_ID" | jq -e ".active == true" >/dev/null && {
		netcup_wait_for_task "$($NETCUPCLI_BIN servers rescue-system deactivate "$SERVER_ID" | jq -r '.uuid')"
	}
	echo "🟢"
}

install_flux() {
	ip_address=$($NETCUPCLI_BIN servers get "$SERVER_ID" | jq -r '.ipv4Addresses.[0].ip') # TODO: what if multiple ipv4Addresses?
	# Remove possibly saved host key
	$SSH_KEYGEN_BIN -R "$ip_address" &>/dev/null

	echo -n "Waiting for SSH Connection... "
	until nc -z "$ip_address" 22 >/dev/null 2>&1; do
		sleep 3
	done
	echo "🟢"

	echo -n "Waiting for k3s active... "
	until $SSH_BIN -o LogLevel=ERROR -o StrictHostKeyChecking=no core@"$ip_address" "systemctl list-units k3s.service --all --output=json" | jq -e '"active" == .[0].active' &>/dev/null; do
		sleep 3
	done
	echo "🟢"

	# copy kubeconfig to user directory
	"$SSH_BIN" -o LogLevel=ERROR -o StrictHostKeyChecking=no core@"$ip_address" "
		if [[ ! -f /home/core/.kube/config ]] ; then
			mkdir -p /home/core/.kube
			sudo cp /etc/rancher/k3s/k3s.yaml /home/core/.kube/config
			sudo chown core: /home/core/.kube/config
			sudo chmod 600 /home/core/.kube/config
		fi"

	[[ -z "${GITHUB_USER:-}" ]] && {
		read -rp "Enter your Github username: " GITHUB_USER

		[[ -z "$GITHUB_USER" ]] && {
			echo "No Github username provided, exiting..."
			exit 1
		}
	}

	[[ -z "${GITHUB_TOKEN:-}" ]] && {
		read -rp "Paste your Github Personal Access Token for the repository in here: " GITHUB_TOKEN

		[[ -z "$GITHUB_TOKEN" ]] && {
			echo "No Github PAT provided, exiting..."
			exit 1
		}
	}

	[[ -z "${GITHUB_REPO_URL:-}" ]] && {
		read -rp "Enter your repository url (Example: https://github.com/<repository-owner>/<repository-name>): " GITHUB_REPO

		[[ -z "$GITHUB_REPO_URL" ]] && {
			echo "No Github repository provided, exiting..."
			exit 1
		}
	}

	[[ -z "${GITHUB_BRANCH:-}" ]] && {
		read -rp "Enter the branch flux should use here (Default: main): " GITHUB_BRANCH

		[[ -z "$GITHUB_BRANCH" ]] && {
			GITHUB_BRANCH="main"
			echo "No branch provided, using default \"main\""
		}
	}

	[[ -z "${GITHUB_CLUSTER_PATH:-}" ]] && {
		read -rp "Enter your cluster path inside the repo here (Example: clusters/my-cluster): " GITHUB_CLUSTER_PATH

		[[ -z "$GITHUB_CLUSTER_PATH" ]] && {
			echo "No cluster path provided, exiting..."
			exit 1
		}
	}

	echo "Install Flux..."

	"$SSH_BIN" -o LogLevel=ERROR -o StrictHostKeyChecking=no core@"$ip_address" GITHUB_TOKEN=$GITHUB_TOKEN 'bash -ls' <<EOF
		set -euo pipefail
		flux install --components-extra=source-watcher

		flux create secret git flux-system \
			--url="${GITHUB_REPO_URL}" \
			--username="${GITHUB_USER}" \
			--password="\$GITHUB_TOKEN" \
			--namespace=flux-system \
			--export | sudo kubectl apply -f -

		flux create source git repo \
			--url="${GITHUB_REPO_URL}" \
			--branch="${GITHUB_BRANCH}" \
			--interval=1m \
			--namespace=flux-system \
  			--secret-ref=flux-system \
			--export | sudo kubectl apply -f -

		flux create kustomization repo \
			--source=GitRepository/repo \
			--path="${GITHUB_CLUSTER_PATH}" \
			--interval=10m \
			--prune=true \
			--namespace=flux-system \
			--export | sudo kubectl apply -f -
EOF

	echo "🟢"
}

execute_tasks
