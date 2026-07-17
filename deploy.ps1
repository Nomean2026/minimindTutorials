<#
.SYNOPSIS
  GitHub Pages 通用部署脚本 (PowerShell版)
  复制到任意文件夹，右键"使用 PowerShell 运行"
  把所在文件夹部署到同名的 GitHub 仓库，并开启 Pages
#>

$ErrorActionPreference = "Continue"
$Host.UI.RawUI.WindowTitle = "GitHub Pages 一键部署"

Write-Host "╔" -NoNewline
Write-Host "══════════════════════════════════════════" -NoNewline
Write-Host "╗" -ForegroundColor White
Write-Host "║        GitHub Pages 一键部署脚本          ║" -ForegroundColor Cyan
Write-Host "╚" -NoNewline
Write-Host "══════════════════════════════════════════" -NoNewline
Write-Host "╝" -ForegroundColor White
Write-Host ""

# ─── 检查 gh ───
if (-not (Get-Command "gh" -ErrorAction SilentlyContinue)) {
    Write-Host "❌ 未检测到 GitHub CLI (gh)" -ForegroundColor Red
    Write-Host "请先安装: https://cli.github.com/"
    Write-Host "安装后运行: gh auth login"
    Read-Host "按回车退出"
    exit 1
}

# ─── 检查登录 ───
$status = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ 未登录 GitHub CLI" -ForegroundColor Red
    Write-Host "请运行: gh auth login"
    Read-Host "按回车退出"
    exit 1
}

$GH_USER = gh api user --jq .login 2>$null
Write-Host "✅ 已登录: $GH_USER" -ForegroundColor Green
Write-Host ""

# ─── 获取当前文件夹名作为仓库名 ───
$REPO_NAME = Split-Path -Leaf $PWD.Path
$BRANCH = "main"
$FOLDER = $PWD.Path

Write-Host "📂 当前文件夹: $FOLDER" -ForegroundColor Yellow
Write-Host "📦 目标仓库: $GH_USER/$REPO_NAME" -ForegroundColor Yellow
Write-Host ""

# ─── 确认 ───
Write-Host "即将部署为 GitHub Pages 网站："
Write-Host "  https://$GH_USER.github.io/$REPO_NAME/" -ForegroundColor Cyan
Write-Host ""
$confirm = Read-Host "是否继续？(Y/n)"
if ($confirm -eq "n" -or $confirm -eq "N") { exit 0 }
Write-Host ""

# ─── 检查已有 Git ───
if (Test-Path ".git") {
    $remote = git remote get-url origin 2>$null
    if ($remote) {
        Write-Host "🔄 检测到已有 Git 仓库，直接推送更新..." -ForegroundColor Green
        goto PUSH
    }
}

# ─── 创建仓库 ───
Write-Host "🚀 正在创建 GitHub 仓库 $REPO_NAME ..." -ForegroundColor Yellow
gh repo create $REPO_NAME --public --description "Deployed from $FOLDER" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "⚠️  仓库可能已存在" -ForegroundColor Yellow
} else {
    Write-Host "✅ 仓库创建成功！" -ForegroundColor Green
}

# ─── 初始化 Git ───
if (-not (Test-Path ".git")) {
    Write-Host "🔧 初始化 Git ..." -ForegroundColor Yellow
    git init 2>$null
    git branch -M $BRANCH 2>$null
}

# ─── .gitignore ───
if (-not (Test-Path ".gitignore")) {
    ".git", "deploy.bat", "deploy.ps1", "push_err.txt" | Set-Content ".gitignore"
}

# ─── 提交 ───
Write-Host "📝 暂存并提交代码..." -ForegroundColor Yellow
git add .
$commitMsg = "Deploy: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
git commit -m $commitMsg 2>$null
if ($LASTEXITCODE -ne 0) {
    git commit --allow-empty -m $commitMsg 2>$null
}
Write-Host "✅ 提交成功" -ForegroundColor Green

# ─── 远程 ───
$remote = git remote get-url origin 2>$null
if (-not $remote) {
    git remote add origin "https://github.com/${GH_USER}/${REPO_NAME}.git"
}

# ─── Push ───
:PUSH
Write-Host "📤 正在推送到 GitHub ..." -ForegroundColor Yellow
$pushResult = git push -u origin $BRANCH 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ 推送成功！" -ForegroundColor Green
    goto PAGES
}

# ─── API 备用 ───
Write-Host "⚠️  git push 失败，改用 API 方式上传..." -ForegroundColor Yellow
Write-Host ""

$TOKEN = gh auth token 2>$null
if (-not $TOKEN) {
    Write-Host "❌ 无法获取 Token" -ForegroundColor Red
    $continue = Read-Host "是否忽略错误继续？(Y/n)"
    if ($continue -eq "n") { exit 1 }
    goto PAGES
}

$api = "https://api.github.com/repos/${GH_USER}/${REPO_NAME}/contents/"
$headers = @{
    "Authorization" = "Bearer $TOKEN"
    "Accept" = "application/vnd.github+json"
}

# 收集要上传的文件
$extensions = @(".html", ".htm", ".css", ".js", ".md", ".json", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico", ".txt", ".yml", ".yaml", ".xml", ".woff", ".woff2", ".ttf", ".eot", ".webp")
$files = Get-ChildItem -Path $FOLDER -Recurse -File | Where-Object {
    $_.Extension -in $extensions -and $_.FullName -notmatch '\\.git\\'
}

if ($files.Count -eq 0) {
    $files = Get-ChildItem -Path $FOLDER -File | Where-Object {
        $_.Name -notlike ".*" -and $_.Extension -notin @(".bat", ".ps1", ".exe", ".dll")
    }
}

Write-Host "上传 $($files.Count) 个文件 ..."
$success = $true
foreach ($file in $files) {
    $relPath = [System.IO.Path]::GetRelativePath($FOLDER, $file.FullName) -replace '\\', '/'
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $content = [Convert]::ToBase64String($bytes)
    
    $data = @{
        message = "Add $relPath"
        content = $content
    }
    
    # 检查是否存在
    try {
        $existing = Invoke-RestMethod -Uri "${api}${relPath}" -Headers $headers -Method Get -ErrorAction SilentlyContinue
        if ($existing.sha) { $data.sha = $existing.sha }
    } catch {}
    
    try {
        Invoke-RestMethod -Uri "${api}${relPath}" -Headers $headers -Method Put -Body ($data | ConvertTo-Json -Depth 3) -ContentType "application/json" | Out-Null
        Write-Host "  ✅ $relPath" -ForegroundColor Green
    } catch {
        Write-Host "  ⚠️  $relPath : $($_.Exception.Message)" -ForegroundColor Yellow
        $success = $false
    }
}

if (-not $success) {
    $continue = Read-Host "部分文件上传失败，是否继续开启 Pages？(Y/n)"
    if ($continue -eq "n") { exit 1 }
}

# ─── 启用 Pages ───
:PAGES
Write-Host ""
Write-Host "🌐 正在启用 GitHub Pages ..." -ForegroundColor Yellow
try {
    $result = gh api "repos/${GH_USER}/${REPO_NAME}/pages" -X POST -f source[branch]=$BRANCH -f source[path]="/" 2>$null
    Write-Host "✅ GitHub Pages 已启用！" -ForegroundColor Green
} catch {
    Write-Host "⚠️  Pages 可能已启用，或需手动设置" -ForegroundColor Yellow
    Write-Host "   仓库 Settings > Pages > 选择 main 分支" -ForegroundColor Gray
}

# ─── 显示结果 ───
Write-Host ""
Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  🎉  部署完成！" -ForegroundColor White
Write-Host ""
Write-Host "  📍 访问地址:" -ForegroundColor White
Write-Host "  https://$GH_USER.github.io/$REPO_NAME/" -ForegroundColor Green
Write-Host ""
Write-Host "  📂 仓库地址:" -ForegroundColor White
Write-Host "  https://github.com/$GH_USER/$REPO_NAME" -ForegroundColor Blue
Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "💡 如果页面显示 404，请等 1-2 分钟让 GitHub 构建完成" -ForegroundColor Yellow
Read-Host "按回车退出"