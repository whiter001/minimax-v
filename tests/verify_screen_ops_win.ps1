# verify_screen_ops_win.ps1 - 验证桌面控制/截图能力是否可触发（Windows）
#
# 用法:
#   .\tests\verify_screen_ops_win.ps1
#   .\tests\verify_screen_ops_win.ps1 -SkipBuild
#   .\tests\verify_screen_ops_win.ps1 -SkipMouse
#   .\tests\verify_screen_ops_win.ps1 -SkipNotepadFlow
#   .\tests\verify_screen_ops_win.ps1 -WithMcp

param(
	[switch]$SkipBuild,
	[switch]$SkipMouse,
	[switch]$SkipNotepadFlow,
	[switch]$WithMcp,
	[int]$TimeoutSec = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..')).Path
Set-Location $RepoRoot

$Binary = Join-Path $RepoRoot 'minimax_cli.exe'
$PassCount = 0
$FailCount = 0

function Write-Step([string]$msg) { Write-Host "[STEP] $msg" -ForegroundColor Cyan }
function Write-Pass([string]$msg) { $script:PassCount++; Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Write-Fail([string]$msg) { $script:FailCount++; Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Write-Skip([string]$msg) { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow }
function Get-Preview([string]$text) {
	if ($null -eq $text) { return '' }
	$lines = $text -split "`r?`n"
	return ($lines | Select-Object -First 6) -join "`n"
}

function Contains-IgnoreCase([string]$text, [string]$expected) {
	if ($null -eq $text) { return $false }
	return ($text.IndexOf($expected, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Test-ApiKeyConfigured {
	if ($env:MINIMAX_API_KEY -and $env:MINIMAX_API_KEY.Trim().Length -gt 0) {
		return $true
	}
	$configPath = Join-Path $env:USERPROFILE '.config\minimax\config'
	$legacyPath = Join-Path $env:USERPROFILE '.minimax_config'
	if (Test-Path $configPath) {
		if (Select-String -Path $configPath -Pattern '^\s*api_key\s*=\s*\S+' -Quiet) { return $true }
	}
	if (Test-Path $legacyPath) {
		if (Select-String -Path $legacyPath -Pattern '^\s*api_key\s*=\s*\S+' -Quiet) { return $true }
	}
	return $false
}

function Invoke-Cli {
	param(
		[string[]]$CliArgs,
		[int]$Timeout = 120
	)
	$psi = [System.Diagnostics.ProcessStartInfo]::new()
	$psi.FileName = $Binary
	$psi.Arguments = ($CliArgs | ForEach-Object {
		if ($_ -match '\s') { "`"$_`"" } else { $_ }
	}) -join ' '
	$psi.RedirectStandardOutput = $true
	$psi.RedirectStandardError = $true
	$psi.RedirectStandardInput = $true
	$psi.UseShellExecute = $false
	$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
	$psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

	$proc = [System.Diagnostics.Process]::Start($psi)
	$proc.StandardInput.Close()

	$stdoutTask = $proc.StandardOutput.ReadToEndAsync()
	$stderrTask = $proc.StandardError.ReadToEndAsync()
	if (-not $proc.WaitForExit($Timeout * 1000)) {
		try { $proc.Kill() } catch {}
		[void]$stdoutTask.Wait(2000)
		[void]$stderrTask.Wait(2000)
		return [pscustomobject]@{
			ExitCode = -1
			Output   = "timeout after ${Timeout}s"
		}
	}
	[void]$stdoutTask.Wait(3000)
	[void]$stderrTask.Wait(3000)
	return [pscustomobject]@{
		ExitCode = $proc.ExitCode
		Output   = ($stdoutTask.Result + $stderrTask.Result)
	}
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Blue
Write-Host " Screen Ops Verification (Windows)" -ForegroundColor Blue
Write-Host "=========================================" -ForegroundColor Blue

if (-not (Test-ApiKeyConfigured)) {
	Write-Fail "未检测到 API Key（环境变量或 ~/.config/minimax/config），无法触发 AI 工具调用"
	exit 2
}
Write-Pass "检测到 API Key 配置"

if (-not $SkipBuild) {
	Write-Step "编译 minimax_cli.exe"
	$buildOut = & v -enable-globals -o minimax_cli.exe src 2>&1
	if ($LASTEXITCODE -eq 0 -and (Test-Path $Binary)) {
		Write-Pass "编译成功"
	} else {
		Write-Fail "编译失败"
		Write-Host (Get-Preview ($buildOut | Out-String)) -ForegroundColor DarkGray
		exit 1
	}
} elseif (-not (Test-Path $Binary)) {
	Write-Fail "SkipBuild 模式下未找到 $Binary"
	exit 1
}

$runId = Get-Date -Format 'yyyyMMdd_HHmmss'
$artifactsDir = Join-Path $env:TEMP "minimax_screen_ops_$runId"
New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
Write-Step "临时产物目录: $artifactsDir"

# 1) 验证 capture_screen 触发
$capturePath = Join-Path $artifactsDir 'capture_screen_test.png'
$capturePrompt = "请只调用 capture_screen 工具，将 path 设为 '$capturePath'，不要调用其他工具，完成后回复 CAPTURE_DONE。"
$captureResult = Invoke-Cli -CliArgs @(
	'--enable-tools',
	'--enable-screen-capture',
	'--output-format', 'plain',
	'-p', $capturePrompt
) -Timeout $TimeoutSec

if ($captureResult.ExitCode -eq 0 -and (Test-Path $capturePath) -and ((Get-Item $capturePath).Length -gt 0)) {
	Write-Pass "capture_screen 已触发并生成截图文件: $capturePath"
} else {
	Write-Fail "capture_screen 触发失败 (exit=$($captureResult.ExitCode))"
	Write-Host (Get-Preview $captureResult.Output) -ForegroundColor DarkGray
}

# 2) 验证 mouse_control 触发（默认执行，可通过 -SkipMouse 跳过）
if (-not $SkipMouse) {
	Add-Type -AssemblyName System.Windows.Forms
	Add-Type -AssemblyName System.Drawing
	$before = [System.Windows.Forms.Cursor]::Position
	$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
	$targetX = [Math]::Min([Math]::Max($before.X + 30, $bounds.Left + 2), $bounds.Right - 3)
	$targetY = [Math]::Min([Math]::Max($before.Y + 30, $bounds.Top + 2), $bounds.Bottom - 3)

	$mousePrompt = "请只调用 mouse_control 工具，action=move x=$targetX y=$targetY，不要调用其他工具，完成后回复 MOUSE_DONE。"
	$mouseResult = Invoke-Cli -CliArgs @(
		'--enable-tools',
		'--enable-desktop-control',
		'--output-format', 'plain',
		'-p', $mousePrompt
	) -Timeout $TimeoutSec

	Start-Sleep -Milliseconds 700
	$after = [System.Windows.Forms.Cursor]::Position
	$dx = [Math]::Abs($after.X - $targetX)
	$dy = [Math]::Abs($after.Y - $targetY)
	[System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new($before.X, $before.Y)

	if ($mouseResult.ExitCode -eq 0 -and (Contains-IgnoreCase $mouseResult.Output 'mouse_control')) {
		if ($dx -le 12 -and $dy -le 12) {
			Write-Pass "mouse_control 已触发（光标移动到目标附近）"
		} else {
			Write-Pass "mouse_control 已触发（输出成功，坐标存在偏差 dx=$dx dy=$dy）"
		}
	} else {
		Write-Fail "mouse_control 触发失败 (exit=$($mouseResult.ExitCode), dx=$dx, dy=$dy)"
		Write-Host (Get-Preview $mouseResult.Output) -ForegroundColor DarkGray
	}
} else {
	Write-Skip "mouse_control 验证已跳过 (-SkipMouse)"
}

# 3) 验证复杂任务流（打开记事本 -> 点击/输入你好 -> 截图 -> 保存 -> 校验文件内容）
if (-not $SkipNotepadFlow) {
	Write-Step "验证复杂任务流（Notepad）"

	$notepadBeforePath = Join-Path $artifactsDir 'notepad_before.png'
	$notepadAfterInputPath = Join-Path $artifactsDir 'notepad_after_input.png'
	$notepadAfterSavePath = Join-Path $artifactsDir 'notepad_after_save.png'
	$savedFilePath = Join-Path $artifactsDir 'notepad_saved_nihao.txt'
	$notepadBeforePathPrompt = ($notepadBeforePath -replace '\\', '/')
	$notepadAfterInputPathPrompt = ($notepadAfterInputPath -replace '\\', '/')
	$notepadAfterSavePathPrompt = ($notepadAfterSavePath -replace '\\', '/')
	$savedFilePathPrompt = ($savedFilePath -replace '\\', '/')
	$existingNotepadIds = @((Get-Process notepad -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id))

	if (Test-Path $savedFilePath) {
		Remove-Item $savedFilePath -Force -ErrorAction SilentlyContinue
	}

	$notepadProc = $null
	try {
		$openNotepadPrompt = "请只调用 run_command 工具执行这个命令来打开记事本并加载目标文件：powershell -NoProfile -Command `"Start-Process notepad -ArgumentList '$savedFilePathPrompt'`"。不要调用其他工具，完成后仅回复 NOTEPAD_OPENED。"
		$openResult = Invoke-Cli -CliArgs @(
			'--enable-tools',
			'--output-format', 'plain',
			'-p', $openNotepadPrompt
		) -Timeout ($TimeoutSec + 30)
		$openHasRunCommand = (Contains-IgnoreCase $openResult.Output 'run_command')
		$openRetryResult = $null

		Start-Sleep -Milliseconds 1200
		$newNotepad = Get-Process notepad -ErrorAction SilentlyContinue |
			Where-Object { $_.Id -notin $existingNotepadIds } |
			Sort-Object StartTime -Descending |
			Select-Object -First 1
		if ($null -eq $newNotepad) {
			$openRetryPrompt = "你必须调用 run_command 工具执行 powershell -NoProfile -Command `"Start-Process notepad -ArgumentList '$savedFilePathPrompt'`"，其他内容不要做，完成后回复 OPEN_RETRY_DONE。"
			$openRetryResult = Invoke-Cli -CliArgs @(
				'--enable-tools',
				'--output-format', 'plain',
				'-p', $openRetryPrompt
			) -Timeout ($TimeoutSec + 30)
			if (Contains-IgnoreCase $openRetryResult.Output 'run_command') {
				$openHasRunCommand = $true
			}
			Start-Sleep -Milliseconds 1200
			$newNotepad = Get-Process notepad -ErrorAction SilentlyContinue |
				Where-Object { $_.Id -notin $existingNotepadIds } |
				Sort-Object StartTime -Descending |
				Select-Object -First 1
		}
		$notepadProc = $newNotepad

		if ($null -eq $notepadProc) {
			Write-Fail "未找到 Notepad 进程"
			Write-Host "    open output: $(Get-Preview $openResult.Output)" -ForegroundColor DarkGray
			if ($null -ne $openRetryResult) {
				Write-Host "    retry output: $(Get-Preview $openRetryResult.Output)" -ForegroundColor DarkGray
			}
		} else {
			if ($openHasRunCommand) {
				Write-Pass "AI 已触发 run_command 打开 Notepad"
			} else {
				Write-Pass "Notepad 已启动（未检测到 run_command 痕迹，记录为弱校验）"
			}

			$hwnd = [IntPtr]::Zero
			for ($i = 0; $i -lt 80; $i++) {
				$notepadProc.Refresh()
				$hwnd = $notepadProc.MainWindowHandle
				if ($hwnd -ne [IntPtr]::Zero) { break }
				Start-Sleep -Milliseconds 250
			}

			if ($hwnd -eq [IntPtr]::Zero) {
				Write-Fail "Notepad MainWindowHandle 无效"
			} else {
				Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct RECT {
	public int Left;
	public int Top;
	public int Right;
	public int Bottom;
}
public static class MiniMaxWinCtl {
	[DllImport("user32.dll")]
	public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
	[DllImport("user32.dll")]
	public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
	[DllImport("user32.dll")]
	public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@ -ErrorAction SilentlyContinue

				[void][MiniMaxWinCtl]::ShowWindowAsync($hwnd, 9)
				[void][MiniMaxWinCtl]::SetForegroundWindow($hwnd)
				Start-Sleep -Milliseconds 500

				$rect = New-Object RECT
				[void][MiniMaxWinCtl]::GetWindowRect($hwnd, [ref]$rect)
				$clickX = [Math]::Min([Math]::Max($rect.Left + 120, $rect.Left + 10), $rect.Right - 10)
				$clickY = [Math]::Min([Math]::Max($rect.Top + 120, $rect.Top + 10), $rect.Bottom - 10)

				$complexPrompt = @"
请严格按顺序完成任务，只使用 mouse_control、keyboard_control、capture_screen 工具：
1) 用 mouse_control 在 x=$clickX y=$clickY 执行一次 left click
2) 用 capture_screen 截图保存到 '$notepadBeforePathPrompt'
3) 用 keyboard_control 输入文本：你好
4) 再次用 capture_screen 截图保存到 '$notepadAfterInputPathPrompt'
5) 用 keyboard_control 发送 ^s
6) 最后用 capture_screen 截图保存到 '$notepadAfterSavePathPrompt'
完成后仅回复 COMPLEX_DONE
"@

				$complexResult = Invoke-Cli -CliArgs @(
					'--enable-tools',
					'--enable-desktop-control',
					'--enable-screen-capture',
					'--output-format', 'plain',
					'-p', $complexPrompt
				) -Timeout ($TimeoutSec + 90)

				Start-Sleep -Milliseconds 1200

				$basicOk = $true
				if ($complexResult.ExitCode -ne 0) {
					$basicOk = $false
					Write-Fail "复杂任务调用失败 (exit=$($complexResult.ExitCode))"
					Write-Host (Get-Preview $complexResult.Output) -ForegroundColor DarkGray
				}
				if (-not (Contains-IgnoreCase $complexResult.Output 'mouse_control')) {
					$basicOk = $false
					Write-Fail "复杂任务输出未发现 mouse_control 调用痕迹"
				}
				if (-not (Contains-IgnoreCase $complexResult.Output 'keyboard_control')) {
					$basicOk = $false
					Write-Fail "复杂任务输出未发现 keyboard_control 调用痕迹"
				}
				if (-not (Contains-IgnoreCase $complexResult.Output 'capture_screen')) {
					$basicOk = $false
					Write-Fail "复杂任务输出未发现 capture_screen 调用痕迹"
				}

				$shotsOk = $true
				foreach ($shot in @($notepadBeforePath, $notepadAfterInputPath, $notepadAfterSavePath)) {
					if (-not (Test-Path $shot) -or ((Get-Item $shot).Length -le 0)) {
						$shotsOk = $false
						Write-Fail "复杂任务截图不存在或为空: $shot"
					}
				}
				if ($shotsOk) {
					$h1 = (Get-FileHash -Path $notepadBeforePath -Algorithm SHA256).Hash
					$h2 = (Get-FileHash -Path $notepadAfterInputPath -Algorithm SHA256).Hash
					if ($h1 -ne $h2) {
						Write-Pass "复杂任务截图前后有变化（输入后画面变化）"
					} else {
						Write-Fail "复杂任务截图前后无变化（可能未输入成功）"
					}
				}

				if (Test-Path $savedFilePath) {
					$savedContent = Get-Content -Path $savedFilePath -Raw -ErrorAction SilentlyContinue
					if (Contains-IgnoreCase $savedContent '你好') {
						Write-Pass "复杂任务保存文件成功，内容包含“你好”"
					} else {
						Write-Fail "复杂任务保存文件存在，但内容不包含“你好”"
					}
				} else {
					$retrySteps = @(
						"请只调用 mouse_control 工具，action=click x=$clickX y=$clickY button=left clicks=1，完成后仅回复 RETRY_CLICK_DONE。",
						"请只调用 keyboard_control 工具，action=send keys='^s'，完成后仅回复 RETRY_CTRL_S_DONE。"
					)
					$retryFailed = $false
					$retryOutputText = ''
					foreach ($retryPrompt in $retrySteps) {
						$retryResult = Invoke-Cli -CliArgs @(
							'--enable-tools',
							'--enable-desktop-control',
							'--output-format', 'plain',
							'-p', $retryPrompt
						) -Timeout ($TimeoutSec + 45)
						$retryOutputText += ($retryResult.Output + "`n")
						if ($retryResult.ExitCode -ne 0) {
							$retryFailed = $true
						}
						Start-Sleep -Milliseconds 500
					}
					Start-Sleep -Milliseconds 1200
					if (Test-Path $savedFilePath) {
						$savedContent = Get-Content -Path $savedFilePath -Raw -ErrorAction SilentlyContinue
						if (Contains-IgnoreCase $savedContent '你好') {
							Write-Pass "复杂任务保存重试成功，内容包含“你好”"
						} else {
							Write-Fail "复杂任务保存重试后文件存在，但内容不包含“你好”"
						}
					} else {
						Write-Fail "复杂任务未生成保存文件: $savedFilePath"
						Write-Host (Get-Preview $retryOutputText) -ForegroundColor DarkGray
					}
					if ($retryFailed) {
						Write-Fail "复杂任务保存重试过程中存在非零退出码"
					}
				}

				if ($basicOk -and $shotsOk -and (Test-Path $savedFilePath) -and (Contains-IgnoreCase (Get-Content -Path $savedFilePath -Raw -ErrorAction SilentlyContinue) '你好')) {
					Write-Pass "Notepad 复杂任务流触发完成"
				}
			}
		}
	} finally {
		if ($null -ne $notepadProc) {
			try {
				if (-not $notepadProc.HasExited) {
					Stop-Process -Id $notepadProc.Id -Force -ErrorAction SilentlyContinue
				}
			} catch {}
		}
	}
} else {
	Write-Skip "Notepad 复杂任务流已跳过 (-SkipNotepadFlow)"
}

# 4) 可选验证 screen_analyze（需要 MCP 可用）
if ($WithMcp) {
	$mcpPrompt = "请调用 screen_analyze 工具分析当前屏幕，prompt='请简要描述当前屏幕主要内容'。"
	$mcpResult = Invoke-Cli -CliArgs @(
		'--mcp',
		'--enable-tools',
		'--enable-screen-capture',
		'--output-format', 'plain',
		'-p', $mcpPrompt
	) -Timeout ($TimeoutSec + 60)

	if ($mcpResult.ExitCode -eq 0 -and $mcpResult.Output -notmatch 'Error:') {
		Write-Pass "screen_analyze 调用完成"
	} else {
		Write-Fail "screen_analyze 调用失败 (exit=$($mcpResult.ExitCode))"
		Write-Host (Get-Preview $mcpResult.Output) -ForegroundColor DarkGray
	}
} else {
	Write-Skip "screen_analyze 验证已跳过（使用 -WithMcp 可启用）"
}

Write-Host ""
Write-Host "-----------------------------------------" -ForegroundColor Blue
Write-Host " PASS: $PassCount" -ForegroundColor Green
Write-Host " FAIL: $FailCount" -ForegroundColor Red
Write-Host " ArtifactDir: $artifactsDir" -ForegroundColor Cyan
Write-Host "-----------------------------------------" -ForegroundColor Blue

if ($FailCount -gt 0) { exit 1 }
exit 0
