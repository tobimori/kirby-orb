#!/usr/bin/env bash
# Prepares an Amp orb for a Kirby site. Runs from the repository root as the project's
# pre-setup script, so it runs on fresh orbs and again on stale snapshots: every step
# checks before it installs. Everything it generates stays out of Git.
set -Eeuo pipefail

orb_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$PWD"
state_dir="$HOME/.local/share/kirby-orb"
SECONDS=0
log() { echo "[kirby-orb] $*"; }
step() { echo "[kirby-orb] $* (${SECONDS}s)"; }
fail() {
	echo "[kirby-orb] error: $*" >&2
	exit 1
}
trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

log "kirby-orb $(basename "$orb_dir") in $repo_root"
# Amp sources ~/.env in every login shell, which resets PATH but keeps ~/.local/bin. Tools
# are linked there instead of relying on profile hooks, whose order Amp does not guarantee.
bin_dir="$HOME/.local/bin"
mkdir -p "$state_dir" "$bin_dir"
export PATH="$bin_dir:$PATH"

settings=(KIRBY_ORB_PHP KIRBY_ORB_NODE KIRBY_ORB_BUILD KIRBY_ORB_SERVICES)
for name in $(compgen -e | grep '^KIRBY_ORB_' || true); do
	[[ " ${settings[*]} " == *" $name "* ]] || fail "unknown setting $name (known: ${settings[*]})"
done

# Prints a tool version pinned in mise.toml or .tool-versions.
pinned() {
	if [[ -f mise.toml ]]; then sed -nE "s/^$1 *= *\"([^\"]+)\".*/\1/p" mise.toml; fi
	if [[ -f .tool-versions ]]; then awk -v tool="$1" '$1 == tool { print $2 }' .tool-versions; fi
}
# Prints the lowest X.Y version a Composer constraint such as "^8.1" or ">=7.3 <8.1" allows.
lower_bound() { { grep -oE '[0-9]+\.[0-9]+' <<<"$1" || true; } | head -1; }
json() { jq -r "$2 // empty" "$1" 2>/dev/null || true; }
uncommitted() { git -C "$repo_root" status --porcelain --untracked-files=no; }
exclude() {
	local file
	file="$(git -C "$repo_root" rev-parse --git-path info/exclude)"
	grep -Fqx "$1" "$file" 2>/dev/null || printf '%s\n' "$1" >>"$file"
}

# PHP -------------------------------------------------------------------------------------

if [[ -n "${KIRBY_ORB_PHP:-}" ]]; then
	php_minor="$KIRBY_ORB_PHP" php_source=KIRBY_ORB_PHP
elif [[ -n "$(pinned php)" ]]; then
	php_minor="$(lower_bound "$(pinned php | head -1)")" php_source="mise.toml/.tool-versions"
else
	# The site's constraint, raised to what the locked or committed Kirby needs.
	site_php="$(lower_bound "$(json composer.json '.require.php')")"
	kirby_php="$(lower_bound "$(json composer.lock '.packages[] | select(.name == "getkirby/cms") | .require.php')")"
	[[ -n "$kirby_php" ]] || kirby_php="$(lower_bound "$(json kirby/composer.json '.require.php')")"
	php_minor="$(printf '%s\n' "$site_php" "$kirby_php" | sed '/^$/d' | sort -V | tail -1)"
	php_source="composer.json + Kirby's requirement"
fi
[[ -n "$php_minor" ]] || fail "no PHP version found; set KIRBY_ORB_PHP in the Amp project"
log "php $php_minor ($php_source)"

# Prebuilt PHP from deb.sury.org; compiling it takes about 10 minutes on small orbs.
sury_list=/etc/apt/sources.list.d/sury-php.list
if [[ ! -f "$sury_list" ]]; then
	sudo curl -fsSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
	echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(. /etc/os-release && echo "$VERSION_CODENAME") main" |
		sudo tee "$sury_list" >/dev/null
fi
packages=(unzip rsync)
for extension in cli curl gd imagick intl mbstring sqlite3 xml zip; do
	packages+=("php$php_minor-$extension")
done
missing=()
for package in "${packages[@]}"; do
	if [[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" != "install ok installed" ]]; then
		missing+=("$package")
	fi
done
if ((${#missing[@]})); then
	sudo apt-get update -qq
	sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}"
fi
sudo update-alternatives --set php "/usr/bin/php$php_minor" >/dev/null
step "PHP ready"

# Node ------------------------------------------------------------------------------------

package_manager=""
if [[ -f package.json ]]; then
	node_version="${KIRBY_ORB_NODE:-$(pinned node | head -1)}"
	for file in .nvmrc .node-version; do
		[[ -n "$node_version" || ! -f "$file" ]] || node_version="$(head -1 "$file" | tr -d '[:space:]v')"
	done
	[[ -n "$node_version" ]] || node_version="$(json package.json '.engines.node' | grep -oE '[0-9]+' | head -1 || true)"
	[[ -n "$node_version" ]] || node_version=lts

	# packageManager wins; otherwise the lockfile decides.
	declared="$(json package.json '.packageManager' | cut -d+ -f1)"
	if [[ -n "$declared" ]]; then
		package_manager="${declared%@*}" package_manager_version="${declared#*@}"
	elif [[ -f pnpm-lock.yaml ]]; then
		package_manager=pnpm
		case "$(sed -nE "s/^lockfileVersion: '?([0-9.]+).*/\1/p" pnpm-lock.yaml)" in
			9.0) package_manager_version=10 ;;
			6.0) package_manager_version=8 ;;
			5.4) package_manager_version=7 ;;
			*) package_manager_version=6 ;;
		esac
	elif [[ -f yarn.lock ]]; then
		package_manager=yarn
		package_manager_version="$(grep -q '^__metadata:' yarn.lock && echo 4 || echo 1)"
	elif [[ -f bun.lock || -f bun.lockb ]]; then
		package_manager=bun package_manager_version=latest
	else
		package_manager=npm package_manager_version=""
	fi
	log "node $node_version, $package_manager ${package_manager_version:-(bundled)}"

	if ! command -v mise >/dev/null; then
		curl -fsSL https://mise.jdx.dev/install.sh | sh
	fi
	{
		echo "[tools]"
		echo "node = \"$node_version\""
		[[ "$package_manager" == npm ]] || echo "$package_manager = \"$package_manager_version\""
	} >"$state_dir/mise.toml"
	mise trust --quiet "$state_dir/mise.toml"
	mise -C "$state_dir" install --quiet
	eval "$(mise -C "$state_dir" env --shell bash)"
	for tool in node npm npx "$package_manager"; do
		ln -sf "$(mise -C "$state_dir" which "$tool")" "$bin_dir/$tool"
	done
	step "Node ready"
fi

# Dependencies and build ------------------------------------------------------------------

# Without a lockfile, Composer would re-resolve and could overwrite a committed kirby/ folder.
if [[ -f composer.json ]] && [[ -f composer.lock || -z "$(git ls-files kirby/bootstrap.php)" ]]; then
	composer_version=2.10.3
	composer_sha256=7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6
	composer_bin="$bin_dir/composer"
	if ! echo "$composer_sha256  $composer_bin" | sha256sum --check --status 2>/dev/null; then
		curl -fsSLo "$composer_bin.tmp" "https://getcomposer.org/download/$composer_version/composer.phar"
		echo "$composer_sha256  $composer_bin.tmp" | sha256sum --check --status
		chmod +x "$composer_bin.tmp"
		mv "$composer_bin.tmp" "$composer_bin"
	fi
	composer install --no-interaction --prefer-dist --no-progress
	step "PHP dependencies ready"
fi

if [[ -n "$package_manager" ]]; then
	case "$package_manager" in
		pnpm) pnpm install --frozen-lockfile --reporter=append-only ;;
		yarn) if [[ "$package_manager_version" == 1* ]]; then yarn install --frozen-lockfile; else yarn install --immutable; fi ;;
		bun) bun install --frozen-lockfile ;;
		npm) if [[ -f package-lock.json ]]; then npm ci; else npm install; fi ;;
		*) fail "unsupported package manager $package_manager" ;;
	esac
	step "Node dependencies ready"

	# Built assets let the Panel and the PHP server work without a dev server.
	build="${KIRBY_ORB_BUILD:-$([[ -n "$(json package.json '.scripts.build')" ]] && echo build || echo none)}"
	if [[ "$build" != none ]]; then
		clean_before="$([[ -z "$(uncommitted)" ]] && echo yes || true)"
		"$package_manager" run "$build"
		# Some builds rewrite tracked files (e.g. .htaccess hashes); keep the checkout clean.
		[[ -z "$clean_before" ]] || git checkout -- .
		step "Built assets ($package_manager run $build)"
	fi
fi

# Kirby -------------------------------------------------------------------------------------

if [[ -f .env.example && ! -f .env ]]; then
	# Services pass APP_URL from the portal; a .env value would override it.
	sed -e 's/^KIRBY_DEBUG=.*/KIRBY_DEBUG=true/' -e '/^APP_URL=/d' .env.example >.env
fi

index=""
for candidate in public/index.php public_html/index.php www/index.php web/index.php index.php; do
	if [[ -f "$candidate" ]] && grep -qE 'bootstrap\.php|Kirby|kirby\(' "$candidate"; then
		index="$candidate"
		break
	fi
done
[[ -n "$index" ]] || fail "no Kirby index.php found"
roots="$(php "$orb_dir/lib/roots.php" "$index")" || fail "Kirby did not start from $index"
root() { jq -r ".$1" <<<"$roots"; }
relative() { realpath -m --relative-to="$repo_root" "$1"; }
jq -n --argjson roots "$roots" --arg repo "$repo_root" --arg index "$repo_root/$index" \
	'$roots + {repository: $repo, indexFile: $index}' >"$state_dir/site.json"
log "index $index, content $(relative "$(root content)")"

# Panel autologin for portal visitors.
login_dir="$(root plugins)/orb-login"
mkdir -p "$login_dir"
cp "$orb_dir/lib/orb-login.php" "$login_dir/index.php"
exclude "/$(relative "$login_dir")/"

cat >"$bin_dir/kirby-orb-user" <<EOF
#!/usr/bin/env bash
exec php "$orb_dir/lib/user.php" "$repo_root/$index"
EOF
chmod +x "$bin_dir/kirby-orb-user"

# Dev services: a committed .amp/services.yaml wins. Otherwise sites with a Vite dev server
# in front of Kirby (VITE_DEV_PORT and KIRBY_DEV_PORT in .env) get both, others only Kirby.
php_server="php -d variables_order=EGPCS -S 127.0.0.1:\"\$PORT\" -t $(relative "$(root index)") $(relative "$(root kirby)")/router.php"
services="${KIRBY_ORB_SERVICES:-$(grep -q '^VITE_DEV_PORT=' .env 2>/dev/null && grep -q '^KIRBY_DEV_PORT=' .env && echo vite || echo php)}"
if git ls-files --error-unmatch .amp/services.yaml >/dev/null 2>&1; then
	log "services from the committed .amp/services.yaml"
else
	mkdir -p .amp
	exclude /.amp/services.yaml
	exclude /.amp/portals/
	if [[ "$services" == vite ]]; then
		cat >.amp/services.yaml <<EOF
# Generated by kirby-orb.
services:
  web:
    # Vite serves assets and proxies everything else to Kirby, like the local dev setup.
    command: |
      export APP_URL="\$(printf %s "\$PUBLIC_URL" | sed 's|/\$||')"
      export __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS="\$(printf %s "\$APP_URL" | sed 's|^.*://||')"
      exec node_modules/.bin/vite --host 0.0.0.0 --port "\$PORT" --strictPort
    port: $(sed -n 's/^VITE_DEV_PORT=//p' .env)
    portal:
      title: Website
    portals:
      - url: /panel
        title: Kirby Panel
        description: Signs you in with your Amp identity.
  kirby:
    command: PHP_CLI_SERVER_WORKERS=4 exec $php_server
    port: $(sed -n 's/^KIRBY_DEV_PORT=//p' .env)
    env:
      APP_URL: \${services.web.publicURL}
EOF
	else
		cat >.amp/services.yaml <<EOF
# Generated by kirby-orb.
services:
  kirby:
    command: |
      export APP_URL="\$(printf %s "\$PUBLIC_URL" | sed 's|/\$||')"
      PHP_CLI_SERVER_WORKERS=4 exec ${php_server/127.0.0.1/0.0.0.0}
    port: 3000
    portal:
      title: Website
    portals:
      - url: /panel
        title: Kirby Panel
        description: Signs you in with your Amp identity.
EOF
	fi
	log "services: $services"
fi

# Content sync tool, from the same kirby-orb revision.
plugin_dir="$HOME/.config/amp/plugins/kirby-content-sync"
rm -rf "$plugin_dir"
mkdir -p "$plugin_dir"
cp "$orb_dir/plugin/index.ts" "$plugin_dir/index.ts"

# Agent notes live between markers and are replaced on every run.
guide_file="$HOME/.config/amp/AGENTS.md"
mkdir -p "$(dirname "$guide_file")"
touch "$guide_file"
awk '$0 == "<!-- kirby-orb -->" {skip = 1} !skip {print} $0 == "<!-- /kirby-orb -->" {skip = 0}' "$guide_file" >"$guide_file.tmp"
cat >>"$guide_file.tmp" <<EOF
<!-- kirby-orb -->
## Kirby site orb

- PHP $php_minor, Composer$([[ -n "$package_manager" ]] && echo ", Node and $package_manager") are on PATH. Project binaries are in \`vendor/bin\` (e.g. \`vendor/bin/kirby\`) and \`node_modules/.bin\`.
- \`amp orb services ensure\` starts the dev server behind an Amp portal. Use the portal URL for browser checks or localhost with agent-browser.
- Portal visitors are logged in to the Panel automatically. For agent-browser, run \`kirby-orb-user\` to create or reset \`agent@orb.test\` and print a fresh password.
- Content lives in \`$(relative "$(root content)")\` and is usually not in Git. Pull it with the \`sync_content\` tool when it is available; never connect to the live server directly.
<!-- /kirby-orb -->
EOF
mv "$guide_file.tmp" "$guide_file"

step "Done. Start the dev servers with: amp orb services ensure"
