@echo off
REM =============================================================================
REM HACKERAI CYBER WARFARE NEXUS - Windows Setup Script
REM =============================================================================
REM Bu skript barcha kerakli dasturlarni o'rnatadi va GitHubga push qiladi
REM =============================================================================

title HACKERAI Cyber Warfare Nexus - Setup

echo.
echo ============================================
echo  HACKERAI CYBER WARFARE NEXUS v3.0
echo  Windows Setup & GitHub Push
echo ============================================
echo.

REM -------------------------------------------
REM 1. GitHub login
REM -------------------------------------------
echo [*] Step 1: GitHub login...
echo.
echo   GitHub repoga push qilish uchun:
echo   1. https://github.com saytiga kiring
echo   2. Yangi repo yarating: hackerai/cyber_warfare_nexus
echo   3. Quyidagi buyruqlarni bajaring:
echo.
echo ============================================
echo  cd /d C:\cyber_warfare_nexus
echo  git remote add origin https://github.com/YOUR_USERNAME/cyber_warfare_nexus.git
echo  git branch -M main
echo  git push -u origin main
echo ============================================
echo.

REM -------------------------------------------
REM 2. Dependency install
REM -------------------------------------------
echo [*] Step 2: Installing Python dependencies...
cd /d C:\cyber_warfare_nexus\exploits
pip install -r requirements.txt 2>nul
echo.
echo [*] Step 3: Installing Node.js dependencies...
cd /d C:\cyber_warfare_nexus\web_intel
call npm install 2>nul
echo.
echo [*] Step 4: Config...
echo   Tahrirlash: notepad C:\cyber_warfare_nexus\config.env
echo   Target IP va domainlarni kiriting.
echo.
echo [*] Setup complete!
echo   Run: warfare.sh --full --target 10.10.10.0/24 --domain example.com
echo.
pause
