#!/bin/zsh
# 编译 SwiftUI 前端并打包成 ~/Applications/面搭子.app
set -e
cd "$(dirname "$0")"
swift build -c release
APP="$HOME/Applications/面搭子.app"
PROJECT="$(cd .. && pwd)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ResumeScreener "$APP/Contents/MacOS/ResumeScreener"
python3 i18n/gen_strings.py "$APP/Contents/Resources"
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
<key>CFBundleIdentifier</key><string>com.longbridge.resume-screener</string>
<key>CFBundleExecutable</key><string>ResumeScreener</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4</string>
<key>CFBundleVersion</key><string>4</string>
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
codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP" >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
echo "已生成 $APP"
