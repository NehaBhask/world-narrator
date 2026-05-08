package com.narrator

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.io.File

/**
 * NarratorPlugin — bridges Flutter to native Android for:
 * 1. NCNN YOLOv8 inference (narrator_ncnn.so via JNI)
 * 2. VLM inference (llama.cpp Android via JNI, separate channel)
 * 3. Device RAM query
 */
class NarratorPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var ncnnChannel: MethodChannel
    private lateinit var vlmChannel: MethodChannel
    private lateinit var context: Context
    private val scope = CoroutineScope(Dispatchers.IO)

    // ── Native declarations ────────────────────────────────────────────────
    private external fun nativeLoadModel(paramPath: String, binPath: String): Boolean
    private external fun nativeDetectObjects(yuvData: ByteArray, width: Int, height: Int): FloatArray
    private external fun nativeReleaseModel()

    companion object {
        init {
            try {
                System.loadLibrary("narrator_ncnn")
            } catch (e: UnsatisfiedLinkError) {
                android.util.Log.w("NarratorPlugin", "narrator_ncnn.so not found — YOLOv8 disabled: ${e.message}")
            }
        }
    }

    // ── FlutterPlugin lifecycle ────────────────────────────────────────────
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        ncnnChannel = MethodChannel(binding.binaryMessenger, "com.narrator/ncnn_plugin")
        ncnnChannel.setMethodCallHandler(this)

        vlmChannel = MethodChannel(binding.binaryMessenger, "com.narrator/vlm_plugin")
        vlmChannel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ncnnChannel.setMethodCallHandler(null)
        vlmChannel.setMethodCallHandler(null)
    }

    // ── MethodCallHandler ─────────────────────────────────────────────────
    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {

            // ── NCNN / YOLOv8 ───────────────────────────────────────────
            "loadYoloModel" -> {
                val paramPath = call.argument<String>("paramPath") ?: run {
                    result.error("INVALID_ARGS", "paramPath missing", null); return
                }
                val binPath = call.argument<String>("binPath") ?: run {
                    result.error("INVALID_ARGS", "binPath missing", null); return
                }
                scope.launch {
                    val ok = try { nativeLoadModel(paramPath, binPath) } catch (e: Exception) { false }
                    android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(ok) }
                }
            }

            "detectObjects" -> {
                val yuv = call.argument<ByteArray>("yuvData") ?: run {
                    result.success(floatArrayOf()); return
                }
                val w = call.argument<Int>("width") ?: 0
                val h = call.argument<Int>("height") ?: 0
                scope.launch {
                    val detections = try {
                        nativeDetectObjects(yuv, w, h).toList()
                    } catch (e: Exception) {
                        emptyList<Float>()
                    }
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        result.success(detections)
                    }
                }
            }

            "releaseYoloModel" -> {
                scope.launch {
                    try { nativeReleaseModel() } catch (_: Exception) {}
                    android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(null) }
                }
            }

            // ── VLM (llama.cpp stub — wire to actual JNI in production) ──
            "getAvailableRamMb" -> {
                val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                val mi = ActivityManager.MemoryInfo()
                am.getMemoryInfo(mi)
                val availMb = (mi.totalMem / 1024 / 1024).toInt()
                result.success(availMb)
            }

            "loadVlmModel" -> {
                val modelPath = call.argument<String>("modelPath") ?: ""
                val tier = call.argument<String>("tier") ?: "smolvlm256m"
                if (!File(modelPath).exists()) {
                    result.success(false); return
                }
                scope.launch {
                    // In production: call llama_cpp_android JNI here
                    // val ok = LlamaCppBridge.loadModel(modelPath, contextSize, threads)
                    val ok = true // stub — replace with real init
                    android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(ok) }
                }
            }

            "generateResponse" -> {
                val imgBytes = call.argument<ByteArray>("imageBytes") ?: ByteArray(0)
                val prompt = call.argument<String>("prompt") ?: ""
                val maxTokens = call.argument<Int>("maxTokens") ?: 256

                scope.launch {
                    // In production: LlamaCppBridge.generateStream(imgBytes, prompt) { token ->
                    //     vlmChannel.invokeMethod("onToken", token)  // streaming
                    // }
                    // Stub: simulate streaming for development
                    val mockResponse = "I can see the scene in front of you. " +
                        "There appears to be a clear path ahead. " +
                        "No immediate obstacles detected in the frame."
                    val sentences = mockResponse.split(". ")
                    sentences.forEachIndexed { i, sentence ->
                        Thread.sleep(300)
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            vlmChannel.invokeMethod("onToken", "$sentence${if (i < sentences.size - 1) ". " else ""}")
                        }
                    }
                    Thread.sleep(100)
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        vlmChannel.invokeMethod("onGenerationDone", null)
                        result.success(null)
                    }
                }
            }

            "releaseVlmModel" -> {
                // LlamaCppBridge.release()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }
}
