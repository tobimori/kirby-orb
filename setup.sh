#!/usr/bin/env bash
set -Eeuo pipefail

orb_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$PWD"
state_dir="$HOME/.local/share/kirby-orb"
bin_dir="$HOME/.local/bin"
SECONDS=0

log() { echo "[kirby-orb] $*"; }
fail() {
	echo "[kirby-orb] error: $*" >&2
	exit 1
}
trap 'fail "line $LINENO: $BASH_COMMAND"' ERR

mkdir -p "$state_dir" "$bin_dir"
export PATH="$bin_dir:$PATH"

settings=(KIRBY_ORB_PHP KIRBY_ORB_NODE KIRBY_ORB_BUILD KIRBY_ORB_SERVICES)
for name in $(compgen -e | grep '^KIRBY_ORB_' || true); do
	[[ " ${settings[*]} " == *" $name "* ]] || fail "unknown setting $name"
done

pinned() {
	if [[ -f mise.toml ]]; then sed -nE "s/^$1 *= *\"([^\"]+)\".*/\1/p" mise.toml; fi
	if [[ -f .tool-versions ]]; then awk -v tool="$1" '$1 == tool { print $2 }' .tool-versions; fi
}
lower_bound() { { grep -oE '[0-9]+\.[0-9]+' <<<"$1" || true; } | head -1; }
json() { jq -r "$2 // empty" "$1" 2>/dev/null || true; }
exclude() {
	local file
	file="$(git -C "$repo_root" rev-parse --git-path info/exclude)"
	grep -Fqx "$1" "$file" 2>/dev/null || printf '%s\n' "$1" >>"$file"
}

if [[ -n "${KIRBY_ORB_PHP:-}" ]]; then
	php_minor="$KIRBY_ORB_PHP"
elif [[ -n "$(pinned php)" ]]; then
	php_minor="$(lower_bound "$(pinned php | head -1)")"
else
	site_php="$(lower_bound "$(json composer.json '.require.php')")"
	kirby_php="$(lower_bound "$(json composer.lock '.packages[] | select(.name == "getkirby/cms") | .require.php')")"
	[[ -n "$kirby_php" ]] || kirby_php="$(lower_bound "$(json kirby/composer.json '.require.php')")"
	php_minor="$(printf '%s\n' "$site_php" "$kirby_php" | sed '/^$/d' | sort -V | tail -1)"
fi
[[ -n "$php_minor" ]] || fail "no PHP version found, set KIRBY_ORB_PHP"

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
log "php $php_minor"

package_manager=""
if [[ -f package.json ]]; then
	node_version="${KIRBY_ORB_NODE:-$(pinned node | head -1)}"
	for file in .nvmrc .node-version; do
		[[ -n "$node_version" || ! -f "$file" ]] || node_version="$(head -1 "$file" | tr -d '[:space:]v')"
	done
	[[ -n "$node_version" ]] || node_version="$(json package.json '.engines.node' | grep -oE '[0-9]+' | head -1 || true)"
	[[ -n "$node_version" ]] || node_version=lts

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

	command -v mise >/dev/null || curl -fsSL https://mise.jdx.dev/install.sh | sh
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
	log "node $node_version, $package_manager $package_manager_version"
fi

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
fi

if [[ -n "$package_manager" ]]; then
	case "$package_manager" in
		pnpm) pnpm install --frozen-lockfile --reporter=append-only ;;
		yarn) if [[ "$package_manager_version" == 1* ]]; then yarn install --frozen-lockfile; else yarn install --immutable; fi ;;
		bun) bun install --frozen-lockfile ;;
		npm) if [[ -f package-lock.json ]]; then npm ci; else npm install; fi ;;
		*) fail "unsupported package manager $package_manager" ;;
	esac

	build="${KIRBY_ORB_BUILD:-$([[ -n "$(json package.json '.scripts.build')" ]] && echo build || echo none)}"
	if [[ "$build" != none ]]; then
		clean="$([[ -z "$(git status --porcelain --untracked-files=no)" ]] && echo yes || true)"
		"$package_manager" run "$build"
		[[ -z "$clean" ]] || git checkout -- .
	fi
fi

if [[ -f .env.example && ! -f .env ]]; then
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

login_dir="$(root plugins)/orb-login"
mkdir -p "$login_dir"
cp "$orb_dir/lib/orb-login.php" "$login_dir/index.php"
exclude "/$(relative "$login_dir")/"

cat >"$bin_dir/kirby-orb-user" <<EOF
#!/usr/bin/env bash
exec php "$orb_dir/lib/user.php" "$repo_root/$index"
EOF
chmod +x "$bin_dir/kirby-orb-user"

php_server="php -d variables_order=EGPCS -S 127.0.0.1:\"\$PORT\" -t $(relative "$(root index)") $(relative "$(root kirby)")/router.php"
services="${KIRBY_ORB_SERVICES:-$(grep -q '^VITE_DEV_PORT=' .env 2>/dev/null && grep -q '^KIRBY_DEV_PORT=' .env && echo vite || echo php)}"
if ! git ls-files --error-unmatch .amp/services.yaml >/dev/null 2>&1; then
	mkdir -p .amp
	exclude /.amp/services.yaml
	exclude /.amp/portals/
	if [[ "$services" == vite ]]; then
		cat >.amp/services.yaml <<EOF
services:
  web:
    command: |
      export APP_URL="\$(printf %s "\$PUBLIC_URL" | sed 's|/\$||')"
      export __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS="\$(printf %s "\$APP_URL" | sed 's|^.*://||')"
      exec node_modules/.bin/vite --host 0.0.0.0 --port "\$PORT" --strictPort
    port: $(sed -n 's/^VITE_DEV_PORT=//p' .env)
    portal:
      title: Website
    portals:
      - url: /panel
        title: Panel
  kirby:
    command: PHP_CLI_SERVER_WORKERS=4 exec $php_server
    port: $(sed -n 's/^KIRBY_DEV_PORT=//p' .env)
    env:
      APP_URL: \${services.web.publicURL}
EOF
	else
		cat >.amp/services.yaml <<EOF
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
        title: Panel
EOF
	fi
fi

plugin_dir="$HOME/.config/amp/plugins/kirby-content-sync"
rm -rf "$plugin_dir"
mkdir -p "$plugin_dir"
cp "$orb_dir/plugin/index.ts" "$plugin_dir/index.ts"

guide_file="$HOME/.config/amp/AGENTS.md"
mkdir -p "$(dirname "$guide_file")"
touch "$guide_file"
awk '$0 == "<!-- kirby-orb -->" {skip = 1} !skip {print} $0 == "<!-- /kirby-orb -->" {skip = 0}' "$guide_file" >"$guide_file.tmp"
cat >>"$guide_file.tmp" <<EOF
<!-- kirby-orb -->
- Start the dev servers with \`amp orb services ensure\`.
- \`kirby-orb-user\` prints a Panel login.
<!-- /kirby-orb -->
EOF
mv "$guide_file.tmp" "$guide_file"

log "done in ${SECONDS}s"
