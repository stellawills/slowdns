package com.iptunnel.tunnel.helper;

import android.provider.Settings;

import com.google.firebase.FirebaseApp;
import com.google.firebase.auth.FirebaseAuth;
import com.iptunnel.tunnel.MyApplication;
import com.iptunnel.tunnel.BuildConfig;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.concurrent.ThreadLocalRandom;

public final class AppApiClient {

    private AppApiClient() {}

    public static final class CoinState {
        public boolean success;
        public int coins;
        public boolean banned;
        public boolean canRedeem;
        public boolean canReceiveCoins;
        public boolean canSendCoins;
        public boolean adOnlyEarning;
        public String error;
    }

    public static final class GenericResult {
        public boolean success;
        public String error;
        public String id;
    }

    public static final class ProvisioningResult {
        public boolean success;
        public boolean reused;
        public JSONObject raw;
        public JSONObject device;
        public JSONObject credential;
        public String error;
    }

    public static final class SignResult {
        public boolean success;
        public JSONObject payload;
        public String error;
    }

    public static CoinState fetchCoinState() {
        try {
            String deviceId = Helper.getID(MyApplication.getContext());
            if (deviceId == null || deviceId.isEmpty()) return null;

            JSONObject res = getJson(AppData.coin_state_api + "&deviceId=" + java.net.URLEncoder.encode(deviceId, "UTF-8"));
            if (res == null) return null;

            CoinState state = new CoinState();
            state.success = res.optBoolean("success", false);
            state.coins = res.optInt("coins", 0);
            state.banned = res.optBoolean("banned", false);
            state.canRedeem = res.optBoolean("canRedeem", true);
            state.canReceiveCoins = res.optBoolean("canReceiveCoins", true);
            state.canSendCoins = res.optBoolean("canSendCoins", true);
            state.adOnlyEarning = res.optBoolean("adOnlyEarning", false);
            state.error = res.optString("error", "");
            return state;
        } catch (Exception ignored) {
            return null;
        }
    }

    public static boolean syncCoins(int coins) {
        try {
            String deviceId = Helper.getID(MyApplication.getContext());
            if (deviceId == null || deviceId.isEmpty()) return false;

            JSONObject body = new JSONObject();
            body.put("deviceId", deviceId);
            body.put("coins", coins);
            String authUid = getAuthUidSafely();
            if (authUid != null) {
                body.put("authUid", authUid);
            }

            JSONObject res = postJson(AppData.coin_sync_api, body);
            return res != null && res.optBoolean("success", false);
        } catch (Exception ignored) {
            return false;
        }
    }

    public static boolean redeemCode(String code, int coins) {
        try {
            String deviceId = Helper.getID(MyApplication.getContext());
            if (deviceId == null || deviceId.isEmpty()) return false;

            JSONObject body = new JSONObject();
            body.put("deviceId", deviceId);
            body.put("code", code);
            body.put("coins", coins);
            String authUid = getAuthUidSafely();
            if (authUid != null) {
                body.put("authUid", authUid);
            }

            JSONObject res = postJson(AppData.redeem_api, body);
            return res != null && res.optBoolean("success", false);
        } catch (Exception ignored) {
            return false;
        }
    }

    public static ProvisioningResult deviceRegister() {
        try {
            JSONObject body = buildProvisioningBody();
            JSONObject res = postJson(AppData.device_register_api, body);
            return toProvisioningResult(res);
        } catch (Exception e) {
            ProvisioningResult result = new ProvisioningResult();
            result.success = false;
            result.error = e.getMessage() == null ? "device_register_failed" : e.getMessage();
            return result;
        }
    }

    public static ProvisioningResult deviceProvision(String protocol, boolean forceRotate, String serverId) {
        try {
            JSONObject body = buildProvisioningBody();
            if (protocol != null && !protocol.trim().isEmpty()) {
                body.put("protocol", protocol.trim());
            }
            if (forceRotate) {
                body.put("forceRotate", true);
            }
            if (serverId != null && !serverId.trim().isEmpty()) {
                body.put("serverId", serverId.trim());
            }
            JSONObject res = postJson(AppData.device_provision_api, body);
            return toProvisioningResult(res);
        } catch (Exception e) {
            ProvisioningResult result = new ProvisioningResult();
            result.success = false;
            result.error = e.getMessage() == null ? "device_provision_failed" : e.getMessage();
            return result;
        }
    }

    public static ProvisioningResult deviceCredentials(String protocol) {
        try {
            String url = AppData.device_credentials_api;
            if (protocol != null && !protocol.trim().isEmpty()) {
                url += "&protocol=" + java.net.URLEncoder.encode(protocol.trim(), "UTF-8");
            }
            JSONObject res = getJson(url);
            return toProvisioningResult(res);
        } catch (Exception e) {
            ProvisioningResult result = new ProvisioningResult();
            result.success = false;
            result.error = e.getMessage() == null ? "device_credentials_failed" : e.getMessage();
            return result;
        }
    }

    public static ProvisioningResult deviceRotate(String protocol) {
        try {
            JSONObject body = buildProvisioningBody();
            if (protocol != null && !protocol.trim().isEmpty()) {
                body.put("protocol", protocol.trim());
            }
            JSONObject res = postJson(AppData.device_rotate_api, body);
            return toProvisioningResult(res);
        } catch (Exception e) {
            ProvisioningResult result = new ProvisioningResult();
            result.success = false;
            result.error = e.getMessage() == null ? "device_rotate_failed" : e.getMessage();
            return result;
        }
    }

    public static ProvisioningResult deviceRevoke(String protocol, String reason) {
        try {
            JSONObject body = buildProvisioningBody();
            if (protocol != null && !protocol.trim().isEmpty()) {
                body.put("protocol", protocol.trim());
            }
            if (reason != null && !reason.trim().isEmpty()) {
                body.put("reason", reason.trim());
            }
            JSONObject res = postJson(AppData.device_revoke_api, body);
            return toProvisioningResult(res);
        } catch (Exception e) {
            ProvisioningResult result = new ProvisioningResult();
            result.success = false;
            result.error = e.getMessage() == null ? "device_revoke_failed" : e.getMessage();
            return result;
        }
    }

    public static ProvisioningResult deviceHeartbeat() {
        try {
            JSONObject body = buildProvisioningBody();
            JSONObject res = postJson(AppData.device_heartbeat_api, body);
            return toProvisioningResult(res);
        } catch (Exception e) {
            ProvisioningResult result = new ProvisioningResult();
            result.success = false;
            result.error = e.getMessage() == null ? "device_heartbeat_failed" : e.getMessage();
            return result;
        }
    }

    public static SignResult signImportPayloadDetailed(JSONObject payload) {
        SignResult result = new SignResult();
        result.success = false;
        result.error = "";
        result.payload = null;
        try {
            if (payload == null) {
                result.error = "Payload is empty";
                return result;
            }
            JSONObject body = new JSONObject();
            body.put("payload", payload);
            JSONObject res = postJson(AppData.app_sign_import_api, body);
            if (res == null) {
                result.error = "No response from signing API";
                return result;
            }
            if (!res.optBoolean("success", false)) {
                String err = res.optString("error", "");
                String detail = res.optString("detail", "");
                String reason = res.optString("reason", "");
                if (detail != null && !detail.trim().isEmpty()) {
                    result.error = detail.trim();
                } else if (err != null && !err.trim().isEmpty()) {
                    result.error = err.trim();
                } else if (reason != null && !reason.trim().isEmpty()) {
                    result.error = reason.trim();
                } else {
                    result.error = "Signing API rejected request";
                }
                return result;
            }
            JSONObject signedPayload = res.optJSONObject("payload");
            if (signedPayload == null) {
                result.error = "API did not return signed payload";
                return result;
            }
            result.success = true;
            result.payload = signedPayload;
            result.error = "";
            return result;
        } catch (Exception e) {
            result.error = (e.getMessage() == null || e.getMessage().trim().isEmpty())
                    ? "Signing request failed"
                    : e.getMessage();
            return result;
        }
    }

    public static JSONObject signImportPayload(JSONObject payload) {
        SignResult result = signImportPayloadDetailed(payload);
        return result.success ? result.payload : null;
    }

    public static String publishCloudConfig(String encryptedConfig, boolean autoDelete5Min, boolean deleteAfterFirstAccess, String configName) {
        try {
            JSONObject body = new JSONObject();
            body.put("config", encryptedConfig);
            body.put("autoDelete5Min", autoDelete5Min);
            body.put("deleteAfterFirstAccess", deleteAfterFirstAccess);
            body.put("configName", configName == null ? "Cloud Config" : configName);
            JSONObject res = postJson(AppData.app_cloud_publish_api, body);
            if (res == null || !res.optBoolean("success", false)) return null;
            return res.optString("key", null);
        } catch (Exception ignored) {
            return null;
        }
    }

    public static JSONObject fetchCloudConfig(String key) {
        return fetchCloudConfig(key, true);
    }

    private static JSONObject fetchCloudConfig(String key, boolean allowSessionRetry) {
        HttpURLConnection conn = null;
        try {
            String urlString = AppData.cloud_fetch_api + "&key=" + java.net.URLEncoder.encode(key, "UTF-8");
            URL url = new URL(urlString);
            String deviceId = Helper.getID(MyApplication.getContext());
            long ts = System.currentTimeMillis() / 1000L;
            String nonce = Long.toHexString(ThreadLocalRandom.current().nextLong(Long.MAX_VALUE));
            String signature = AppAuthConfig.buildSignature("GET", url, deviceId, ts, nonce);
            String authMode = AppAuthConfig.getAuthMode();
            String appSession = AppIntegrityAuth.getOrRefreshSession(url, deviceId);
            if (isProtectedSessionMissing(appSession)) {
                return buildSessionUnavailableResponse();
            }

            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("GET");
            conn.setConnectTimeout(15000);
            conn.setReadTimeout(15000);
            applyAppHeaders(conn, url, "GET", deviceId, ts, nonce, signature, appSession, authMode);
            int code = conn.getResponseCode();
            InputStream in = (code >= 200 && code < 300) ? conn.getInputStream() : conn.getErrorStream();
            if (in == null) return null;
            String text = readAll(in);
            JSONObject obj = new JSONObject(text);
            if (allowSessionRetry && isSessionRetryResponse(code, obj)) {
                AppIntegrityAuth.clearSession();
                return fetchCloudConfig(key, false);
            }
            obj.put("_http", code);
            return obj;
        } catch (Exception ignored) {
            return null;
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    public static boolean touchCloudConfig(String key, String mode) {
        try {
            JSONObject body = new JSONObject();
            body.put("key", key);
            body.put("mode", mode == null ? "touch" : mode);
            JSONObject res = postJson(AppData.cloud_touch_api, body);
            return res != null && res.optBoolean("success", false);
        } catch (Exception ignored) {
            return false;
        }
    }

    public static GenericResult submitSupportRequest(JSONObject body) {
        GenericResult result = new GenericResult();
        HttpURLConnection conn = null;
        try {
            URL url = new URL(AppData.support_submit_api);
            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setConnectTimeout(15000);
            conn.setReadTimeout(15000);
            conn.setDoOutput(true);
            conn.setRequestProperty("Content-Type", "application/json");

            byte[] payload = body.toString().getBytes(StandardCharsets.UTF_8);
            OutputStream out = conn.getOutputStream();
            out.write(payload);
            out.flush();
            out.close();

            int code = conn.getResponseCode();
            InputStream in = (code >= 200 && code < 300) ? conn.getInputStream() : conn.getErrorStream();
            if (in == null) {
                result.success = false;
                result.error = "No response";
                return result;
            }
            String text = readAll(in);
            JSONObject obj = new JSONObject(text);
            result.success = obj.optBoolean("success", false);
            result.id = obj.optString("id", "");
            result.error = obj.optString("error", obj.optString("detail", ""));
            if (!result.success && (result.error == null || result.error.trim().isEmpty())) {
                result.error = "HTTP " + code;
            }
            return result;
        } catch (Exception e) {
            result.success = false;
            result.error = e.getMessage() == null ? "Request failed" : e.getMessage();
            return result;
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    private static JSONObject postJson(String urlString, JSONObject body) {
        return postJson(urlString, body, true);
    }

    private static JSONObject postJson(String urlString, JSONObject body, boolean allowSessionRetry) {
        HttpURLConnection conn = null;
        try {
            URL url = new URL(urlString);
            String deviceId = Helper.getID(MyApplication.getContext());
            long ts = System.currentTimeMillis() / 1000L;
            String nonce = Long.toHexString(ThreadLocalRandom.current().nextLong(Long.MAX_VALUE));
            String signature = AppAuthConfig.buildSignature("POST", url, deviceId, ts, nonce);
            String authMode = AppAuthConfig.getAuthMode();
            String appSession = AppIntegrityAuth.getOrRefreshSession(url, deviceId);
            if (isProtectedSessionMissing(appSession)) {
                return buildSessionUnavailableResponse();
            }

            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setConnectTimeout(15000);
            conn.setReadTimeout(15000);
            conn.setDoOutput(true);
            conn.setRequestProperty("Content-Type", "application/json");
            applyAppHeaders(conn, url, "POST", deviceId, ts, nonce, signature, appSession, authMode);

            byte[] payload = body.toString().getBytes(StandardCharsets.UTF_8);
            OutputStream out = conn.getOutputStream();
            out.write(payload);
            out.flush();
            out.close();

            int code = conn.getResponseCode();
            InputStream in = (code >= 200 && code < 300) ? conn.getInputStream() : conn.getErrorStream();
            if (in == null) return null;
            String text = readAll(in);
            JSONObject obj = new JSONObject(text);
            if (allowSessionRetry && isSessionRetryResponse(code, obj)) {
                AppIntegrityAuth.clearSession();
                return postJson(urlString, body, false);
            }
            return obj;
        } catch (Exception e) {
            return null;
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    private static JSONObject getJson(String urlString) {
        return getJson(urlString, true);
    }

    private static JSONObject getJson(String urlString, boolean allowSessionRetry) {
        HttpURLConnection conn = null;
        try {
            URL url = new URL(urlString);
            String deviceId = Helper.getID(MyApplication.getContext());
            long ts = System.currentTimeMillis() / 1000L;
            String nonce = Long.toHexString(ThreadLocalRandom.current().nextLong(Long.MAX_VALUE));
            String signature = AppAuthConfig.buildSignature("GET", url, deviceId, ts, nonce);
            String authMode = AppAuthConfig.getAuthMode();
            String appSession = AppIntegrityAuth.getOrRefreshSession(url, deviceId);
            if (isProtectedSessionMissing(appSession)) {
                return buildSessionUnavailableResponse();
            }

            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("GET");
            conn.setConnectTimeout(15000);
            conn.setReadTimeout(15000);
            applyAppHeaders(conn, url, "GET", deviceId, ts, nonce, signature, appSession, authMode);

            int code = conn.getResponseCode();
            InputStream in = (code >= 200 && code < 300) ? conn.getInputStream() : conn.getErrorStream();
            if (in == null) return null;
            String text = readAll(in);
            JSONObject obj = new JSONObject(text);
            if (allowSessionRetry && isSessionRetryResponse(code, obj)) {
                AppIntegrityAuth.clearSession();
                return getJson(urlString, false);
            }
            return obj;
        } catch (Exception e) {
            return null;
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    private static boolean isProtectedSessionMissing(String appSession) {
        return AppAuthConfig.isSessionV2Mode()
                && (appSession == null || appSession.trim().isEmpty());
    }

    private static JSONObject buildProvisioningBody() throws Exception {
        JSONObject body = new JSONObject();
        String deviceId = Helper.getID(MyApplication.getContext());
        if (deviceId == null) deviceId = "";
        body.put("deviceId", deviceId);
        String authUid = getAuthUidSafely();
        if (authUid != null && !authUid.trim().isEmpty()) {
            body.put("authUid", authUid.trim());
        }
        String androidId = "";
        try {
            androidId = Settings.Secure.getString(
                    MyApplication.getContext().getContentResolver(),
                    Settings.Secure.ANDROID_ID
            );
        } catch (Exception ignored) {
        }
        if (androidId != null && !androidId.trim().isEmpty()) {
            body.put("androidIdHash", sha256Hex(androidId.trim()).toLowerCase());
        }
        body.put("packageName", BuildConfig.APPLICATION_ID);
        body.put("appVersion", String.valueOf(BuildConfig.VERSION_CODE));
        return body;
    }

    private static ProvisioningResult toProvisioningResult(JSONObject res) {
        ProvisioningResult result = new ProvisioningResult();
        result.raw = res;
        if (res == null) {
            result.success = false;
            result.error = "No response";
            return result;
        }
        result.success = res.optBoolean("success", false);
        result.reused = res.optBoolean("reused", false);
        result.device = res.optJSONObject("device");
        result.credential = res.optJSONObject("credential");
        String error = res.optString("error", "");
        String reason = res.optString("reason", "");
        String detail = res.optString("detail", "");
        if (!result.success) {
            if (detail != null && !detail.trim().isEmpty()) {
                result.error = detail.trim();
            } else if (error != null && !error.trim().isEmpty()) {
                result.error = error.trim();
            } else if (reason != null && !reason.trim().isEmpty()) {
                result.error = reason.trim();
            } else {
                result.error = "Request failed";
            }
        } else {
            result.error = "";
        }
        return result;
    }

    private static String sha256Hex(String value) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] out = digest.digest(value.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(out.length * 2);
            for (byte b : out) {
                sb.append(String.format("%02x", b));
            }
            return sb.toString();
        } catch (Exception e) {
            return "";
        }
    }

    private static JSONObject buildSessionUnavailableResponse() {
        try {
            JSONObject obj = new JSONObject();
            obj.put("success", false);
            obj.put("error", "secure_session_unavailable");
            obj.put("reason", "session_bootstrap_failed");
            return obj;
        } catch (Exception ignored) {
            return null;
        }
    }

    private static boolean isSessionRetryResponse(int httpCode, JSONObject obj) {
        if (httpCode != HttpURLConnection.HTTP_UNAUTHORIZED || obj == null) {
            return false;
        }
        String reason = obj.optString("reason", "");
        return "missing_session".equalsIgnoreCase(reason)
                || "invalid_session".equalsIgnoreCase(reason)
                || "session_device_mismatch".equalsIgnoreCase(reason);
    }

    private static void applyAppHeaders(HttpURLConnection conn, URL url, String method, String deviceId, long ts, String nonce, String signature, String appSession, String authMode) {
        conn.setRequestProperty("X-App-Id", AppAuthConfig.getClientId());
        conn.setRequestProperty("X-App-Device", deviceId);
        conn.setRequestProperty("X-App-Ts", String.valueOf(ts));
        conn.setRequestProperty("X-App-Nonce", nonce);
        conn.setRequestProperty("X-App-Auth-Mode", authMode);
        if (signature != null && !signature.isEmpty()) {
            conn.setRequestProperty("X-App-Sign", signature);
        }
        conn.setRequestProperty("X-App-Version", String.valueOf(BuildConfig.VERSION_CODE));
        if (appSession != null && !appSession.isEmpty()) {
            conn.setRequestProperty("X-App-Session", appSession);
        }
    }

    private static String readAll(InputStream in) throws Exception {
        BufferedReader reader = new BufferedReader(new InputStreamReader(in, "iso-8859-1"), 8);
        StringBuilder str = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) {
            str.append(line);
        }
        in.close();
        return str.toString();
    }

    private static String getAuthUidSafely() {
        try {
            if (MyApplication.getContext() == null) return null;
            if (FirebaseApp.getApps(MyApplication.getContext()).isEmpty()) return null;
            FirebaseAuth auth = FirebaseAuth.getInstance();
            if (auth.getCurrentUser() != null) {
                return auth.getCurrentUser().getUid();
            }
        } catch (Exception ignored) {
        }
        return null;
    }
}

