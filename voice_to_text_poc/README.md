# Voice → Text POC (Option 2: Free first, Sarvam only as fallback)

A minimal Flutter app that converts voice to text for **Tamil, English and
Tanglish**:

1. **First** it uses the phone's **free, on-device recognizer**
   (Android `SpeechRecognizer` / iOS `SFSpeechRecognizer`, via the
   `speech_to_text` package).
2. It reads the **confidence score** of the result. If confidence is **below a
   threshold** (adjustable in the app, default **0.70**) — or the native path
   errors out / returns nothing — it **falls back to Sarvam AI's Saarika**
   speech-to-text API.
3. Every step is written to an **in-app log panel**: which engine ran, the
   confidence score, latency in ms, locale used, audio size uploaded, detected
   language, Sarvam request id, and every error.

```
 Tap mic
    │
    ▼
 Native on-device STT ── confidence ≥ threshold ──► text is English? ──► ACCEPT (NATIVE, free)
    │                                                    │
    │                                     Tamil script + "Output English" ON
    │                                                    ▼
    │                              Sarvam TEXT translate (cheap) ──► ACCEPT (NATIVE + SARVAM TRANSLATE)
    │
    └─ confidence < threshold / empty / error
              │
              ▼
       Record WAV (16 kHz mono) ──► Sarvam Saaras (speech → ENGLISH) ──► ACCEPT (SARVAM, paid)
       (with "Output English" OFF, the fallback uses Saarika: speech → same-language text)
```

**A note on confidence:** the app does not compute confidence — it displays the
raw score the OS recognizer returns with its final result. Android's Google
recognizer is known to return coarse, flat scores (~0.87–0.90 for almost any
utterance it parsed), so don't expect fine-grained values; the log also prints
every alternate hypothesis the OS returned with its individual score. Set the
threshold slider above the flat value (e.g. 0.90) to force the fallback.

---

## 1. Install Flutter (one-time, ~30 min)

You don't need any Flutter knowledge to run this — just follow these steps.

1. Install the **Flutter SDK**: follow the official guide for your OS at
   <https://docs.flutter.dev/get-started/install>. Choose the **Android**
   target (iOS requires a Mac).
2. Install **Android Studio** from <https://developer.android.com/studio>
   (Flutter uses its Android SDK and emulator). During first launch let it
   install the default SDK components.
3. Open a terminal and run:

   ```bash
   flutter doctor
   ```

   Fix anything it flags. Most commonly you need:

   ```bash
   flutter doctor --android-licenses   # press y to accept
   ```

   You're ready when `flutter doctor` shows a green tick for
   **Flutter** and **Android toolchain**.

> **Use a real Android phone if you can.** Enable *Developer options → USB
> debugging* on the phone and plug it in. Emulators work too, but you must
> enable the mic: in the emulator's settings enable **"Virtual microphone
> uses host audio input"**, and speech recognition quality is worse.

## 2. Get a Sarvam API key (one-time, free tier available)

1. Sign up at <https://dashboard.sarvam.ai>.
2. Create an **API subscription key** and copy it. You'll paste it into the
   app's Settings panel later (it is stored on the device only, never in git).

## 3. Set up this project (one-time)

The repo intentionally contains only the Dart source; the `android/`/`ios/`
folders are machine-generated locally:

```bash
cd voice_to_text_poc
./setup.sh
```

The script runs `flutter create .` (generates the platform folders), adds the
required permissions, and fetches packages.

<details>
<summary>On Windows, or if the script fails? Do it manually (4 small steps)</summary>

```bash
cd voice_to_text_poc
flutter create . --project-name voice_to_text_poc --org com.example --platforms android,ios
flutter pub get
```

Then edit **`android/app/src/main/AndroidManifest.xml`** — add this right
*above* the `<application` line:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
<queries>
    <intent>
        <action android:name="android.speech.RecognitionService" />
    </intent>
</queries>
```

Then edit **`android/app/build.gradle.kts`** (or `build.gradle`) — change
`minSdk = flutter.minSdkVersion` to `minSdk = 23`.

(For iOS on a Mac: add `NSMicrophoneUsageDescription` and
`NSSpeechRecognitionUsageDescription` string entries to
`ios/Runner/Info.plist`.)

If `flutter create` replaced this README, restore it with
`git checkout -- README.md`.
</details>

## 4. Run it

```bash
cd voice_to_text_poc
flutter run
```

Pick your device if asked. First build takes a few minutes; later builds are
fast. (Hot reload: press `r` in the terminal after editing code.)

## 5. Using the app

1. Open **Settings** (top card): pick the language
   (**Tamil / English / Tanglish**), paste your **Sarvam API key**, and adjust
   the **confidence threshold** if you want.
2. Tap the **mic** and speak. Grant mic (and speech) permission when asked.
3. Watch the log panel at the bottom — every decision is printed live:

   ```
   [NATIVE] Listening started. locale=ta_IN, threshold=0.70
   [NATIVE] Final result in 2140ms: "வணக்கம்" | confidence=0.91
   [NATIVE] ACCEPTED (confidence 0.91 ≥ threshold 0.70). Engine used: NATIVE. Cost: free.
   ```

   or, when the free path isn't good enough:

   ```
   [NATIVE] Final result in 2870ms: "..." | confidence=0.41
   [NATIVE] REJECTED: confidence 0.41 < threshold 0.70 → falling back to Sarvam.
   [SARVAM] Fallback triggered (...). SPEAK AGAIN now — recording WAV 16 kHz mono ...
   [SARVAM] Recording stopped (94.2 KB). Uploading to Sarvam Saarika (model saarika:v2.5, language_code=unknown)…
   [SARVAM] Transcript in 1650ms: "நான் office போren" | detected language: ta-IN | request id: … Engine used: SARVAM (paid).
   ```

4. The **result card** shows the final transcript with a colored badge —
   green **NATIVE (on-device)** or purple **SARVAM AI (cloud)** — plus the
   confidence and latency.
5. Useful testing tools:
   - **Force Sarvam** toggle → skips the native engine so you can test the
     Sarvam path directly.
   - **Threshold slider** → set it to 1.0 to force fallback on every attempt,
     or 0.0 to always accept native.
   - **Copy log** button (top right) → exports the whole log as text.

### Testing Tanglish

Select **Tanglish (auto-detect)**. The native recognizer is pointed at Tamil
(best effort — native engines handle code-mixing poorly, which usually shows
up as a low confidence score and triggers the fallback), while Sarvam is
called with `language_code=unknown`, which enables Saarika's auto-detect /
code-mixed handling.

## 6. What's logged (metrics)

| Metric | Where it comes from |
|---|---|
| Engine used (NATIVE / SARVAM) | The fallback decision in `lib/main.dart` |
| Confidence (0–1) | Native recognizer's final result (`n/a` if the device doesn't report one; Sarvam's API returns no confidence) |
| Latency (ms) | Native: mic-tap → final result. Sarvam: upload → response |
| Locale / language code | Resolved native locale (e.g. `ta_IN`) or Sarvam code (`ta-IN` / `en-IN` / `unknown`) |
| Audio size (KB) | The WAV file uploaded to Sarvam |
| Detected language + request id | Sarvam's API response |
| Errors & status changes | Both engines' callbacks |

## 7. Where the logic lives

| File | What it does |
|---|---|
| `lib/main.dart` | UI + the state machine. The fallback decision is in `_onNativeResult()` (search for "THE fallback decision"). |
| `lib/sarvam_service.dart` | The Sarvam Saarika API call (multipart upload of the WAV). |
| `lib/app_logger.dart` | The in-app log panel's backing store. |
| `lib/models.dart` | Engines, languages, log-entry and result types. |

## 8. Known POC limitations

- **Fallback asks you to speak again.** Android/iOS don't let the native
  recognizer and a raw audio recorder share the microphone, so the original
  audio isn't available when native fails — the app re-records for Sarvam. A
  production version would record once and run *both* paths on the same audio
  (record first, then feed Sarvam directly; native file-based recognition
  isn't exposed by the plugin).
- **Some Android devices report no confidence score** (logged as
  `not reported`). The POC accepts those results; use **Force Sarvam** or the
  threshold slider to exercise the fallback on such devices.
- **Native Tamil needs the language pack.** On Android, install Tamil under
  *Settings → Google → Voice → Offline speech recognition* (or in Gboard's
  voice typing languages). The app logs a warning at startup if no Tamil
  locale is found.
- The Sarvam API key is stored in `shared_preferences` (plain, on-device) —
  fine for a POC, not for production.
