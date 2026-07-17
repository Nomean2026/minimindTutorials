@echo off
chcp 65001 >nul
title GitHub Pages 一键部署
setlocal enabledelayedexpansion

:: ============================================================
::  GitHub Pages 通用部署脚本 (bat版)
::  用法：复制到任意文件夹，双击运行
::  效果：把所在文件夹部署到 GitHub 同名仓库，并开启 Pages
:: ============================================================

echo ╔══════════════════════════════════════════╗
echo ║        GitHub Pages 一键部署脚本          ║
echo ╚══════════════════════════════════════════╝
echo.

:: ─── 检查 gh CLI ───
where gh >nul 2>nul
if %errorlevel% neq 0 (
    echo ❌ 未检测到 GitHub CLI ^(gh^)
    echo.
    echo 请先安装: https://cli.github.com/
    echo 安装后运行: gh auth login
    echo.
    pause
    exit /b 1
)

:: ─── 检查 gh 登录状态 ───
gh auth status >nul 2>nul
if %errorlevel% neq 0 (
    echo ❌ 未登录 GitHub CLI
    echo 请运行: gh auth login
    pause
    exit /b 1
)

:: ─── 获取 GitHub 用户名 ───
for /f "tokens=*" %%i in ('gh api user --jq .login 2^>nul') do set GH_USER=%%i
echo ✅ 已登录: %GH_USER%
echo.

:: ─── 获取当前文件夹名作为仓库名 ───
for %%i in ("%CD%") do set REPO_NAME=%%~ni
set BRANCH=main
set FOLDER=%CD%

echo 📂 当前文件夹: %FOLDER%
echo 📦 目标仓库: %GH_USER%/%REPO_NAME%
echo.

:: ─── 确认部署 ───
echo 即将把当前文件夹部署为 GitHub Pages 网站：
echo   https://%GH_USER%.github.io/%REPO_NAME%/
echo.
choice /c YN /m "是否继续？"
if errorlevel 2 exit /b 0
echo.

:: ─── 检查是否已有 .git ───
if exist ".git" (
    git remote get-url origin >nul 2>nul
    if !errorlevel! equ 0 (
        echo 🔄 检测到已有 Git 仓库，直接推送更新...
        echo.
        goto :PUSH
    )
)

:: ─── 创建 GitHub 仓库 ───
echo 🚀 正在创建 GitHub 仓库 %REPO_NAME% ...
gh repo create %REPO_NAME% --public --description "Deployed from %FOLDER%" >nul 2>nul
if %errorlevel% neq 0 (
    echo ⚠️  仓库可能已存在，继续尝试推送...
) else (
    echo ✅ 仓库创建成功！
)
echo.

:: ─── 初始化 Git ───
if not exist ".git" (
    echo 🔧 初始化 Git 仓库...
    git init >nul 2>nul
    git branch -M %BRANCH% >nul 2>nul
)
echo.

:: ─── 添加 .gitignore ───
if not exist ".gitignore" (
    echo 创建 .gitignore ...
    echo .git > .gitignore
    echo deploy.bat >> .gitignore
    echo deploy.ps1 >> .gitignore
)

:: ─── 添加并提交 ───
echo 📝 暂存文件...
git add .
if %errorlevel% neq 0 (
    echo ❌ git add 失败
    pause
    exit /b 1
)

echo 📝 提交代码...
git commit -m "Deploy: %DATE% %TIME%"
if %errorlevel% neq 0 (
    git commit --allow-empty -m "Deploy: %DATE% %TIME%"
)
echo ✅ 提交成功
echo.

:: ─── 配置远程仓库 ───
git remote get-url origin >nul 2>nul
if %errorlevel% neq 0 (
    git remote add origin https://github.com/%GH_USER%/%REPO_NAME%.git
)

:PUSH
:: ─── 尝试 git push ───
echo 📤 正在推送到 GitHub ...
git push -u origin %BRANCH% 2> push_err.txt
if %errorlevel% equ 0 (
    echo ✅ 推送成功！
    goto :ENABLE_PAGES
)

:: ─── git push 失败，改用 API ───
echo ⚠️  git push 失败，改用 API 方式上传...
call :API_UPLOAD
if %errorlevel% neq 0 (
    echo ❌ 所有上传方式均失败
    type push_err.txt 2>nul
    echo.
    choice /c YN /m "是否忽略错误，继续开启 Pages？"
    if errorlevel 2 exit /b 1
)

:ENABLE_PAGES
echo.
echo 🌐 正在启用 GitHub Pages ...
gh api repos/%GH_USER%/%REPO_NAME%/pages -X POST -f source[branch]=%BRANCH% -f source[path]="/" >nul 2>nul
if %errorlevel% equ 0 (
    echo ✅ GitHub Pages 已启用！
) else (
    echo ⚠️  Pages 可能已启用，或者需要去 GitHub 网页端手动开启
    echo    仓库 Settings ^> Pages ^> 选择 main 分支
)
echo.

:: ─── 显示结果 ───
echo ══════════════════════════════════════════
echo   🎉  部署完成！
echo.
echo   📍 访问地址:
echo   https://%GH_USER%.github.io/%REPO_NAME%/
echo.
echo   📂 仓库地址:
echo   https://github.com/%GH_USER%/%REPO_NAME%
echo ══════════════════════════════════════════
echo.
echo 💡 如果页面显示 404，请等 1-2 分钟让 GitHub 构建完成
echo.
del push_err.txt 2>nul

echo 按任意键退出...
pause >nul
exit /b 0


:: =============================================
::  API 上传函数（备用方案）
:: =============================================
:API_UPLOAD
setlocal enabledelayedexpansion

for /f "tokens=*" %%i in ('gh auth token 2^>nul') do set TOKEN=%%i
if not defined TOKEN (
    endlocal
    exit /b 1
)

python --version >nul 2>nul
if !errorlevel! equ 0 (
    python -c "
import base64, requests, os, sys

token = sys.argv[1]
user = sys.argv[2]
repo = sys.argv[3]
folder = sys.argv[4]
headers = {'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json'}
api = f'https://api.github.com/repos/{user}/{repo}/contents/'

# 收集文件
files = []
for root, dirs, fnames in os.walk(folder):
    # 跳过 .git 目录
    dirs[:] = [d for d in dirs if d != '.git']
    for f in fnames:
        if f.endswith(('.html', '.htm', '.css', '.js', '.md', '.json', '.png', '.jpg', '.svg', '.ico', '.txt', '.yml', '.yaml', '.xml', '.woff', '.woff2', '.ttf', '.eot')):
            rel = os.path.relpath(os.path.join(root, f), folder)
            files.append(rel)

if not files:
    files = [f for f in os.listdir(folder) if not f.startswith('.') and not f.endswith(('.bat', '.ps1'))]

print(f'上传 {len(files)} 个文件...')
for fname in sorted(files):
    path = os.path.join(folder, fname)
    if not os.path.isfile(path):
        continue
    with open(path, 'rb') as f:
        content = base64.b64encode(f.read()).decode()
    
    # 处理路径分隔符
    api_path = fname.replace('\\', '/')
    
    # 检查是否存在
    r = requests.get(api + api_path, headers=headers)
    sha = r.json().get('sha', '') if r.status_code == 200 else ''
    
    data = {'message': f'Add {api_path}', 'content': content}
    if sha:
        data['sha'] = sha
    
    r = requests.put(api + api_path, headers=headers, json=data)
    if r.status_code in (200, 201):
        print(f'  ✅ {api_path}')
    else:
        print(f'  ⚠️  {api_path}: {r.status_code}')
" "!TOKEN!" "!GH_USER!" "!REPO_NAME!" "!FOLDER!"
    if !errorlevel! equ 0 (
        endlocal
        exit /b 0
    )
)

endlocal
exit /b 1