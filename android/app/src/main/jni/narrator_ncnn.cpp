#include <jni.h>
#include <string>
#include <vector>
#include <android/log.h>
#include "ncnn/net.h"
#include "ncnn/mat.h"

#define LOG_TAG "NarratorNCNN"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ── YOLO Output Structure ─────────────────────────────────────────────────────
struct Detection {
    int classId;
    float confidence;
    float x1, y1, x2, y2; // normalized [0,1]
};

// ── Obstacle class IDs (COCO 80-class) ───────────────────────────────────────
// 0:person, 56:chair, 57:couch, 58:potted plant, 59:bed, 60:dining table,
// 61:toilet, 62:tv, 63:laptop, 64:mouse, 2:car, 3:motorcycle, 1:bicycle,
// 9:traffic light, 11:stop sign, 13:bench
static const std::vector<int> OBSTACLE_CLASSES = {
    0, 1, 2, 3, 5, 7, 9, 11, 13, 56, 57, 58, 59, 60, 61, 62, 63
};

static ncnn::Net yoloNet;
static bool modelLoaded = false;
static const int INPUT_SIZE = 320; // YOLOv8n input size
static const float CONF_THRESHOLD = 0.45f;
static const float NMS_THRESHOLD = 0.45f;

// ── Load model from file paths ────────────────────────────────────────────────
extern "C" JNIEXPORT jboolean JNICALL
Java_com_narrator_NarratorPlugin_loadModel(
    JNIEnv *env, jobject /*thiz*/,
    jstring paramPath, jstring binPath) {

    const char *param = env->GetStringUTFChars(paramPath, nullptr);
    const char *bin   = env->GetStringUTFChars(binPath, nullptr);

    yoloNet.opt.use_vulkan_compute = false;
    yoloNet.opt.num_threads = 4;
    yoloNet.opt.use_bf16_storage = true;

    int ret = yoloNet.load_param(param);
    if (ret != 0) {
        LOGE("Failed to load param: %s", param);
        env->ReleaseStringUTFChars(paramPath, param);
        env->ReleaseStringUTFChars(binPath, bin);
        return JNI_FALSE;
    }
    ret = yoloNet.load_model(bin);
    if (ret != 0) {
        LOGE("Failed to load model: %s", bin);
        env->ReleaseStringUTFChars(paramPath, param);
        env->ReleaseStringUTFChars(binPath, bin);
        return JNI_FALSE;
    }

    env->ReleaseStringUTFChars(paramPath, param);
    env->ReleaseStringUTFChars(binPath, bin);
    modelLoaded = true;
    LOGI("YOLOv8-nano loaded successfully");
    return JNI_TRUE;
}

// ── NMS ───────────────────────────────────────────────────────────────────────
static float iou(const Detection &a, const Detection &b) {
    float interX1 = std::max(a.x1, b.x1);
    float interY1 = std::max(a.y1, b.y1);
    float interX2 = std::min(a.x2, b.x2);
    float interY2 = std::min(a.y2, b.y2);
    float interArea = std::max(0.f, interX2 - interX1) * std::max(0.f, interY2 - interY1);
    float aArea = (a.x2 - a.x1) * (a.y2 - a.y1);
    float bArea = (b.x2 - b.x1) * (b.y2 - b.y1);
    return interArea / (aArea + bArea - interArea + 1e-6f);
}

static std::vector<Detection> nms(std::vector<Detection> &dets) {
    std::sort(dets.begin(), dets.end(),
        [](const Detection &a, const Detection &b) { return a.confidence > b.confidence; });
    std::vector<Detection> result;
    std::vector<bool> suppressed(dets.size(), false);
    for (size_t i = 0; i < dets.size(); i++) {
        if (suppressed[i]) continue;
        result.push_back(dets[i]);
        for (size_t j = i + 1; j < dets.size(); j++) {
            if (!suppressed[j] && dets[i].classId == dets[j].classId &&
                iou(dets[i], dets[j]) > NMS_THRESHOLD) {
                suppressed[j] = true;
            }
        }
    }
    return result;
}

// ── Main inference call ───────────────────────────────────────────────────────
// Returns float array: [classId, conf, x1, y1, x2, y2, ...] per detection
extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_narrator_NarratorPlugin_detectObjects(
    JNIEnv *env, jobject /*thiz*/,
    jbyteArray yuvData, jint width, jint height) {

    if (!modelLoaded) {
        LOGE("Model not loaded");
        return env->NewFloatArray(0);
    }

    jbyte *yuv = env->GetByteArrayElements(yuvData, nullptr);

    // YUV420 → NCNN RGB Mat
    int rgb_size = width * height * 3;
std::vector<unsigned char> rgb(rgb_size);

const unsigned char* y_plane = reinterpret_cast<const unsigned char*>(yuv);
const unsigned char* uv_plane = y_plane + width * height;

for (int row = 0; row < height; row++) {
    for (int col = 0; col < width; col++) {
        int y_val = y_plane[row * width + col];
        int uv_row = row / 2;
        int uv_col = (col / 2) * 2;
        int v_val = uv_plane[uv_row * width + uv_col];
        int u_val = uv_plane[uv_row * width + uv_col + 1];

        int r = y_val + 1.402f * (v_val - 128);
        int g = y_val - 0.344136f * (u_val - 128) - 0.714136f * (v_val - 128);
        int b = y_val + 1.772f * (u_val - 128);

        int idx = (row * width + col) * 3;
        rgb[idx]     = (unsigned char)std::clamp(r, 0, 255);
        rgb[idx + 1] = (unsigned char)std::clamp(g, 0, 255);
        rgb[idx + 2] = (unsigned char)std::clamp(b, 0, 255);
    }
}

    ncnn::Mat in = ncnn::Mat::from_pixels(rgb.data(), ncnn::Mat::PIXEL_RGB, width, height);

    env->ReleaseByteArrayElements(yuvData, yuv, JNI_ABORT);

    // Resize to input size
    ncnn::Mat in_resized;
    ncnn::resize_bilinear(in, in_resized, INPUT_SIZE, INPUT_SIZE);

    // Normalize: mean=[0,0,0] std=[255,255,255]
    const float norm_vals[3] = {1.f / 255.f, 1.f / 255.f, 1.f / 255.f};
    in_resized.substract_mean_normalize(nullptr, norm_vals);

    ncnn::Extractor ex = yoloNet.create_extractor();
    ex.set_light_mode(true);
    ex.input("images", in_resized);

    ncnn::Mat out;
    ex.extract("output0", out);

    // Parse YOLOv8 output: [batch, 84, num_anchors] → transposed
    // out shape: (84, 8400) for 320x320 input
    int num_anchors = out.w;
    int num_classes = out.h - 4;

    std::vector<Detection> detections;
    for (int i = 0; i < num_anchors; i++) {
        float cx = out.channel(0)[i];
        float cy = out.channel(1)[i];
        float bw = out.channel(2)[i];
        float bh = out.channel(3)[i];

        // Find best class
        float maxConf = -1.f;
        int bestClass = -1;
        for (int c = 0; c < num_classes; c++) {
            float conf = out.channel(4 + c)[i];
            if (conf > maxConf) { maxConf = conf; bestClass = c; }
        }

        if (maxConf < CONF_THRESHOLD) continue;

        // Check if obstacle class
        bool isObstacle = false;
        for (int oc : OBSTACLE_CLASSES) {
            if (oc == bestClass) { isObstacle = true; break; }
        }
        if (!isObstacle) continue;

        // Normalize coords
        float x1 = (cx - bw * 0.5f) / INPUT_SIZE;
        float y1 = (cy - bh * 0.5f) / INPUT_SIZE;
        float x2 = (cx + bw * 0.5f) / INPUT_SIZE;
        float y2 = (cy + bh * 0.5f) / INPUT_SIZE;
        x1 = std::max(0.f, std::min(1.f, x1));
        y1 = std::max(0.f, std::min(1.f, y1));
        x2 = std::max(0.f, std::min(1.f, x2));
        y2 = std::max(0.f, std::min(1.f, y2));

        detections.push_back({bestClass, maxConf, x1, y1, x2, y2});
    }

    auto result = nms(detections);

    // Pack into float array: 6 floats per detection
    jfloatArray ret = env->NewFloatArray(result.size() * 6);
    if (!result.empty()) {
        std::vector<float> buf;
        buf.reserve(result.size() * 6);
        for (auto &d : result) {
            buf.push_back(static_cast<float>(d.classId));
            buf.push_back(d.confidence);
            buf.push_back(d.x1);
            buf.push_back(d.y1);
            buf.push_back(d.x2);
            buf.push_back(d.y2);
        }
        env->SetFloatArrayRegion(ret, 0, buf.size(), buf.data());
    }
    return ret;
}

extern "C" JNIEXPORT void JNICALL
Java_com_narrator_NarratorPlugin_releaseModel(
    JNIEnv * /*env*/, jobject /*thiz*/) {
    yoloNet.clear();
    modelLoaded = false;
    LOGI("Model released");
}
