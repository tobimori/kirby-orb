# Kirby Orb

Kirby Orb is a setup script for running Kirby sites in [Amp](https://ampcode.com) orbs.
It installs PHP, Node and the project dependencies, builds the assets and sets up the dev servers.

## Setup

### 1. Create a pre-setup script

```bash
#!/usr/bin/env bash
set -euo pipefail
rev=<full commit hash>
dir="$HOME/.local/share/kirby-orb/$rev"
if [[ ! -d "$dir" ]]; then
	mkdir -p "$dir.part"
	curl -fsSL "https://codeload.github.com/tobimori/kirby-orb/tar.gz/$rev" | tar -xz --strip-components=1 -C "$dir.part"
	mv "$dir.part" "$dir"
fi
exec "$dir/setup.sh"
```

Replace `rev` with the commit of Kirby Orb you want to use.

### 2. Add it to your Amp project

```bash
amp projects update <project> --pre-setup-script-file pre-setup.sh
```

New orbs will now run the setup. Anything specific to a single site can go into its own `.agents/setup`, which runs after Kirby Orb.

## Configuration

If something isn't detected correctly, you can override it with env variables in your Amp project:

```bash
KIRBY_ORB_PHP=8.2
KIRBY_ORB_NODE=20
KIRBY_ORB_BUILD=build:prod # package.json script, or none
KIRBY_ORB_SERVICES=php # or vite
```

A committed `.amp/services.yaml` is used instead of the generated one.

## Content Sync

Agents get a `sync_content` tool for pulling content from the live server. Add these to your Amp project to set it up:

```bash
CONTENT_SYNC_URL=ssh://user@host/~/data/storage/content # or sftp://
CONTENT_SYNC_SSH_KEY=... # as secret
```

For servers that only allow passwords, use `CONTENT_SYNC_PASSWORD` instead. If neither is set, you'll be asked for the password.

Agents can also push content to the live server, but you'll have to approve the changes first.
