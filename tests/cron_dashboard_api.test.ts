import { afterAll, beforeAll, describe, expect, test } from 'bun:test'
import { spawn, spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const repoRoot = resolve(import.meta.dir, '..')
const binaryPath = join(repoRoot, 'minimax_cli.exe')
const testPort = Number(process.env.CRON_DASHBOARD_TEST_PORT ?? '18787')
const baseUrl = `http://127.0.0.1:${testPort}`

interface ApiResponse {
	success?: boolean
	message?: string
	error?: string
	job_id?: string
	[key: string]: unknown
}

interface CronJobRecord {
	id: string
	name: string
	schedule: string
	command: string
	run_once: boolean
	enabled: boolean
	next_run: number
}

let tempHome = ''
let server: ReturnType<typeof spawn> | null = null
let stdout = ''
let stderr = ''

function sleep(ms: number) {
	return new Promise((resolve) => setTimeout(resolve, ms))
}

function failWithLogs(message: string): never {
	const details = [`${message}`]
	if (stdout.trim().length > 0) {
		details.push(`stdout:\n${stdout.trim()}`)
	}
	if (stderr.trim().length > 0) {
		details.push(`stderr:\n${stderr.trim()}`)
	}
	throw new Error(details.join('\n\n'))
}

function assertBuiltBinary() {
	if (!existsSync(binaryPath)) {
		failWithLogs(`missing built binary: ${binaryPath}`)
	}
}

async function waitForDashboard() {
	const deadline = Date.now() + 20_000
	let lastError = ''
	while (Date.now() < deadline) {
		try {
			const res = await fetch(`${baseUrl}/`)
			if (res.ok) {
				return
			}
			lastError = `unexpected status ${res.status}`
		} catch (err) {
			lastError = err instanceof Error ? err.message : String(err)
		}
		await sleep(250)
	}
	failWithLogs(`dashboard did not start: ${lastError}`)
}

async function startDashboard() {
	tempHome = await mkdtemp(join(tmpdir(), 'minimax-bun-cron-'))
	server = spawn(binaryPath, ['cron', 'dashboard', String(testPort)], {
		cwd: repoRoot,
		env: {
			...process.env,
			HOME: tempHome,
			USERPROFILE: tempHome,
			MINIMAX_SKIP_CRON_DAEMON_START: '1',
		},
		stdio: ['ignore', 'pipe', 'pipe'],
	})

	server.stdout?.on('data', (chunk) => {
		stdout += chunk.toString()
	})
	server.stderr?.on('data', (chunk) => {
		stderr += chunk.toString()
	})

	await waitForDashboard()
}

async function stopDashboard() {
	if (server) {
		if (server.exitCode === null) {
			server.kill()
			await Promise.race([
				new Promise<void>((resolve) => {
					server?.once('exit', () => resolve())
				}),
				sleep(5000),
			])
			if (server.exitCode === null && server.pid) {
				spawnSync('taskkill', ['/PID', String(server.pid), '/T', '/F'], {
					cwd: repoRoot,
					stdio: 'ignore',
				})
			}
		}
		server = null
	}

	if (tempHome.length > 0) {
		await rm(tempHome, { recursive: true, force: true })
		tempHome = ''
	}
}

async function requestJson(path: string, init?: RequestInit) {
	const response = await fetch(`${baseUrl}${path}`, init)
	const body = await response.text()
	let parsed: ApiResponse
	try {
		parsed = JSON.parse(body) as ApiResponse
	} catch {
		failWithLogs(`expected JSON from ${path}, got:\n${body}`)
	}
	return { response, body, parsed }
}

async function readCronJobs() {
	if (tempHome.length === 0) {
		failWithLogs('temporary home is not initialized')
	}
	const cronJobsPath = join(tempHome, '.config', 'minimax', 'cron', 'cron_jobs.json')
	if (!existsSync(cronJobsPath)) {
		failWithLogs(`missing cron jobs file: ${cronJobsPath}`)
	}
	const content = await readFile(cronJobsPath, 'utf8')
	return JSON.parse(content) as CronJobRecord[]
}

beforeAll(async () => {
	assertBuiltBinary()
	await startDashboard()
})

afterAll(async () => {
	await stopDashboard()
})

describe('cron dashboard interface', () => {
	test('renders the dashboard page and edit controls', async () => {
		const response = await fetch(`${baseUrl}/`)
		const html = await response.text()

		expect(response.status).toBe(200)
		expect(html).toContain('Cron Dashboard')
		expect(html).toContain('/api/jobs/update')
		expect(html).toContain('create-form')
		expect(html).toContain('edit-form')
		expect(html).toContain('edit-modal')
	})

	test('supports create update and delete over http', async () => {
		const jobName = `bun-cron-${Date.now()}`
		const createdName = `${jobName}-created`
		const postUpdatedName = `${jobName}-post`

		const createUrl = new URL('/api/jobs', baseUrl)
		createUrl.search = new URLSearchParams({
			name: createdName,
			schedule: '@hourly',
			command: 'echo created',
			type: 'cron',
		}).toString()

		let result = await requestJson(createUrl.pathname + createUrl.search, {
			method: 'POST',
		})
		expect(result.response.status).toBe(200)
		expect(result.parsed.success).toBe(true)

		let jobs = await readCronJobs()
		const createdJob = jobs.find((job) => job.name === createdName)
		expect(createdJob).toBeDefined()
		expect(createdJob?.command).toBe('echo created')
		const jobId = createdJob?.id ?? failWithLogs(`created job not found: ${createdName}`)

		const postUpdateUrl = new URL(`/api/jobs/update`, baseUrl)
		postUpdateUrl.search = new URLSearchParams({
			id: jobId,
			name: postUpdatedName,
			schedule: '@daily',
			command: 'echo post-updated',
			type: 'cron',
		}).toString()

		result = await requestJson(postUpdateUrl.pathname + postUpdateUrl.search, {
			method: 'POST',
		})
		expect(result.response.status).toBe(200)
		expect(result.parsed.success).toBe(true)
		expect(result.parsed.job_id).toBe(jobId)

		jobs = await readCronJobs()
		let updatedJob = jobs.find((job) => job.id === jobId)
		expect(updatedJob?.name).toBe(postUpdatedName)
		expect(updatedJob?.schedule).toBe('@daily')
		expect(updatedJob?.command).toBe('echo post-updated')

		result = await requestJson(`/api/jobs/${jobId}`, {
			method: 'DELETE',
		})
		expect(result.response.status).toBe(200)
		expect(result.parsed.success).toBe(true)

		jobs = await readCronJobs()
		expect(jobs.find((job) => job.id === jobId)).toBeUndefined()
	})
})
