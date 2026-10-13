import type { PluginAPI, PluginUI } from '@ampcode/plugin'
import { readFileSync } from 'node:fs'
import { mkdir, mkdtemp, rm, stat, writeFile } from 'node:fs/promises'
import { homedir, tmpdir } from 'node:os'
import { dirname, join, posix, relative, resolve } from 'node:path'

export const description = 'Pull and push Kirby content from the live server.'

type Config = {
	protocol: 'ssh' | 'sftp'
	user: string
	host: string
	port: string
	remotePath: string
	localPath: string
}

type Direction = 'pull' | 'push'

const KNOWN_HOSTS = join(homedir(), '.ssh', 'known_hosts_content_sync')
const PACKAGES: Record<string, string> = { rsync: 'rsync', sshpass: 'sshpass', lftp: 'lftp' }

export function readConfig(env: NodeJS.ProcessEnv): Config | null {
	if (!env.CONTENT_SYNC_URL) return null
	const url = new URL(env.CONTENT_SYNC_URL)
	const protocol = url.protocol.replace(/:$/, '')
	if (protocol !== 'ssh' && protocol !== 'sftp') throw new Error('CONTENT_SYNC_URL must start with ssh:// or sftp://')
	const path = decodeURIComponent(url.pathname)
	return {
		protocol,
		user: decodeURIComponent(url.username),
		host: url.hostname,
		port: url.port,
		remotePath: path.startsWith('/~/') ? path.slice(3) : path,
		localPath: env.CONTENT_SYNC_LOCAL_PATH || detectedContentRoot() || 'content',
	}
}

function detectedContentRoot(): string | undefined {
	try {
		return JSON.parse(readFileSync(join(homedir(), '.local/share/kirby-orb/site.json'), 'utf8')).content
	} catch {
		return undefined
	}
}

export function contentPaths(input: unknown): string[] {
	const list = Array.isArray(input) ? input : input === undefined || input === '' ? [] : [input]
	const paths = list.map((item) => {
		const path = posix.normalize(String(item)).replace(/\/+$/, '')
		if (path.startsWith('/') || path === '..' || path.startsWith('../')) {
			throw new Error(`${item} is not inside the content folder`)
		}
		return path
	})
	return paths.includes('.') ? [] : [...new Set(paths)]
}

async function run(command: string[], env: Record<string, string> = {}) {
	const proc = Bun.spawn(command, { stdout: 'pipe', stderr: 'pipe', env: { ...process.env, ...env } })
	const [stdout, stderr, exitCode] = await Promise.all([
		new Response(proc.stdout).text(),
		new Response(proc.stderr).text(),
		proc.exited,
	])
	if (exitCode !== 0) throw new Error(`${command[0]} failed (${exitCode}): ${(stderr || stdout).trim()}`)
	return stdout
}

async function ensureTools(names: string[]) {
	const missing = names.filter((name) => !Bun.which(name))
	if (!missing.length) return
	if (!Bun.which('sudo') || !Bun.which('apt-get')) throw new Error(`Install ${missing.join(', ')} first.`)
	const packages = missing.map((name) => PACKAGES[name])
	const install = ['sudo', 'env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', '-qq', ...packages]
	await run(install).catch(async () => {
		await run(['sudo', 'apt-get', 'update', '-qq'])
		await run(install)
	})
}

export function createSync(config: Config, credentials: { key?: string; password?: string }) {
	const remoteRoot = config.remotePath || '.'

	return async function sync(
		direction: Direction,
		options: { paths: string[]; root: string; dryRun: boolean; deleteRemote: boolean },
	): Promise<string> {
		const localRoot = resolve(options.root, config.localPath)
		await mkdir(localRoot, { recursive: true })
		await mkdir(join(homedir(), '.ssh'), { recursive: true, mode: 0o700 })

		const keyDir = await mkdtemp(join(tmpdir(), 'content-sync-'))
		try {
			let keyFile: string | undefined
			if (credentials.key) {
				keyFile = join(keyDir, 'key')
				await writeFile(keyFile, credentials.key.endsWith('\n') ? credentials.key : `${credentials.key}\n`, {
					mode: 0o600,
				})
			}
			const ssh = [
				'-o StrictHostKeyChecking=accept-new',
				`-o UserKnownHostsFile=${KNOWN_HOSTS}`,
				...(keyFile
					? [`-i ${keyFile}`, '-o IdentitiesOnly=yes', '-o BatchMode=yes']
					: ['-o PreferredAuthentications=password,keyboard-interactive', '-o PubkeyAuthentication=no']),
			]
			const localFolders = new Set<string>()
			if (direction === 'push') {
				for (const path of options.paths) {
					const stats = await stat(join(localRoot, path)).catch(() => null)
					if (!stats) throw new Error(`${path} does not exist locally`)
					if (stats.isDirectory()) localFolders.add(path)
				}
			}
			const deletes = direction === 'pull' || options.deleteRemote

			if (config.protocol === 'ssh') {
				await ensureTools(credentials.password ? ['rsync', 'sshpass'] : ['rsync'])
				const host = `${config.user ? `${config.user}@` : ''}${config.host}:`
				const sources = options.paths.length ? options.paths.map((path) => `/./${path}`) : ['/']
				const [from, to] =
					direction === 'pull'
						? [sources.map((source) => `${host}${remoteRoot}${source}`), `${localRoot}/`]
						: [sources.map((source) => `${localRoot}${source}`), `${host}${remoteRoot}/`]
				const command = [
					'rsync',
					'-az',
					...(options.paths.length ? ['--relative'] : []),
					'--exclude=.lock',
					...(deletes ? ['--delete'] : []),
					...(options.dryRun ? ['--dry-run', '--itemize-changes'] : ['--stats']),
					'-e',
					['ssh', ...(config.port ? [`-p ${config.port}`] : []), ...ssh].join(' '),
					...from,
					to,
				]
				if (!credentials.password) return await run(command)
				return await run(['sshpass', '-e', ...command], { SSHPASS: credentials.password })
			}

			await ensureTools(['lftp'])
			const quote = (value: string) => `"${value.replace(/(["\\])/g, '\\$1')}"`
			const url = `sftp://${config.host}${config.port ? `:${config.port}` : ''}`
			const lftp = (commands: string[]) =>
				run(
					[
						'lftp',
						'-c',
						[
							'set cmd:fail-exit yes',
							'set xfer:clobber on',
							'set sftp:auto-confirm yes',
							'set net:max-retries 2',
							'set net:timeout 30',
							`set sftp:connect-program ${quote(['ssh -a -x', ...ssh].join(' '))}`,
							credentials.password
								? `open --env-password -u ${quote(config.user)} ${url}`
								: `open -u ${quote(`${config.user},`)} ${url}`,
							...commands,
						].join('\n'),
					],
					credentials.password ? { LFTP_PASSWORD: credentials.password } : {},
				)
			const local = (path: string) => (path ? join(localRoot, path) : localRoot)
			const remote = (path: string) => posix.join(remoteRoot, path)
			const mirror = (path: string) =>
				[
					'mirror',
					...(direction === 'push' ? ['--reverse'] : []),
					...(deletes ? ['--delete'] : []),
					...(options.dryRun ? ['--dry-run'] : ['--verbose=1']),
					'--exclude-glob .lock',
					...(direction === 'pull'
						? [quote(remote(path)), quote(local(path))]
						: [quote(local(path)), quote(remote(path))]),
				].join(' ')

			const paths = options.paths.length ? options.paths : ['']
			let isFolder: (path: string) => boolean
			if (direction === 'push') {
				isFolder = (path) => !path || localFolders.has(path)
			} else {
				const listing = options.paths.length
					? await lftp([`cls -1 -d -F ${paths.map((path) => quote(remote(path))).join(' ')}`])
					: ''
				isFolder = (path) => !path || listing.split('\n').includes(`${remote(path)}/`)
			}

			const files = paths.filter((path) => !isFolder(path))
			const commands: string[] = []
			for (const path of paths) {
				if (isFolder(path)) commands.push(mirror(path))
				else if (direction === 'pull') {
					await mkdir(dirname(local(path)), { recursive: true })
					commands.push(`get ${quote(remote(path))} -o ${quote(local(path))}`)
				} else
					commands.push(
						`mkdir -p -f ${quote(posix.dirname(remote(path)))}`,
						`put ${quote(local(path))} -o ${quote(remote(path))}`,
					)
			}
			const runnable = options.dryRun ? commands.filter((command) => command.startsWith('mirror')) : commands
			const output = runnable.length ? await lftp(runnable) : ''
			return options.dryRun
				? [output, ...files.map((path) => `put file:${local(path)}`)].join('\n')
				: `${output}\n${files.map((path) => `Transferring file \`${path}'`).join('\n')}`
		} finally {
			await rm(keyDir, { recursive: true, force: true })
		}
	}
}

export function changeList(output: string, local: string, remote: string): string[] {
	const relative = (path: string) => {
		if (path.startsWith('file:')) return path.slice(5).replace(`${local}/`, '')
		const tail = remote.replace(/^\/?(~\/)?/, '').replace(/\/$/, '')
		const index = path.indexOf(`${tail}/`)
		return index === -1 ? path : path.slice(index + tail.length + 1)
	}
	return output.split('\n').flatMap((line) => {
		const rsync = line.match(/^(\*deleting|[<>]f\S*)\s+(.+)$/)
		if (rsync) return [`${rsync[1] === '*deleting' ? '-' : rsync[1].includes('+++') ? '+' : '~'} ${rsync[2]}`]
		const lftp = line.match(/^(get|put|rm)\s(?:.*\s)?(\S+)$/)
		if (lftp) return [`${lftp[1] === 'rm' ? '-' : '~'} ${relative(lftp[2])}`]
		return []
	})
}

function summary(output: string): string {
	const lines = output.split('\n')
	const rsync = lines.filter((line) =>
		/^(Number of (files|regular files transferred|deleted files)|Total transferred file size)/.test(line),
	)
	if (rsync.length) return rsync.join('\n')
	return `Transferred ${lines.filter((line) => line.startsWith('Transferring file')).length} files.`
}

export default function (amp: PluginAPI) {
	const config = readConfig(process.env)
	if (!config) return

	let password = process.env.CONTENT_SYNC_PASSWORD
	const credentials = async (ui: PluginUI) => {
		if (process.env.CONTENT_SYNC_SSH_KEY) return { key: process.env.CONTENT_SYNC_SSH_KEY }
		password ||= await ui.input({
			title: `Password for ${config.user}@${config.host}`,
			secret: true,
			requireHuman: true,
			fieldName: 'CONTENT_SYNC_PASSWORD',
		})
		if (!password) throw new Error('No password given.')
		return { password }
	}

	const syncTool = async (input: Record<string, unknown>, ui: PluginUI) => {
		const direction: Direction = input.direction === 'push' ? 'push' : 'pull'
		const paths = contentPaths(input.paths)
		const root = amp.system.workspaceRoot ? amp.helpers.filePathFromURI(amp.system.workspaceRoot) : process.cwd()
		const sync = createSync(config, await credentials(ui))
		const options = { paths, root, dryRun: false, deleteRemote: input.delete === true }
		const contentDir = relative(root, resolve(root, config.localPath))
		const label = paths.length ? paths.map((path) => `${contentDir}/${path}`).join(', ') : contentDir

		if (direction === 'pull') {
			const output = await sync('pull', options)
			return `Pulled ${label}.\n${summary(output)}`
		}

		const changes = changeList(
			await sync('push', { ...options, dryRun: true }),
			resolve(root, config.localPath),
			config.remotePath || '.',
		)
		if (!changes.length) return 'Nothing to push.'
		const shown = changes.slice(0, 40).join('\n')
		const more = changes.length > 40 ? `\n… and ${changes.length - 40} more` : ''
		let approved = false
		try {
			approved = await ui.confirm({
				title: `Push to ${config.host}?`,
				message: `\`\`\`\n${shown}${more}\n\`\`\``,
				confirmButtonText: 'Push',
				requireHuman: true,
			})
		} catch (error) {
			if (!(error instanceof Error && amp.helpers.isPluginUINotAvailableError(error))) throw error
		}
		if (!approved) return 'Push not approved.'
		const output = await sync('push', options)
		return `Pushed ${label}.\n${summary(output)}`
	}

	amp.registerTool({
		name: 'sync_content',
		title: 'Sync Kirby content',
		transcriptGroup: { active: 'Syncing content', complete: 'Synced content' },
		description:
			`Sync the Kirby content folder with ${config.host}. pull (default) replaces local content with the live content. ` +
			"push uploads local content and needs the user's approval. Only push when the user asked for it. Never access the server any other way.",
		inputSchema: {
			type: 'object',
			properties: {
				direction: { type: 'string', enum: ['pull', 'push'] },
				paths: {
					type: 'array',
					items: { type: 'string' },
					description:
						'Files or folders relative to the content folder, e.g. "1_home/home.txt". Defaults to everything.',
				},
				delete: {
					type: 'boolean',
					description: 'push only: delete live files that are missing locally. Only when the user asked for it.',
				},
			},
		},
		async execute(input, ctx) {
			try {
				return await syncTool(input, ctx.ui)
			} catch (error) {
				password = process.env.CONTENT_SYNC_PASSWORD
				throw error
			}
		},
	})

	const escape = (value: string) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
	const blocked = new RegExp(`${escape(config.host)}|CONTENT_SYNC_|known_hosts_content_sync`, 'i')
	amp.on('tool.call', (event) => {
		const shell = amp.helpers.shellCommandFromToolCall(event)
		if (!shell || !blocked.test(shell.command)) return { action: 'allow' }
		return {
			action: 'reject-and-continue',
			message: `Use sync_content to access ${config.host}.`,
		}
	})
}
