#!/usr/bin/env bash
# One-time setup for the Voice-to-Text POC.
# Generates the android/ and ios/ platform folders and patches in the
# microphone / speech / internet permissions the app needs.
#
# Prerequisite: Flutter SDK installed and on your PATH (run `flutter doctor`).
# Usage:  cd voice_to_text_poc && ./setup.sh
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Step 1/4: generating platform folders (flutter create) ..."
flutter create . --project-name voice_to_text_poc --org com.example --platforms android,ios

# flutter create skips files that already exist, so lib/ and pubspec.yaml
# are preserved. If it replaced README.md, restore ours from git.
git checkout -- README.md 2>/dev/null || true

echo "==> Step 2/4: patching AndroidManifest.xml (permissions + speech service query) ..."
python3 - <<'PYEOF'
import io, re

path = "android/app/src/main/AndroidManifest.xml"
with io.open(path, encoding="utf-8") as f:
    content = f.read()

permissions = """    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.INTERNET" />
    <queries>
        <intent>
            <action android:name="android.speech.RecognitionService" />
        </intent>
    </queries>
"""

if "RECORD_AUDIO" not in content:
    content = content.replace("<application", permissions + "    <application", 1)
    with io.open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print("    added RECORD_AUDIO, INTERNET and RecognitionService query")
else:
    print("    already patched, skipping")
PYEOF

echo "==> Step 3/4: setting Android minSdk to 23 (required by the 'record' package) ..."
python3 - <<'PYEOF'
import io, os, re

for path in ("android/app/build.gradle.kts", "android/app/build.gradle"):
    if not os.path.exists(path):
        continue
    with io.open(path, encoding="utf-8") as f:
        content = f.read()
    new = content.replace("minSdk = flutter.minSdkVersion", "minSdk = 23")
    new = new.replace("minSdkVersion flutter.minSdkVersion", "minSdkVersion 23")
    if new != content:
        with io.open(path, "w", encoding="utf-8") as f:
            f.write(new)
        print(f"    patched {path}")
    else:
        print(f"    {path}: nothing to change (already patched?)")
    break
PYEOF

echo "==> Step 4/4: patching ios/Runner/Info.plist (mic + speech usage descriptions) ..."
python3 - <<'PYEOF'
import io, os

path = "ios/Runner/Info.plist"
if os.path.exists(path):
    with io.open(path, encoding="utf-8") as f:
        content = f.read()
    keys = """\t<key>NSMicrophoneUsageDescription</key>
\t<string>This POC records your voice to convert it to text.</string>
\t<key>NSSpeechRecognitionUsageDescription</key>
\t<string>This POC uses on-device speech recognition to convert voice to text.</string>
"""
    if "NSMicrophoneUsageDescription" not in content:
        content = content.replace("</dict>\n</plist>", keys + "</dict>\n</plist>")
        with io.open(path, "w", encoding="utf-8") as f:
            f.write(content)
        print("    added NSMicrophoneUsageDescription and NSSpeechRecognitionUsageDescription")
    else:
        print("    already patched, skipping")
else:
    print("    ios/ not generated (not on macOS?), skipping")
PYEOF

echo "==> Fetching Dart packages ..."
flutter pub get

echo ""
echo "Setup complete. Plug in a phone (or start an emulator) and run:  flutter run"
