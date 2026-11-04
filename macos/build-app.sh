#!/bin/zsh
# 编译 SwiftUI 前端并打包成 ~/Applications/面搭子.app
set -e
setopt null_glob
cd "$(dirname "$0")"
swift build -c release
APP="$HOME/Applications/面搭子.app"
PROJECT="$(cd .. && pwd)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ResumeScreener "$APP/Contents/MacOS/ResumeScreener"
python3 i18n/gen_strings.py "$APP/Contents/Resources"
# 独立安装包：自带 Python 3.12（uv 管理的可搬移版本）+ 依赖 + 后端代码，别人装上就能用
RES="$APP/Contents/Resources"
uv python install 3.12 >/dev/null
PYSRC="$(cd / && cd "$(dirname "$(cd / && uv python find 3.12 --managed-python --no-project)")/.." && pwd -P)"
cp -R "$PYSRC" "$RES/python"
rm -rf "$RES/python/lib/python3.12/test" "$RES/python/lib/python3.12/idlelib" "$RES/python/lib/python3.12/tkinter" "$RES/python/lib/python3.12/turtledemo" "$RES/python/share" "$RES/python/lib/tcl"* "$RES/python/lib/tk"* "$RES/python/lib/itcl"* "$RES/python/lib/thread"*
REQ="$(mktemp)"
(cd "$PROJECT" && uv export --frozen --no-dev --no-hashes --no-emit-project 2>/dev/null | grep -viE "^(pywebview|pyobjc|proxy-tools|bottle)") > "$REQ"
uv pip install --quiet --python "$RES/python/bin/python3" --break-system-packages --no-cache -r "$REQ"
rm -f "$REQ"
mkdir -p "$RES/backend"
rsync -a --exclude __pycache__ "$PROJECT/screener" "$RES/backend/"
find "$RES/python" -name __pycache__ -type d -prune -exec rm -rf {} +
[ -f icon/AppIcon.icns ] || { swift icon/make-icon.swift icon/AppIcon.iconset && iconutil -c icns icon/AppIcon.iconset -o icon/AppIcon.icns; }
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>面搭子</string>
<key>CFBundleDisplayName</key><string>面搭子</string>
<key>CFBundleIdentifier</key><string>com.almightyyantao.interviewmate</string>
<key>CFBundleExecutable</key><string>ResumeScreener</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>面试时转写你说的话（本机识别，音频不保存）</string>
<key>NSSpeechRecognitionUsageDescription</key><string>用本机语音识别把面试对话转成文字</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>读取日历里的面试安排，开始前提醒你（只读）</string>
<key>NSAudioCaptureUsageDescription</key><string>转写视频会议里候选人的声音（本机识别，音频不保存）</string>
<key>ScreenerProjectDir</key><string>$PROJECT</string>
</dict></plist>
PLIST
touch "$APP"
# 用固定的开发者证书签名，系统权限（麦克风、语音识别、屏幕与系统录音）重新打包后不会失效。
# 证书在 .sign-identity 里配置（证书名或 SHA-1），没有就退回临时签名。
IDENTITY="$(cat .sign-identity 2>/dev/null || echo -)"
# 先签里面的 Python 二进制和动态库，再签整个 App
sign() { codesign --force --timestamp=none --sign "$IDENTITY" "$@" >/dev/null 2>&1 || codesign --force --sign - "$@" >/dev/null 2>&1 || true; }
find "$APP/Contents/Resources/python" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -u+x \) -print0 | while IFS= read -r -d '' f; do
  file "$f" | grep -q Mach-O && sign "$f"
done
codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP" >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
echo "已生成 $APP"
