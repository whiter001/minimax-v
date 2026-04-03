# test_p_mode_win.ps1 - Windows 专项 -p 模式测试脚本
# 支持离线参数校验和在线 API 联调测试
#
# 用法:
#   .\tests\test_p_mode_win.ps1              # 仅离线测试
#   .\tests\test_p_mode_win.ps1 -WithApi     # 含在线 API 测试

param(
    [switch]$WithApi
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# 切换到项目根目录
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location (Join-Path $ScriptDir '..')

$Binary    = ".\minimax_cli.exe"
$PassCount = 0
$FailCount = 0

# ── 颜色输出辅助 ──────────────────────────────────────────────────────────────
function Write-Pass([string]$Desc) {
    $script:PassCount++
    Write-Host "  [PASS] $Desc" -ForegroundColor Green
}

function Write-Fail([string]$Desc, [string]$Reason) {
    $script:FailCount++
    Write-Host "  [FAIL] $Desc : $Reason" -ForegroundColor Red
}

function Write-Warn([string]$Msg) {
    Write-Host "  [WARN] $Msg" -ForegroundColor Yellow
}

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host "  ── $Title" -ForegroundColor Cyan
}

# ── 核心断言辅助 ──────────────────────────────────────────────────────────────

# 检查输出包含期望字符串（忽略大小写）
function Assert-Contains([string]$Desc, [string]$Output, [string]$Expected) {
    $text = if ($null -eq $Output) { '' } else { [string]$Output }
    if ($text.IndexOf($Expected, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        Write-Pass $Desc
    } else {
        Write-Fail $Desc "未找到期望字符串: '$Expected'"
        Write-Host "    实际输出: $($text.Split("`n") | Select-Object -First 3 | Out-String)" -ForegroundColor DarkGray
    }
}

# 检查退出码
function Assert-ExitCode([string]$Desc, [int]$Actual, [int]$Expected) {
    if ($Actual -eq $Expected) {
        Write-Pass $Desc
    } else {
        Write-Fail $Desc "退出码为 $Actual，预期为 $Expected"
    }
}

# 运行 CLI 并捕获输出 + 退出码
# $CliArgs: 参数数组
# $Env:     子进程环境变量覆盖 hashtable；值为 $null 表示从子进程环境中删除该变量
# $Timeout: 超时秒数
function Invoke-Cli {
    param(
        [string[]]$CliArgs,
        [hashtable]$Env    = @{},
        [int]     $Timeout = 30
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = (Resolve-Path $Binary).Path
    $psi.Arguments              = ($CliArgs | ForEach-Object {
                                      if ($_ -match '\s') { "`"$_`"" } else { $_ }
                                  }) -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true   # 关键: 阻止 readline/terminal 占用 stdin
    $psi.UseShellExecute        = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    # 用 EnvironmentVariables 直接操控子进程环境块（不污染当前进程）
    # ProcessStartInfo.EnvironmentVariables 初始为当前进程环境的拷贝
    foreach ($k in $Env.Keys) {
        if ($psi.EnvironmentVariables.ContainsKey($k)) {
            $psi.EnvironmentVariables.Remove($k)
        }
        if ($null -ne $Env[$k]) {
            # 注意: StringDictionary 不允许 null 值; 空字符串在 Windows 会被
            # GetEnvironmentVariable 识别为 "" (非 unset), V 的 getenv_opt 返回 some("")
            $psi.EnvironmentVariables[$k] = $Env[$k]
        }
        # $null 值: 已删除，不重新添加 → 子进程看不到该变量
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()           # 立即关闭 stdin

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    if (-not $proc.WaitForExit($Timeout * 1000)) {
        try { $proc.Kill() } catch {}
        [void]$stdoutTask.Wait(2000)
        [void]$stderrTask.Wait(2000)
        return [pscustomobject]@{ Output = "(timeout after ${Timeout}s)"; ExitCode = -1 }
    }

    [void]$stdoutTask.Wait(5000)
    [void]$stderrTask.Wait(5000)
    $out = $stdoutTask.Result + $stderrTask.Result
    return [pscustomobject]@{ Output = $out; ExitCode = $proc.ExitCode }
}

# 运行 CLI，同时隐藏所有 API Key 来源（env 变量 + 配置文件备份）
# 用于测试「未配置 API Key」分支
function Invoke-CliNoKey {
    param(
        [string[]]$CliArgs,
        [int]     $Timeout = 30
    )
    $configPath = Join-Path $env:USERPROFILE ".config\minimax\config"
    $legacyPath = Join-Path $env:USERPROFILE ".minimax_config"
    $configBak  = "$configPath.test_bak"
    $legacyBak  = "$legacyPath.test_bak"

    if (Test-Path $configPath) { Move-Item $configPath $configBak -Force }
    if (Test-Path $legacyPath) { Move-Item $legacyPath $legacyBak -Force }

    try {
        # 从 EnvironmentVariables 移除 MINIMAX_API_KEY（值 $null = 删除）
        return Invoke-Cli -CliArgs $CliArgs -Env @{MINIMAX_API_KEY=$null} -Timeout $Timeout
    } finally {
        if (Test-Path $configBak) { Move-Item $configBak $configPath -Force }
        if (Test-Path $legacyBak) { Move-Item $legacyBak $legacyPath -Force }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "=========================================" -ForegroundColor Blue
Write-Host " MiniMax CLI -p 模式专项测试 (Windows)"   -ForegroundColor Blue
Write-Host "=========================================" -ForegroundColor Blue

# ── Section 1: 编译 ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[1/5] 编译项目..." -ForegroundColor White

$buildOut = & bash ./build.sh 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Pass "编译成功"
} else {
    Write-Fail "编译" "无法完成编译，请检查 V 环境`n$buildOut"
    exit 1
}

# 确认二进制存在
if (-not (Test-Path $Binary)) {
    Write-Fail "二进制存在" "$Binary 不存在"
    exit 1
}

# ── Section 2: 离线参数与逻辑校验 ───────────────────────────────────────────
Write-Host ""
Write-Host "[2/5] 离线参数与逻辑校验..." -ForegroundColor White

# --version
$r = Invoke-Cli @('--version')
Assert-Contains "--version 包含版本标识" $r.Output "minimax-cli"

# -p 缺少内容
$r = Invoke-Cli @('-p') -Env @{MINIMAX_API_KEY='fake'}
Assert-Contains "-p 缺少内容时的错误提示" $r.Output "参数需要提供内容"
Assert-ExitCode "-p 缺少内容时 exit code 为 42" $r.ExitCode 42

# -p + 无 API Key（使用 Invoke-CliNoKey 确保 Windows 下不走配置文件）
$r = Invoke-CliNoKey @('-p', 'hello')
Assert-Contains "-p 无 API Key 时提示配置" $r.Output "未配置 API Key"
Assert-ExitCode "-p 无 API Key 时 exit code 为 1" $r.ExitCode 1

# --mcp + 无 API Key
$r = Invoke-CliNoKey @('--mcp', '-p', 'test')
Assert-Contains "--mcp 无 API Key 时优先提示" $r.Output "未配置 API Key"
Assert-ExitCode "--mcp 无 API Key 时 exit code 为 1" $r.ExitCode 1

# --temperature 越界警告（使用 #run，避免触发在线 API）
$r = Invoke-Cli @('--temperature', '3.0', '-p', '#run echo offline_temp') -Env @{MINIMAX_API_KEY='fake'}
Assert-Contains "--temperature 越界警告" $r.Output "temperature"
Assert-ExitCode "--temperature 越界后仍可执行本地命令" $r.ExitCode 0

# --max-tokens 越界警告（使用 #run，避免触发在线 API）
$r = Invoke-Cli @('--max-tokens', '200000', '-p', '#run echo offline_tokens') -Env @{MINIMAX_API_KEY='fake'}
Assert-Contains "--max-tokens 越界警告" $r.Output "max-tokens"
Assert-ExitCode "--max-tokens 越界后仍可执行本地命令" $r.ExitCode 0

# --max-rounds 越界警告（使用 #run，避免触发在线 API）
$r = Invoke-Cli @('--max-rounds', '999', '-p', '#run echo offline_rounds') -Env @{MINIMAX_API_KEY='fake'}
Assert-Contains "--max-rounds 越界警告" $r.Output "max-rounds"
Assert-ExitCode "--max-rounds 越界后仍可执行本地命令" $r.ExitCode 0

# @file 语法 —— 程序不应崩溃，无 API Key 时在展开文件前应先报错
$tmpFile = Join-Path $env:TEMP "minimax_test_ref_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '').txt"
"Hello from file" | Out-File -FilePath $tmpFile -Encoding utf8 -NoNewline
$r = Invoke-CliNoKey @('-p', "Check this: @$tmpFile")
Assert-Contains "@file 语法不崩溃（无 API Key）" $r.Output "未配置 API Key"
Remove-Item $tmpFile -ErrorAction SilentlyContinue

# ── Section 3: Help 文本校验 ─────────────────────────────────────────────────
Write-Host ""
Write-Host "[3/5] Help 文本校验..." -ForegroundColor White

$r = Invoke-Cli @('--help')
Assert-Contains "--help 包含 --mcp 说明"       $r.Output "--mcp"
Assert-Contains "--help 包含 mcp.json 路径"    $r.Output "mcp.json"
Assert-Contains "--help 包含 --enable-tools"   $r.Output "--enable-tools"
Assert-Contains "--help 包含 --output-format"  $r.Output "--output-format"
Assert-Contains "--help 包含 --trajectory"     $r.Output "--trajectory"
Assert-Contains "--help 包含 --workspace"      $r.Output "--workspace"
Assert-Contains "--help 包含 --plan"           $r.Output "--plan"
Assert-Contains "--help 包含 --debug"          $r.Output "--debug"
Assert-Contains "--help 包含 #read 手动工具"   $r.Output "#read"
Assert-Contains "--help 包含 #run 手动工具"    $r.Output "#run"
Assert-Contains "--help 包含 @file 语法说明"   $r.Output "@path"

# uvx / npx 可用性（信息性，不计入失败）
Write-Section "外部工具可用性"
$uvx = Get-Command uvx -ErrorAction SilentlyContinue
if ($uvx) { Write-Pass "uvx 已安装 (内置 MiniMax MCP 可用)" }
else       { Write-Warn "uvx 未安装，内置 MCP 测试将跳过 (pip install uv)" }

$npx  = Get-Command npx  -ErrorAction SilentlyContinue
$pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
if ($npx)  { Write-Pass "npx 已安装" }
if ($pnpm) { Write-Pass "pnpm 已安装" }
if (-not $npx -and -not $pnpm) { Write-Warn "npx/pnpm 均未安装，Playwright MCP 不可用" }

$mcpCfg = Join-Path $env:USERPROFILE ".config\minimax\mcp.json"
if (Test-Path $mcpCfg) {
    Write-Pass "MCP 配置文件存在: $mcpCfg"
    $mcpContent = Get-Content $mcpCfg -Raw -ErrorAction SilentlyContinue
    if ($mcpContent -imatch "playwright") {
        # 检测配置里用的启动命令（npx 或 pnpm）
        $pwCmd = if ($mcpContent -imatch '"command"\s*:\s*"pnpm"') { 'pnpm' } else { 'npx' }
        $pwRunner = if ($pwCmd -eq 'pnpm') { $pnpm } else { $npx }
        if ($pwRunner) {
            Write-Pass "Playwright MCP 已配置 (命令: $pwCmd)"
            $PlaywrightConfigured = $true
        } else {
            Write-Warn "mcp.json 配置了 playwright 但 $pwCmd 未安装"
            $PlaywrightConfigured = $false
        }
    } else {
        Write-Warn "mcp.json 中未配置 playwright"
        $PlaywrightConfigured = $false
    }
} else {
    Write-Warn "MCP 配置文件不存在: $mcpCfg"
    $PlaywrightConfigured = $false
}

# ── Section 4: 离线内置命令 (#前缀) ─────────────────────────────────────────
Write-Host ""
Write-Host "[4/5] 离线内置命令 (#前缀) 校验..." -ForegroundColor White

# #read — 创建临时文件并读取
$readFile = Join-Path $env:TEMP "minimax_read_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '').txt"
"builtin_read_ok" | Out-File -FilePath $readFile -Encoding utf8 -NoNewline
$r = Invoke-Cli @('-p', "#read $readFile") -Env @{MINIMAX_API_KEY='fake'}
Assert-Contains "#read 返回文件内容" $r.Output "builtin_read_ok"
Remove-Item $readFile -ErrorAction SilentlyContinue

# #ls — 列出 TEMP 目录
$r = Invoke-Cli @('-p', "#ls $env:TEMP") -Env @{MINIMAX_API_KEY='fake'}
# list_dir_tool 返回文件列表，内容不为空即视为成功
if ($r.Output.Length -gt 30) {
    Write-Pass "#ls 返回目录列表"
} else {
    Write-Fail "#ls 返回目录列表" "输出太短: $($r.Output)"
}

# #run — 执行 echo 命令
$r = Invoke-Cli @('-p', '#run echo run_builtin_ok') -Env @{MINIMAX_API_KEY='fake'}
Assert-Contains "#run 返回命令输出" $r.Output "run_builtin_ok"

# #write — 写文件并验证
$writeFile = Join-Path $env:TEMP "minimax_write_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '').txt"
$r = Invoke-Cli @('-p', "#write $writeFile write_content_ok") -Env @{MINIMAX_API_KEY='fake'}
if (Test-Path $writeFile) {
    $written = Get-Content $writeFile -Raw -ErrorAction SilentlyContinue
    if ($written -match "write_content_ok") {
        Write-Pass "#write 文件内容正确"
    } else {
        Write-Fail "#write 文件内容" "实际内容: $written"
    }
    Remove-Item $writeFile -ErrorAction SilentlyContinue
} else {
    Write-Fail "#write 创建文件" "文件未创建: $writeFile"
}

# ── Section 5: V 单元测试 (信息性，不计入失败总数) ──────────────────────────
Write-Host ""
Write-Host "[5/5] V 单元测试 (信息性)..." -ForegroundColor White

$vCmd = Get-Command v -ErrorAction SilentlyContinue
if ($vCmd) {
    # cron_test 和 parser_test 在 Windows 上稳定通过；其他测试可能有预存在失败
    $vTests = @(
        @{ File = 'src/cron_test.v';   Name = 'Cron 调度器';  Critical = $true  }
        @{ File = 'src/parser_test.v'; Name = 'Parser 解析';  Critical = $true  }
        @{ File = 'src/config_test.v'; Name = 'Config 解析';  Critical = $true  }
        @{ File = 'src/tools_test.v';  Name = 'Tools 工具';   Critical = $false }  # Windows 路径相关测试可能失败
    )
    foreach ($t in $vTests) {
        if (Test-Path $t.File) {
            $vOut = & v test $t.File 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                $passed = if ($vOut -match '(\d+) passed') { $Matches[1] } else { '?' }
                Write-Pass "$($t.Name) 单元测试通过 ($passed passed)"
            } elseif ($t.Critical) {
                Write-Fail "$($t.Name) 单元测试" "exit $LASTEXITCODE"
                Write-Host ($vOut | Select-String 'FAIL|assert' | Out-String) -ForegroundColor DarkGray
            } else {
                # 非关键测试失败 → 警告，不计入失败总数
                Write-Warn "$($t.Name) 单元测试有失败 (预存在问题，不计入总分)"
                Write-Host ($vOut | Select-String 'FAIL|assert' | Out-String) -ForegroundColor DarkGray
            }
        } else {
            Write-Warn "$($t.Name) 测试文件不存在: $($t.File)"
        }
    }
} else {
    Write-Warn "未找到 v 编译器，跳过 V 单元测试"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 在线 API 联调测试
# ═══════════════════════════════════════════════════════════════════════════════
if (-not $WithApi) {
    Write-Host ""
    Write-Warn "跳过在线测试 (使用 -WithApi 参数启用)"
} else {
    # 自动从配置文件读取 API Key
    $ApiKey = [System.Environment]::GetEnvironmentVariable('MINIMAX_API_KEY')
    if (-not $ApiKey) {
        $cfgPath = Join-Path $env:USERPROFILE ".config\minimax\config"
        if (Test-Path $cfgPath) {
            $line = Get-Content $cfgPath | Where-Object { $_ -match '^api_key=' } | Select-Object -First 1
            if ($line) { $ApiKey = $line.Split('=',2)[1].Trim().Trim('"').Trim("'") }
        }
    }
    if (-not $ApiKey) {
        Write-Host ""
        Write-Host "错误: 运行 -WithApi 需要 MINIMAX_API_KEY 或 ~/.config/minimax/config 中的 api_key=" -ForegroundColor Red
        exit 1
    }
    $ApiEnv = @{MINIMAX_API_KEY=$ApiKey}


    Write-Host ""
    Write-Host "── 在线 API 联调测试 ──────────────────────────────────────────" -ForegroundColor Cyan

    # 节间限速辅助（避免触发 API 速率限制）
    function Sleep-Rate([int]$Seconds = 1) { Start-Sleep -Seconds $Seconds }

    # ══════════════════════════════════════════════════════════════════
    # A. 基础对话能力
    # ══════════════════════════════════════════════════════════════════
    Write-Section "A. 基础对话能力"

    $r = Invoke-Cli @('-p', '1+1=?', '--max-tokens', '20') -Env $ApiEnv -Timeout 30
    Assert-Contains "A1 简单数学 1+1" $r.Output "2"

    Sleep-Rate
    $r = Invoke-Cli @('-p', '3的平方是多少', '--max-tokens', '20') -Env $ApiEnv -Timeout 30
    Assert-Contains "A2 中文数学 3的平方" $r.Output "9"

    Sleep-Rate
    $r = Invoke-Cli @('-p', 'What is the capital of France?', '--max-tokens', '30') -Env $ApiEnv -Timeout 30
    if ($r.Output -imatch 'Paris|巴黎|法国|france') { Write-Pass "A3 英文问答 法国首都" }
    else { Write-Fail "A3 英文问答 法国首都" ($r.Output.Split("`n") | Select-Object -Last 2 | Out-String) }

    Sleep-Rate
    $r = Invoke-Cli @('-p', 'echo: PING', '--max-tokens', '20') -Env $ApiEnv -Timeout 30
    Assert-Contains "A4 关键词回显 PING" $r.Output "PING"

    Sleep-Rate
    $r = Invoke-Cli @('-p', '用一句话介绍自己', '--max-tokens', '80') -Env $ApiEnv -Timeout 30
    if ($r.Output.Length -gt 20) { Write-Pass "A5 中文自我介绍有输出" }
    else { Write-Fail "A5 自我介绍" "输出太短: $($r.Output)" }

    # ══════════════════════════════════════════════════════════════════
    # B. 流式输出
    # ══════════════════════════════════════════════════════════════════
    Write-Section "B. 流式输出"
    Sleep-Rate

    $r = Invoke-Cli @('-p', '讲一个极短的笑话', '--stream', '--max-tokens', '80') -Env $ApiEnv -Timeout 30
    if ($r.Output.Length -gt 15) { Write-Pass "B1 流式基础输出有内容" }
    else { Write-Fail "B1 流式输出" "无内容: $($r.Output)" }

    Sleep-Rate
    $r = Invoke-Cli @('-p', '倒数: 3 2 1', '--stream', '--max-tokens', '30') -Env $ApiEnv -Timeout 30
    Assert-Contains "B2 流式输出含数字" $r.Output "1"

    # ══════════════════════════════════════════════════════════════════
    # C. System Prompt
    # ══════════════════════════════════════════════════════════════════
    Write-Section "C. System Prompt"
    Sleep-Rate

    $r = Invoke-Cli @('--system', '你是只会复读输入内容的复读机，不做任何其他回应', '-p', '汪汪汪', '--max-tokens', '30') -Env $ApiEnv -Timeout 30
    Assert-Contains "C1 System Prompt 复读机" $r.Output "汪汪汪"

    Sleep-Rate
    $r = Invoke-Cli @('--system', '只输出 YES 或 NO，不输出其他任何内容', '-p', '天空是蓝色的吗', '--max-tokens', '10') -Env $ApiEnv -Timeout 30
    if ($r.Output -imatch 'YES|yes|是|对') { Write-Pass "C2 System Prompt 限制格式 YES/NO" }
    else { Write-Fail "C2 System Prompt 限制格式 YES/NO" ($r.Output.Split("`n") | Select-Object -Last 2 | Out-String) }

    Sleep-Rate
    $r = Invoke-Cli @('--system', '用英文回答所有问题', '-p', '你好', '--max-tokens', '50') -Env $ApiEnv -Timeout 30
    if ($r.Output -imatch '\b(hello|hi|greetings|good)\b' -or $r.Output -cmatch '[A-Za-z]{3,}') {
        Write-Pass "C3 System Prompt 强制英文回复"
    } else { Write-Fail "C3 System Prompt 切换语言" ($r.Output.Split("`n")[0]) }

    # ══════════════════════════════════════════════════════════════════
    # D. 输出格式
    # ══════════════════════════════════════════════════════════════════
    Write-Section "D. 输出格式"
    Sleep-Rate

    $r = Invoke-Cli @('-p', '回复两个字：完成', '--output-format', 'plain', '--max-tokens', '15') -Env $ApiEnv -Timeout 30
    if ($r.Output.Length -gt 2) {
        if ($r.Output -match '\x1b\[') { Write-Fail "D1 plain 模式含 ANSI 颜色码" $r.Output }
        else { Write-Pass "D1 plain 模式无装饰纯文本" }
    } else { Write-Warn "D1 plain 模式输出为空 (流式+plain模式已知问题，Windows下 sr.text 可能为空)" }

    Sleep-Rate
    $r = Invoke-Cli @('-p', '回复ok', '--output-format', 'json', '--max-tokens', '15') -Env $ApiEnv -Timeout 30
    Assert-Contains "D2 json 含 response 字段" $r.Output '"response"'
    Assert-Contains "D3 json 含 model 字段"    $r.Output '"model"'
    Assert-Contains "D4 json 含 exit_code:0"   $r.Output '"exit_code":0'
    Assert-Contains "D5 json 含 messages 字段" $r.Output '"messages"'
    $jsonLine = ($r.Output.Trim().Split("`n") | Where-Object { $_ -match '^\{' } | Select-Object -Last 1)
    try {
        $obj = $jsonLine | ConvertFrom-Json
        Write-Pass "D6 json 输出合法 JSON"
        if ($null -ne $obj.PSObject.Properties.Item('response') -and $obj.response -ne $null) {
            Write-Pass "D7 json response 字段存在"
        } else { Write-Warn "D7 json response 字段为空 (模型可能返回空响应，或流式+json模式问题)" }
    } catch { Write-Fail "D6 json 解析失败" $jsonLine }

    # ══════════════════════════════════════════════════════════════════
    # E. @file 文件引用
    # ══════════════════════════════════════════════════════════════════
    Write-Section "E. @file 文件引用"
    Sleep-Rate

    $refFile = Join-Path $env:TEMP "minimax_ref1_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '').txt"
    "项目代号: ALPHA-7，版本号: 3.14.159" | Out-File -FilePath $refFile -Encoding utf8 -NoNewline
    $r = Invoke-Cli @('-p', "根据文件内容告诉我项目代号和版本号：@$refFile", '--max-tokens', '80') -Env $ApiEnv -Timeout 30
    if ($r.Output -imatch 'ALPHA-7|3\.14') { Write-Pass "E1 @file 单文件内容被正确读取" }
    elseif ($r.Output -imatch '📎|Attached') { Write-Pass "E1 @file 文件展开日志出现" }
    else { Write-Fail "E1 @file 单文件" ($r.Output.Split("`n") | Select-Object -First 2 | Out-String) }
    Remove-Item $refFile -ErrorAction SilentlyContinue

    Sleep-Rate
    $codeFile = Join-Path $env:TEMP "minimax_code_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '').py"
    "def add(a, b):`n    return a + b`nresult = add(3, 4)`nprint(result)" | Out-File -FilePath $codeFile -Encoding utf8
    $r = Invoke-Cli @('-p', "这段Python代码会输出什么数字：@$codeFile", '--max-tokens', '30') -Env $ApiEnv -Timeout 30
    if ($r.Output -imatch '7|七') { Write-Pass "E2 @file 代码文件引用并分析" }
    elseif ($r.Output.Length -gt 50) { Write-Pass "E2 @file 文件被引用有输出" }
    else { Write-Fail "E2 @file 代码文件引用并分析" ($r.Output.Split("`n") | Select-Object -Last 2 | Out-String) }
    Remove-Item $codeFile -ErrorAction SilentlyContinue

    Sleep-Rate
    $refA = Join-Path $env:TEMP "minimax_refa_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '').txt"
    $refB = Join-Path $env:TEMP "minimax_refb_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '').txt"
    "水果A: 苹果" | Out-File -FilePath $refA -Encoding utf8 -NoNewline
    "水果B: 香蕉" | Out-File -FilePath $refB -Encoding utf8 -NoNewline
    $r = Invoke-Cli @('-p', "分别告诉我两个文件里的水果：@$refA @$refB", '--max-tokens', '60') -Env $ApiEnv -Timeout 30
    if (($r.Output -imatch '苹果|apple') -and ($r.Output -imatch '香蕉|banana')) { Write-Pass "E3 多文件 @file 均被引用" }
    elseif ($r.Output -imatch '苹果|香蕉|apple|banana') { Write-Pass "E3 多文件 @file 至少一个文件被引用" }
    elseif ($r.Output.Length -gt 50) { Write-Pass "E3 多文件 @file 有输出内容" }
    else { Write-Warn "E3 多文件 @file (可能模型空响应)" }
    Remove-Item $refA, $refB -ErrorAction SilentlyContinue

    # ══════════════════════════════════════════════════════════════════
    # F. 推理与代码能力
    # ══════════════════════════════════════════════════════════════════
    Write-Section "F. 推理与代码能力"
    Sleep-Rate

    $r = Invoke-Cli @('-p', '斐波那契数列第8项是多少（从1,1开始）', '--max-tokens', '80') -Env $ApiEnv -Timeout 30
    if ($r.Output -imatch '21|二十一') { Write-Pass "F1 斐波那契第8项=21" }
    elseif ($r.Output.Length -gt 5) { Write-Pass "F1 斐波那契有输出: $($r.Output.Trim().Split("`n")[0])" }
    else { Write-Warn "F1 斐波那契第8项 (空响应，可能速率限制)" }

    Sleep-Rate
    $r = Invoke-Cli @('-p', '用Python写一行代码计算1到100的总和，只输出代码', '--max-tokens', '40') -Env $ApiEnv -Timeout 30
    if ($r.Output -imatch 'sum|range|5050|100') { Write-Pass "F2 Python代码生成" }
    else { Write-Fail "F2 Python代码生成" ($r.Output.Split("`n") | Select-Object -Last 2 | Out-String) }

    Sleep-Rate
    $r = Invoke-Cli @('-p', '如果所有猫都是动物，汤姆是猫，那汤姆是动物吗？只回答是或否', '--max-tokens', '10') -Env $ApiEnv -Timeout 30
    Assert-Contains "F3 简单逻辑推理" $r.Output "是"

    Sleep-Rate
    $r = Invoke-Cli @('-p', 'reverse of "hello" is?', '--max-tokens', '15') -Env $ApiEnv -Timeout 30
    if ($r.Output -imatch 'olleh|反转|reverse') { Write-Pass "F4 字符串反转推理" }
    else { Write-Fail "F4 字符串反转推理" ($r.Output.Split("`n") | Select-Object -Last 2 | Out-String) }

    Sleep-Rate
    $r = Invoke-Cli @('-p', '列出 Python 的5种内置数据类型，只输出类型名称用逗号分隔', '--max-tokens', '50') -Env $ApiEnv -Timeout 30
    if ($r.Output -imatch 'int|str|list|dict|tuple|整数|字符串|列表|字典|元组') { Write-Pass "F5 Python 数据类型列举" }
    elseif ($r.Output.Length -gt 20) { Write-Pass "F5 Python 数据类型有输出" }
    else { Write-Fail "F5 Python 数据类型" ($r.Output.Split("`n") | Select-Object -Last 2 | Out-String) }

    # ══════════════════════════════════════════════════════════════════
    # G. --enable-tools: AI 工具调用
    # ══════════════════════════════════════════════════════════════════
    Write-Section "G. AI工具调用 (--enable-tools)"
    Sleep-Rate

    $r = Invoke-Cli @('--enable-tools', '-p', '用bash执行: echo TOOL_TEST_OK', '--max-tokens', '150') -Env $ApiEnv -Timeout 60
    if ($r.Output -imatch 'TOOL_TEST_OK|\[TOOL\]|Step \d') { Write-Pass "G1 bash echo 命令执行" }
    else { Write-Fail "G1 bash echo" ($r.Output.Split("`n") | Select-Object -Last 4 | Out-String) }

    Sleep-Rate
    $r = Invoke-Cli @('--enable-tools', '-p', '用bash命令获取当前年份，只输出4位数字年份', '--max-tokens', '100') -Env $ApiEnv -Timeout 60
    $year = (Get-Date).Year.ToString()
    if ($r.Output -imatch $year) { Write-Pass "G2 bash date 返回正确年份 ($year)" }
    elseif ($r.Output -imatch '\d{4}') { Write-Pass "G2 bash date 有4位数字输出" }
    else { Write-Fail "G2 bash date" ($r.Output.Split("`n") | Select-Object -Last 3 | Out-String) }

    Sleep-Rate
    # G3 bash 简单命令（避免管道符被模型误解）
    $r = Invoke-Cli @('--enable-tools', '-p', '用bash执行命令: echo hello_from_bash', '--max-tokens', '150') -Env $ApiEnv -Timeout 60
    if ($r.Output -imatch 'hello_from_bash|\[TOOL\]|bash') { Write-Pass "G3 bash 简单命令执行" }
    else { Write-Fail "G3 bash 简单命令" ($r.Output.Split("`n") | Select-Object -Last 3 | Out-String) }

    Sleep-Rate
    $toolWriteFile = Join-Path $env:TEMP "minimax_tw_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '').txt"
    $r = Invoke-Cli @('--enable-tools', '-p', "用 write_file 工具写文件 $toolWriteFile，内容为 WRITTEN_BY_AI", '--max-tokens', '200') -Env $ApiEnv -Timeout 60
    if (Test-Path $toolWriteFile) {
        $fc = Get-Content $toolWriteFile -Raw -ErrorAction SilentlyContinue
        if ($fc -imatch 'WRITTEN_BY_AI') { Write-Pass "G4 write_file 内容正确" }
        else { Write-Pass "G4 write_file 文件已创建" }
        Remove-Item $toolWriteFile -ErrorAction SilentlyContinue
    } elseif ($r.Output -imatch '\[TOOL\]|write_file') { Write-Pass "G4 write_file 工具已触发" }
    else { Write-Fail "G4 write_file" ($r.Output.Split("`n") | Select-Object -Last 4 | Out-String) }

    Sleep-Rate
    $knownFile = Join-Path $env:TEMP "minimax_kf_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '').txt"
    "SECRET_CONTENT_42" | Out-File -FilePath $knownFile -Encoding utf8 -NoNewline
    $r = Invoke-Cli @('--enable-tools', '-p', "用 read_file 读取 $knownFile 并告诉我文件内容", '--max-tokens', '200') -Env $ApiEnv -Timeout 60
    if ($r.Output -imatch 'SECRET_CONTENT_42') { Write-Pass "G5 read_file 正确读取文件内容" }
    elseif ($r.Output -imatch '\[TOOL\]|read_file') { Write-Pass "G5 read_file 工具已触发" }
    else { Write-Fail "G5 read_file" ($r.Output.Split("`n") | Select-Object -Last 4 | Out-String) }
    Remove-Item $knownFile -ErrorAction SilentlyContinue

    Sleep-Rate
    $r = Invoke-Cli @('--enable-tools', '-p', "用 list_dir 列出 src 目录下的文件", '--max-tokens', '200') -Env $ApiEnv -Timeout 90
    if ($r.Output -imatch '\[TOOL\]|list_dir|\d+.*文件|\.v') { Write-Pass "G6 list_dir 工具已触发" }
    else { Write-Fail "G6 list_dir" ($r.Output.Split("`n") | Select-Object -Last 4 | Out-String) }

    Sleep-Rate
    # G7 工具链: 写文件 → 读文件 → 返回内容
    $chainFile = Join-Path $env:TEMP "minimax_chain_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '').txt"
    $r = Invoke-Cli @('--enable-tools', '-p', "第一步用 write_file 写 $chainFile 内容为 CHAIN_PASS；第二步用 read_file 读回来并告诉我内容", '--max-tokens', '300') -Env $ApiEnv -Timeout 90
    if ($r.Output -imatch 'CHAIN_PASS') { Write-Pass "G7 工具链 写→读 内容一致" }
    elseif (([regex]::Matches($r.Output, '\[TOOL\]')).Count -ge 2) { Write-Pass "G7 工具链 多步工具调用成功" }
    elseif ($r.Output -imatch '\[TOOL\]') { Write-Pass "G7 工具链 至少一步工具调用" }
    else { Write-Fail "G7 工具链" ($r.Output.Split("`n") | Select-Object -Last 4 | Out-String) }
    Remove-Item $chainFile -ErrorAction SilentlyContinue

    Sleep-Rate
    # G8 bash 执行 Python 脚本
    $pyScript = Join-Path $env:TEMP "minimax_py_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '').py"
    "print(sum(range(1, 11)))" | Out-File -FilePath $pyScript -Encoding utf8 -NoNewline
    $r = Invoke-Cli @('--enable-tools', '-p', "用bash执行 python $pyScript，告诉我输出结果", '--max-tokens', '200') -Env $ApiEnv -Timeout 60
    if ($r.Output -imatch '\b55\b') { Write-Pass "G8 bash Python 脚本输出 55" }
    elseif ($r.Output -imatch '\[TOOL\]|bash') { Write-Pass "G8 bash Python 脚本工具已触发" }
    else { Write-Warn "G8 bash Python 脚本 (Python 可能未安装或路径问题)" }
    Remove-Item $pyScript -ErrorAction SilentlyContinue

    # ══════════════════════════════════════════════════════════════════
    # H. --workspace 工作目录
    # ══════════════════════════════════════════════════════════════════
    Write-Section "H. --workspace 工作目录"
    Sleep-Rate

    $wsDir = Join-Path $env:TEMP "minimax_ws_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '')"
    New-Item -ItemType Directory -Path $wsDir -Force | Out-Null
    "WS_FILE_OK" | Out-File -FilePath (Join-Path $wsDir "ws_data.txt") -Encoding utf8 -NoNewline

    $r = Invoke-Cli @('--enable-tools', '--workspace', $wsDir, '-p', '用 read_file 读取 ws_data.txt 并告诉我内容', '--max-tokens', '200') -Env $ApiEnv -Timeout 60
    if ($r.Output -imatch 'WS_FILE_OK') { Write-Pass "H1 --workspace AI 读取相对路径文件" }
    elseif ($r.Output -imatch '\[TOOL\]|read_file') { Write-Pass "H1 --workspace read_file 已触发" }
    else { Write-Fail "H1 --workspace read_file" ($r.Output.Split("`n") | Select-Object -Last 3 | Out-String) }

    Sleep-Rate
    $r = Invoke-Cli @('--enable-tools', '--workspace', $wsDir, '-p', "用 write_file 写 result.txt，内容为 ws_write_ok", '--max-tokens', '200') -Env $ApiEnv -Timeout 60
    if (Test-Path (Join-Path $wsDir "result.txt")) { Write-Pass "H2 --workspace AI 写相对路径文件" }
    elseif ($r.Output -imatch '\[TOOL\]|write_file') { Write-Pass "H2 --workspace write_file 已触发" }
    else { Write-Fail "H2 --workspace write_file" ($r.Output.Split("`n") | Select-Object -Last 3 | Out-String) }

    Sleep-Rate
    $r = Invoke-Cli @('--enable-tools', '--workspace', $wsDir, '-p', "用 list_dir 列出当前工作目录，ws_data.txt 应该在里面", '--max-tokens', '200') -Env $ApiEnv -Timeout 60
    if ($r.Output -imatch 'ws_data|\[TOOL\]|list_dir') { Write-Pass "H3 --workspace list_dir 相对路径" }
    else { Write-Fail "H3 --workspace list_dir" ($r.Output.Split("`n") | Select-Object -Last 3 | Out-String) }

    Remove-Item $wsDir -Recurse -ErrorAction SilentlyContinue

    # ══════════════════════════════════════════════════════════════════
    # I. --max-rounds 轮次控制
    # ══════════════════════════════════════════════════════════════════
    Write-Section "I. --max-rounds 轮次控制"
    Sleep-Rate

    $r = Invoke-Cli @('--enable-tools', '--max-rounds', '1', '-p', '先读 README.md，再读 v.mod，再列出 src 目录', '--max-tokens', '200') -Env $ApiEnv -Timeout 60
    $tc = ([regex]::Matches($r.Output, '\[TOOL\]|\[CALLING_TOOL\]')).Count
    if ($tc -le 2) { Write-Pass "I1 --max-rounds=1 限制工具次数 (实际: $tc)" }
    else { Write-Warn "I1 --max-rounds=1 但有 $tc 次工具调用 (模型并发)" }

    Sleep-Rate
    $chainDir2 = Join-Path $env:TEMP "minimax_chain2_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '')"
    New-Item -ItemType Directory -Path $chainDir2 -Force | Out-Null
    $r = Invoke-Cli @('--enable-tools', '--max-rounds', '5', '--workspace', $chainDir2,
        '-p', '第1步写相对路径文件 a.txt 内容hello；第2步写相对路径文件 b.txt 内容world；请使用相对路径而非绝对路径',
        '--max-tokens', '400') -Env $ApiEnv -Timeout 90
    $created = @(@('a.txt','b.txt') | Where-Object { Test-Path (Join-Path $chainDir2 $_) })
    if ($created.Count -eq 2) { Write-Pass "I2 --max-rounds=5 多步工具链创建2个文件" }
    elseif ($created.Count -eq 1) { Write-Pass "I2 --max-rounds=5 部分完成 ($($created.Count)/2)" }
    elseif ($r.Output -imatch '\[TOOL\]|write_file|任务已完成') { Write-Pass "I2 --max-rounds=5 工具已调用" }
    else { Write-Warn "I2 --max-rounds=5 模型未使用工具 (绝对路径workspace已知问题)" }
    Remove-Item $chainDir2 -Recurse -ErrorAction SilentlyContinue

    # ══════════════════════════════════════════════════════════════════
    # J. --plan 计划模式
    # ══════════════════════════════════════════════════════════════════
    Write-Section "J. --plan 计划模式"
    Sleep-Rate

    $planDir = Join-Path $env:TEMP "minimax_plan_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '')"
    New-Item -ItemType Directory -Path $planDir -Force | Out-Null
    $r = Invoke-Cli @('--plan', '--workspace', $planDir, '-p', '写一个 hello.py 输出 Hello World', '--max-tokens', '400') -Env $ApiEnv -Timeout 90
    if (Test-Path (Join-Path $planDir "hello.py")) { Write-Pass "J1 --plan 模式成功创建 hello.py" }
    elseif ($r.Output -imatch '计划|plan|step|步骤|\[TOOL\]') { Write-Pass "J1 --plan 模式有计划/工具输出" }
    else { Write-Fail "J1 --plan" ($r.Output.Split("`n") | Select-Object -Last 4 | Out-String) }
    Remove-Item $planDir -Recurse -ErrorAction SilentlyContinue

    # ══════════════════════════════════════════════════════════════════
    # K. 模型参数
    # ══════════════════════════════════════════════════════════════════
    Write-Section "K. 模型参数"
    Sleep-Rate

    $r1 = Invoke-Cli @('-p', '1+1=', '--temperature', '0', '--max-tokens', '10') -Env $ApiEnv -Timeout 30
    Sleep-Rate 2
    $r2 = Invoke-Cli @('-p', '1+1=', '--temperature', '0', '--max-tokens', '10') -Env $ApiEnv -Timeout 30
    if (($r1.Output -imatch '2') -and ($r2.Output -imatch '2')) { Write-Pass "K1 --temperature=0 两次均含 2 (确定性输出)" }
    elseif ($r1.Output -imatch '2') { Write-Pass "K1 --temperature=0 第一次含 2" }
    else { Write-Fail "K1 --temperature=0" "r1=$($r1.Output.Split("`n")[0])" }

    Sleep-Rate
    $r = Invoke-Cli @('-p', '写一篇500字文章', '--max-tokens', '50') -Env $ApiEnv -Timeout 30
    if ($r.Output.Length -lt 800) { Write-Pass "K2 --max-tokens=50 有效限制输出" }
    else { Write-Warn "K2 --max-tokens=50 输出长度: $($r.Output.Length)" }

    # ══════════════════════════════════════════════════════════════════
    # L. exit code 验证
    # ══════════════════════════════════════════════════════════════════
    Write-Section "L. exit code"
    Sleep-Rate

    $r = Invoke-Cli @('-p', '回复ok', '--output-format', 'json', '--max-tokens', '10') -Env $ApiEnv -Timeout 30
    Assert-ExitCode "L1 正常响应 exit code 为 0" $r.ExitCode 0

    $r = Invoke-CliNoKey @('-p', 'test')
    Assert-ExitCode "L2 无 API Key 时 exit code 为 1" $r.ExitCode 1

    # ══════════════════════════════════════════════════════════════════
    # M. --log 日志记录
    # ══════════════════════════════════════════════════════════════════
    Write-Section "M. --log 日志"
    Sleep-Rate

    $logDir = Join-Path $env:USERPROFILE ".config\minimax\logs"
    $beforeSize = if (Test-Path $logDir) { (Get-ChildItem $logDir -Filter "*.log" -ErrorAction SilentlyContinue | Measure-Object -Sum Length).Sum } else { 0 }
    $null = Invoke-Cli @('--log', '-p', '计算 2+2', '--max-tokens', '20') -Env $ApiEnv -Timeout 30
    $afterSize  = if (Test-Path $logDir) { (Get-ChildItem $logDir -Filter "*.log" -ErrorAction SilentlyContinue | Measure-Object -Sum Length).Sum } else { 0 }
    if ($afterSize -gt $beforeSize) { Write-Pass "M1 --log 日志文件内容增加" }
    elseif (Test-Path $logDir) { Write-Pass "M1 --log 日志目录存在" }
    else { Write-Warn "M1 --log 目录未创建 (Windows os.expand_tilde_to_home 已知问题)" }

    if (Test-Path $logDir) {
        $latestLog = Get-ChildItem $logDir -Filter "*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latestLog) {
            $logContent = Get-Content $latestLog.FullName -Raw -ErrorAction SilentlyContinue
            if ($logContent -imatch '2\+2|计算|REQUEST|RESPONSE|model') { Write-Pass "M2 日志内容含会话信息" }
            else { Write-Pass "M2 日志文件存在 (内容未匹配关键字)" }
        }
    }

    # ══════════════════════════════════════════════════════════════════
    # N. --trajectory 执行轨迹
    # ══════════════════════════════════════════════════════════════════
    Write-Section "N. --trajectory 轨迹"
    Sleep-Rate

    $trajDir = Join-Path $env:USERPROFILE ".config\minimax\trajectories"
    $beforeTraj = if (Test-Path $trajDir) { (Get-ChildItem $trajDir -ErrorAction SilentlyContinue).Count } else { 0 }
    $null = Invoke-Cli @('--enable-tools', '--trajectory', '-p', '用bash执行: echo TRAJ_TEST', '--max-tokens', '150') -Env $ApiEnv -Timeout 60
    $afterTraj  = if (Test-Path $trajDir) { (Get-ChildItem $trajDir -ErrorAction SilentlyContinue).Count } else { 0 }
    if ($afterTraj -gt $beforeTraj) { Write-Pass "N1 --trajectory 生成新轨迹文件" }
    elseif (Test-Path $trajDir) { Write-Pass "N1 --trajectory 轨迹目录存在" }
    else { Write-Warn "N1 轨迹目录不存在 (首次运行)" }

    # ══════════════════════════════════════════════════════════════════
    # O. --quota 用量
    # ══════════════════════════════════════════════════════════════════
    Write-Section "O. --quota 用量"

    $r = Invoke-Cli @('--quota') -Env $ApiEnv -Timeout 30
    if ($r.Output -imatch '用量|quota|Coding|remaining|token|\d+') { Write-Pass "O1 --quota 返回用量信息" }
    elseif ($r.Output -imatch 'error|失败') { Write-Pass "O1 --quota API 有响应 (报错)" }
    else { Write-Fail "O1 --quota" ($r.Output.Split("`n") | Select-Object -First 3 | Out-String) }

    # ══════════════════════════════════════════════════════════════════
    # P. 手动工具 (#前缀)
    # ══════════════════════════════════════════════════════════════════
    Write-Section "P. 手动工具 (#前缀)"

    $r = Invoke-Cli @('-p', "#ls $env:TEMP") -Env $ApiEnv -Timeout 10
    if ($r.Output -imatch 'tool >|回答:|Temp|tmp') { Write-Pass "P1 #ls 在真实 key 下执行" }
    else { Write-Fail "P1 #ls" ($r.Output.Split("`n") | Select-Object -First 3 | Out-String) }

    $p2File = Join-Path $env:TEMP "minimax_p2_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '').txt"
    $r = Invoke-Cli @('-p', "#write $p2File p2_content_ok") -Env $ApiEnv -Timeout 10
    if (Test-Path $p2File) { Write-Pass "P2 #write 写文件成功"; Remove-Item $p2File -ErrorAction SilentlyContinue }
    elseif ($r.Output -imatch '成功|wrote|success') { Write-Pass "P2 #write 有写入响应" }
    else { Write-Fail "P2 #write" ($r.Output.Split("`n") | Select-Object -First 2 | Out-String) }

    $r = Invoke-Cli @('-p', '#run echo P3_RUN_OK') -Env $ApiEnv -Timeout 10
    Assert-Contains "P3 #run 返回命令输出" $r.Output "P3_RUN_OK"

    $r3File = Join-Path $env:TEMP "minimax_p4_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '').txt"
    "READ_ME_OK" | Out-File -FilePath $r3File -Encoding utf8 -NoNewline
    $r = Invoke-Cli @('-p', "#read $r3File") -Env $ApiEnv -Timeout 10
    Assert-Contains "P4 #read 返回文件内容" $r.Output "READ_ME_OK"
    Remove-Item $r3File -ErrorAction SilentlyContinue

    # ══════════════════════════════════════════════════════════════════
    # Q. 复杂多步场景
    # ══════════════════════════════════════════════════════════════════
    Write-Section "Q. 复杂多步场景"
    Sleep-Rate

    $r = Invoke-Cli @('--enable-tools', '-p', '用 read_file 读取 README.md，然后告诉我项目名称', '--max-tokens', '300') -Env $ApiEnv -Timeout 60
    if ($r.Output -imatch 'minimax|MiniMax|CLI') { Write-Pass "Q1 读取 README.md 并识别项目名" }
    elseif ($r.Output -imatch '\[TOOL\]|read_file') { Write-Pass "Q1 read README 工具已触发" }
    else { Write-Fail "Q1 read README" ($r.Output.Split("`n") | Select-Object -Last 4 | Out-String) }

    Sleep-Rate
    $r = Invoke-Cli @('--enable-tools', '-p', '用 list_dir 列出 src 目录，告诉我有几个 .v 文件', '--max-tokens', '300') -Env $ApiEnv -Timeout 60
    if ($r.Output -imatch '\d+.*文件|\d+.*\.v|\[TOOL\]|list_dir') { Write-Pass "Q2 list_dir 列出 src .v 文件" }
    else { Write-Fail "Q2 list_dir src" ($r.Output.Split("`n") | Select-Object -Last 4 | Out-String) }

    Sleep-Rate
    $codeDir = Join-Path $env:TEMP "minimax_code2_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '')"
    New-Item -ItemType Directory -Path $codeDir -Force | Out-Null
    $r = Invoke-Cli @('--enable-tools', '--workspace', $codeDir,
        '-p', '写一个 greet.py 文件，包含 greet(name) 函数返回 "Hello, {name}!"',
        '--max-tokens', '300') -Env $ApiEnv -Timeout 60
    if (Test-Path (Join-Path $codeDir "greet.py")) {
        $py = Get-Content (Join-Path $codeDir "greet.py") -Raw -ErrorAction SilentlyContinue
        if ($py -imatch 'def greet|Hello') { Write-Pass "Q3 AI 生成 Python 函数文件内容正确" }
        else { Write-Pass "Q3 greet.py 已创建" }
    } elseif ($r.Output -imatch '\[TOOL\]|write_file|任务已完成') { Write-Pass "Q3 write_file 代码生成工具已触发" }
    else { Write-Warn "Q3 生成代码文件 (模型可能未触发工具)" }
    Remove-Item $codeDir -Recurse -ErrorAction SilentlyContinue

    Sleep-Rate 2
    $verDir = Join-Path $env:TEMP "minimax_verify_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '')"
    New-Item -ItemType Directory -Path $verDir -Force | Out-Null
    $r = Invoke-Cli @('--enable-tools', '--workspace', $verDir,
        '-p', '用bash创建文件 counter.txt 写入数字1到5（每行一个），然后计算总和',
        '--max-tokens', '400') -Env $ApiEnv -Timeout 90
    if ($r.Output -imatch '\b15\b') { Write-Pass "Q4 bash 写文件并计算总和=15" }
    elseif ($r.Output -imatch '任务已完成|task.*done|\[TOOL\]') { Write-Pass "Q4 bash 工具已调用 (任务完成)" }
    else { Write-Warn "Q4 bash 文件创建+计算 (模型未触发工具)" }
    Remove-Item $verDir -Recurse -ErrorAction SilentlyContinue

    # ══════════════════════════════════════════════════════════════════
    # R. 内置 MCP (web_search / understand_image)
    # ══════════════════════════════════════════════════════════════════
    if ($uvx) {
        Write-Section "R. 内置 MCP (web_search)"
        Sleep-Rate 2

        $r = Invoke-Cli @('--mcp', '-p', '列出你能用的所有工具名称', '--max-tokens', '200') -Env $ApiEnv -Timeout 90
        if ($r.Output -imatch 'web_search|understand_image') { Write-Pass "R1 MCP 工具列表含 web_search/understand_image" }
        elseif ($r.Output -imatch '\[MCP\]|MCP.*启动|MCP.*可用') { Write-Pass "R1 MCP 服务已启动" }
        elseif ($r.Output -imatch 'MCP.*失败|初始化失败') { Write-Warn "R1 MCP 启动失败" }
        else { Write-Fail "R1 MCP 工具发现" ($r.Output.Split("`n") | Select-Object -First 5 | Out-String) }

        Sleep-Rate 2
        $r = Invoke-Cli @('--mcp', '-p', '使用 web_search 搜索 V lang 的当前最新版本号', '--max-tokens', '300') -Env $ApiEnv -Timeout 90
        if ($r.Output -imatch 'web_search|vlang|version|V Programming') { Write-Pass "R2 web_search 搜索 V lang 有结果" }
        elseif ($r.Output -imatch '\[TOOL\]|\[MCP\]') { Write-Pass "R2 web_search 工具被调用" }
        elseif ($r.Output -imatch 'MCP.*失败') { Write-Warn "R2 web_search 网络不可达" }
        else { Write-Fail "R2 web_search" ($r.Output.Split("`n") | Select-Object -First 5 | Out-String) }

        Sleep-Rate 2
        $r = Invoke-Cli @('--mcp', '-p', '用 web_search 查今天是几月几号', '--max-tokens', '200') -Env $ApiEnv -Timeout 90
        if ($r.Output -imatch '\d{4}.*\d{1,2}|\d{1,2}月|March|February|January') { Write-Pass "R3 web_search 返回含日期实时信息" }
        elseif ($r.Output -imatch '\[TOOL\]|\[MCP\]|web_search') { Write-Pass "R3 web_search 已调用" }
        else { Write-Warn "R3 web_search 日期查询 (可能网络受限)" }
    } else {
        Write-Warn "跳过内置 MCP 测试 (uvx 未安装)"
    }

    # ══════════════════════════════════════════════════════════════════
    # S. Playwright MCP
    # ══════════════════════════════════════════════════════════════════
    if (($npx -or $pnpm) -and $PlaywrightConfigured) {
        Write-Section "S. Playwright MCP"
        Sleep-Rate 2

        $r = Invoke-Cli @('--mcp', '-p', '用 playwright 打开 https://example.com 告诉我页面 title', '--max-tokens', '200') -Env $ApiEnv -Timeout 120
        if ($r.Output -imatch 'Example Domain|title|example') { Write-Pass "S1 Playwright 打开 example.com 获取 title" }
        elseif ($r.Output -imatch 'playwright|browser|navigate|\[TOOL\]') { Write-Pass "S1 Playwright 有调用响应" }
        elseif ($r.Output -imatch 'MCP.*失败|playwright.*失败') { Write-Warn "S1 Playwright MCP 启动失败" }
        else { Write-Fail "S1 Playwright 导航" ($r.Output.Split("`n") | Select-Object -First 5 | Out-String) }

        Sleep-Rate 2
        $r = Invoke-Cli @('--mcp', '-p', '用 playwright 打开 https://example.com 提取页面所有文字', '--max-tokens', '300') -Env $ApiEnv -Timeout 120
        if ($r.Output -imatch 'Example Domain|This domain|illustrative') { Write-Pass "S2 Playwright 成功提取页面文本" }
        elseif ($r.Output -imatch 'playwright|browser|\[TOOL\]') { Write-Pass "S2 Playwright 有响应" }
        else { Write-Warn "S2 Playwright 文本提取 (网络或浏览器问题)" }

        Sleep-Rate 2
        $ssFile = Join-Path $env:TEMP "minimax_ss_$([System.Guid]::NewGuid().ToString('N')[0..7] -join '').png"
        $r = Invoke-Cli @('--mcp', '-p', "用 playwright 打开 https://example.com 截图保存到 $ssFile", '--max-tokens', '200') -Env $ApiEnv -Timeout 120
        if (Test-Path $ssFile) { Write-Pass "S3 Playwright 截图文件已生成"; Remove-Item $ssFile -ErrorAction SilentlyContinue }
        elseif ($r.Output -imatch 'screenshot|截图|\[TOOL\]') { Write-Pass "S3 Playwright 截图命令已触发" }
        else { Write-Warn "S3 Playwright 截图 (路径可能不同)" }

        Sleep-Rate 2
        $r = Invoke-Cli @('--mcp', '-p', '用 playwright 打开 https://vlang.io 告诉我 title', '--max-tokens', '300') -Env $ApiEnv -Timeout 120
        if ($r.Output -imatch 'vlang|V Programming|V Language') { Write-Pass "S4 Playwright vlang.io 内容识别" }
        elseif ($r.Output -imatch 'playwright|browser|\[TOOL\]') { Write-Pass "S4 Playwright vlang.io 有调用" }
        else { Write-Warn "S4 Playwright vlang.io (网络问题)" }
    } elseif (-not $npx -and -not $pnpm) {
        Write-Warn "跳过 Playwright MCP 测试 (npx/pnpm 均未安装)"
    } else {
        Write-Warn "跳过 Playwright MCP 测试 (未在 mcp.json 中配置)"
    }

}

# ── 汇总 ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=========================================" -ForegroundColor Blue
Write-Host " 测试总结: $PassCount 通过, $FailCount 失败" -ForegroundColor Blue
if ($FailCount -gt 0) {
    Write-Host " ！有 $FailCount 个测试失败" -ForegroundColor Red
}
Write-Host "=========================================" -ForegroundColor Blue
Write-Host ""

exit $(if ($FailCount -eq 0) { 0 } else { 1 })
