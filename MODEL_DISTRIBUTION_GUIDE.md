# Narrator Model Distribution & Initialization Guide

## Summary of Changes

### 1. ✅ Black Screen Issue (FIXED)
**Problem:** Camera permission dialog + immediate camera init caused Camera2 texture conflicts  
**Solution:** Added 500ms delay + permission re-verification before camera initialization  
**Files Modified:** `lib/screens/home_screen.dart`

---

### 2. ✅ Model URLs Updated
**Before:** YOLO and IndicTrans2 had empty URLs  
**After:** Direct links to GitHub/Hugging Face releases  
**Files Modified:** `lib/core/constants.dart`

**Real Model Sources:**
```
✅ Silero VAD       → GitHub (snakers4/silero-vad) - 2 MB
✅ Whisper-tiny     → Hugging Face ONNX - 75 MB
✅ SmolVLM-256M     → Hugging Face GGUF - 500 MB
✅ YOLOv8-nano      → ncnn releases (GitHub) - 7 MB
✅ IndicTrans2      → Hugging Face (AI4Bharat) - 280 MB
✅ Qwen3-VL-2B      → Hugging Face - 4 GB (optional, 6GB+ RAM devices)
```

---

### 3. ✅ Automatic Model Download with Resilience
**Features Added:**
- **Resumable downloads** — interrupted downloads continue from last byte
- **Exponential backoff retry** — 3 attempts with 2s, 4s, 6s delays
- **Non-blocking initialization** — app runs even if some models fail to download
- **Graceful degradation** — Features disabled when models unavailable

**Files Modified:** `lib/core/model_manager.dart`

**New Properties:**
```dart
essentialModelsReady    // Only Silero VAD (always runs if available)
pipeline1Ready          // YOLO models (obstacle detection)
pipeline2Ready          // Full conversation features
```

---

### 4. ✅ Safer Pipeline Initialization
**Changes:**
- Pipelines don't crash app if models missing
- Pipeline 1 only starts if YOLO models downloaded
- Pipeline 2 VLM only loads if SmolVLM file available
- STT/Wake-word services wrap init in try-catch

**Files Modified:**
- `lib/main.dart`
- `lib/screens/home_screen.dart`

---

## Recommended Implementation Path

### **For MVP (Minimum Viable Product)** ⚡

**Goal:** Work offline, minimal setup
1. Embed essential models in assets:
   ```
   assets/models/
   ├── silero_vad.onnx         (already there, 2MB)
   └── whisper-tiny.onnx       (add, 75MB)
   ```

2. Make downloads optional on first run:
   ```dart
   // In splash_screen.dart
   if (ModelManager.instance.essentialModelsReady) {
     // Can use app with VAD + Whisper
     Navigator.pushReplacementNamed(context, '/home');
   } else {
     Navigator.pushReplacementNamed(context, '/download');
   }
   ```

3. Update splash logic:
   ```dart
   // Allow home screen even if SmolVLM not downloaded
   if (!ModelManager.instance.coreModelsReady) {
     Navigator.pushReplacementNamed(context, '/download');
   } else {
     Navigator.pushReplacementNamed(context, '/home');
   }
   ```

---

### **For Production** 🚀

**Goal:** Full feature set, cloud-backed model distribution

#### **Option A: Direct Hugging Face (Simplest)**
Models auto-download from public Hugging Face URLs on first app run. Works for most users.

```dart
await ModelManager.instance.downloadAll(allowPartial: true);
// App runs with whatever models download successfully
```

---

#### **Option B: Custom CDN (Most Reliable)**

1. **Host models on your CDN** (AWS CloudFront / Wasabi / B2):
   ```dart
   static const String modelCdnBase = 'https://your-cdn.com/narrator-models/';
   
   static const String smolvlmGgufUrl = '$modelCdnBase/SmolVLM-256M.gguf';
   static const String whisperTinyOnnxUrl = '$modelCdnBase/whisper-tiny.onnx';
   // etc.
   ```

2. **Add integrity verification:**
   ```dart
   // In constants.dart - add real SHA256 hashes
   static const Map<String, String> modelHashes = {
     'silero_vad.onnx': 'f15b...',  // Real hash
     'whisper_tiny_multilingual.onnx': '3a2c...',
     // ... etc
   };
   ```

3. **Update verifyIntegrity():**
   ```dart
   Future<bool> verifyIntegrity(String fileName) async {
     final expectedHash = AppConstants.modelHashes[fileName];
     if (expectedHash == null || expectedHash.startsWith('placeholder')) {
       return true;
     }
     final file = File(modelPath(fileName));
     if (!await file.exists()) return false;
     final bytes = await file.readAsBytes();
     final hash = sha256.convert(bytes).toString();
     return hash == expectedHash;
   }
   ```

---

#### **Option C: Server-Orchestrated (Enterprise)**

Create a backend service that:
- Tracks model versions
- Provides signed download URLs (expires in 1 hour)
- Returns best mirror based on user location
- Tracks download metrics

```dart
// In model_manager.dart
Future<String> _getSecureDownloadUrl(String modelFileName) async {
  final response = await _dio.post(
    'https://your-api.com/models/download-url',
    data: {'modelName': modelFileName, 'userId': userId},
  );
  return response.data['downloadUrl'];
}
```

---

## Testing Downloads Locally

### Test resumable download:
```bash
# Simulate interrupted download
curl -O -C - https://huggingface.co/.../model.onnx

# App will resume from same byte position
```

### Test model integrity:
```dart
// In model_manager.dart
_log.i('Hash: ${sha256.convert(await file.readAsBytes()).toString()}');
```

---

## UI/UX Improvements for Users

### 1. Update Model Download Screen to show:
```
✅ Silero VAD         - Ready (embedded)
⏳ Whisper-tiny       - Downloading (45%)...
⚠️  SmolVLM           - Failed 2x, retrying in 4s
⏭️  Skip & Use Offline - [Button] (start with just Whisper)
```

### 2. Add "Degraded Mode" indicator on home:
```
P1: ⏸️ Disabled (YOLO missing)
P2: ✅ Running (Whisper + SmolVLM ready)
```

### 3. Settings → Model Management:
```
- Show download progress
- Allow user to delete individual models
- Show storage used vs available
- Allow manual re-download if corrupted
```

---

## Troubleshooting

### "Black screen on launch"
✅ **FIXED** — Added permission verification delay

### "Downloads fail on slow networks"
**Solution:** Using resumable download + exponential backoff  
- Interrupted downloads auto-resume
- Max 3 retries with 2s/4s/6s backoff
- Partial downloads don't delete temp files

### "App crashes with 'model not found'"
✅ **FIXED** — Pipelines now wrap init in try-catch  
- Pipeline 1 (YOLO) disabled if models missing
- Pipeline 2 (VLM) skips loading missing models
- App starts and runs with available features

### "Models download but never marked ready"
**Debug:** Check that file rename succeeds:
```dart
// model_manager.dart line ~165
await tempFile.rename(destFile.path);  // Ensure this completes
```

### "Storage full during download"
**Monitor available space before download:**
```dart
Future<int> getAvailableStorageMb() async {
  // Use device_info_plus to get available storage
  final availableMb = ...;
  if (availableMb < (totalRequiredMb * 1.5)) {
    throw Exception('Need ${totalRequiredMb}MB, have ${availableMb}MB');
  }
}
```

---

## Performance Targets (Narrator)

| Pipeline | Model | Target | Notes |
|----------|-------|--------|-------|
| **P1** | YOLOv8-nano | 15-30 FPS | Snapdragon 662+, realtime |
| **P2 STT** | Whisper-tiny | 2-5s | Offline, multilingual |
| **P2 VLM** | SmolVLM-256M | 3-8s | Scene description |
| **P2 VLM** | Qwen3-VL-2B | 5-12s | High-end devices only |
| **P2 TTS** | Flutter-TTS | <100ms | First sentence streaming |

---

## Next Steps

1. **Test resumable downloads:**
   - Unplug network after 50% download
   - App should resume on reconnect

2. **Verify non-blocking init:**
   - Block all model URLs in dev
   - App should still launch and reach home screen

3. **Add model integrity checksums:**
   - Generate SHA256 hashes for real models
   - Update `constants.dart`

4. **Deploy:** Use Option A (Hugging Face) initially, migrate to CDN after launch

---

**Questions?** Check logs via `Logger` in model_manager.dart or `debugPrint()` in home_screen.dart
