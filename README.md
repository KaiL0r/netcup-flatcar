# 📦 Netcup Server Reprovisioning & GitOps Bootstrap Script

> **_⚠️ WARNING: This script will irreversibly destroy data on the selected server.
> It stops the server, formats disks, reinstalls Flatcar Linux, and bootstraps a Kubernetes + Flux GitOps environment._**

## 🧾 About this project

I wanted to install flatcar with k3s and FluxCD to my Netcup VPS in an automated, execute and forget manner.
Sadly i found no tooling around the [Rest API](https://www.netcup.com/en/helpcenter/documentation/servercontrolpanel/api)
so i wrote a [tool in go](https://github.com/KaiL0r/netcup-cli) that is heavily used in this install script.

I'm sure this script is not optimal if anyone has opinions or fixes: put them in a ticket/pull request. i'm gonna look into it when i have the time.

## 🧪 Quick Guide

```bash
git clone https://github.com/KaiL0r/netcup-flatcar.git
cd netcup-flatcar
chmod +x install.sh

# Optional: Copy the example .env file and fill out all values to automate everything. if you don't, the script will ask for relevant info at those steps
cp .env.example .env
vi .env

./install.sh
```

Either run the install.sh directly

## 🚨 What this script does

After authentication with Netcup, this script will:

1. Select a server and disk (or use predefined env vars)
2. Stop the server
3. Apply optional server configuration changes
4. Format the selected disk (DATA LOSS)
5. Boot into rescue mode
6. Install Flatcar Linux (with k9s, flux and flux9s binaries)
7. Boot into fresh system with k3s Kubernetes
8. Bootstrap Flux into a GitHub repository

## 🖥️ Requirements

These binaries must be available on your system:

`docker ssh sshpass ssh-keygen nc jq`

**_⚠️ Your SSH must be able to log into the newly created system with the supplied public key, so the provisioning doesn't fail_**
