package com.iptunnel.tunnel.helper;

import android.content.SharedPreferences;
import android.util.Base64;
import android.util.Log;

import com.google.android.gms.tasks.Tasks;
import com.google.android.play.core.integrity.IntegrityManager;
import com.google.android.play.core.integrity.IntegrityManagerFactory;
import com.google.android.play.core.integrity.IntegrityTokenRequest;
import com.google.android.play.core.integrity.IntegrityTokenResponse;
import com.iptunnel.tunnel.BuildConfig;
import com.iptunnel.tunnel.MyApplication;
import com.iptunnel.tunnel.R;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.concurrent.TimeUnit;

public final class AppIntegrityAuth {

    private static final String TAG = "AppIntegrityAuth";
    private static final String KEY_SESSION_TOKEN = "app_session_token";
    private static final String KEY_SESSION_EXP = "app_session_exp";
    private static final String KEY_INTEGRITY_BACKOFF_UNTIL = "integrity_backoff_until";
    private static final String KEY_INTEGRITY_BACKOFF_LEVEL = "integrity_backoff_level";
    private static final long SESSION_SKEW_SECONDS = 30L;
    private static final long[] THROTTLE_BACKOFF_MS = new long[]{
            15L * 60L * 1000L,
            30L * 60L * 1000L,
            60L * 60L * 1000L,
            3L * 60L * 60L * 1000L,
            6L * 60L * 60L * 1000L
    };
    private static final SecureRandom NONCE_RANDOM = new SecureRandom();
    private static volatile String memorySessionToken = "";
    private static volatile long memorySessionExp = 0L;
    private static volatile long memoryIntegrityBackoffUntil = 0L;
    private static volatile int memoryIntegrityBackoffLevel = 0;

    private AppIntegrityAuth() {}

    public static synchronized String getOrRefreshSession(URL anyApiUrl, String deviceId) {
        SharedPreferences prefs = null;
        try {
            long now = System.currentTimeMillis() / 1000L;

            if (memorySessionToken != null && !memorySessionToken.isEmpty() && memorySessionExp > (now + SESSION_SKEW_SECONDS)) {
                return memorySessionToken;
            }

            try {
                prefs = MyApplication.getSharedPreferences();
            } catch (Exception e) {
                Log.w(TAG, "SharedPreferences unavailable for app session cache", e);
            }

            if (prefs != null) {
                try {
                    String cached = prefs.getString(KEY_SESSION_TOKEN, "");
                    long exp = prefs.getLong(KEY_SESSION_EXP, 0L);
                    if (cached != null && !cached.isEmpty() && exp > (now + SESSION_SKEW_SECONDS)) {
                        memorySessionToken = cached;
                        memorySessionExp = exp;
                        return cached;
                    }
                } catch (Exception e) {
                    Log.w(TAG, "Session cache read failed, requesting fresh session", e);
                    clearSessionLocked(prefs);
                }
            }

            long nowMs = System.currentTimeMillis();
            long backoffUntil = getIntegrityBackoffUntil(prefs);
            if (backoffUntil > nowMs) {
                DependencyDiagnostics.reportFailure(
                        DependencyDiagnostics.DOMAIN_INTEGRITY,
                        DependencyDiagnostics.STAGE_SESSION_BOOTSTRAP,
                        "INTEGRITY_BACKOFF_ACTIVE",
                        "Integrity cooldown active",
                        R.string.secure_update_verification_failed
                );
                return "";
            }

            DependencyDiagnostics.PlayServicesStatus playServicesStatus = DependencyDiagnostics.checkPlayServices(
                    MyApplication.getContext(),
                    DependencyDiagnostics.DOMAIN_INTEGRITY,
                    R.string.secure_update_play_services_issue
            );
            if (!playServicesStatus.available) {
                clearSessionLocked(prefs);
                return "";
            }

            String nonce = generateNonce();
            IntegrityManager integrityManager = IntegrityManagerFactory.create(MyApplication.getContext());
            IntegrityTokenRequest request = IntegrityTokenRequest.builder()
                    .setNonce(nonce)
                    .build();
            IntegrityTokenResponse tokenResponse = Tasks.await(
                    integrityManager.requestIntegrityToken(request),
                    20,
                    TimeUnit.SECONDS
            );
            String integrityToken = tokenResponse.token();
            if (integrityToken == null || integrityToken.isEmpty()) {
                DependencyDiagnostics.reportFailure(
                        DependencyDiagnostics.DOMAIN_INTEGRITY,
                        DependencyDiagnostics.STAGE_SESSION_BOOTSTRAP,
                        "PLAY_INTEGRITY_EMPTY_TOKEN",
                        "Play Integrity returned empty token",
                        R.string.secure_update_verification_failed
                );
                return "";
            }

            String attestUrl = buildAttestUrl(anyApiUrl);
            URL url = new URL(attestUrl);
            long ts = System.currentTimeMillis() / 1000L;
            String signature = AppAuthConfig.buildSignature("POST", url, deviceId, ts, nonce);
            String authMode = AppAuthConfig.getAuthMode();

            JSONObject body = new JSONObject();
            body.put("integrityToken", integrityToken);
            body.put("nonce", nonce);
            body.put("deviceId", deviceId);

            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setConnectTimeout(15000);
            conn.setReadTimeout(15000);
            conn.setDoOutput(true);
            conn.setRequestProperty("Content-Type", "application/json");
            conn.setRequestProperty("X-App-Id", AppAuthConfig.getClientId());
            conn.setRequestProperty("X-App-Device", deviceId);
            conn.setRequestProperty("X-App-Ts", String.valueOf(ts));
            conn.setRequestProperty("X-App-Nonce", nonce);
            conn.setRequestProperty("X-App-Auth-Mode", authMode);
            if (signature != null && !signature.isEmpty()) {
                conn.setRequestProperty("X-App-Sign", signature);
            }
            conn.setRequestProperty("X-App-Version", String.valueOf(BuildConfig.VERSION_CODE));

            byte[] payload = body.toString().getBytes(StandardCharsets.UTF_8);
            OutputStream out = conn.getOutputStream();
            out.write(payload);
            out.flush();
            out.close();

            int code = conn.getResponseCode();
            InputStream in = (code >= 200 && code < 300) ? conn.getInputStream() : conn.getErrorStream();
            if (in == null) return "";
            String resp = readAll(in);
            JSONObject obj = new JSONObject(resp);
            if (code < 200 || code >= 300 || !obj.optBoolean("success", false)) {
                DependencyDiagnostics.reportFailure(
                        DependencyDiagnostics.DOMAIN_INTEGRITY,
                        DependencyDiagnostics.STAGE_SESSION_BOOTSTRAP,
                        "APP_ATTEST_HTTP_" + code,
                        trimForLog(resp),
                        R.string.secure_update_verification_failed
                );
                return "";
            }

            String session = obj.optString("app_session", "");
            long ttl = obj.optLong("expires_in", 0L);
            if (session.isEmpty() || ttl <= 0) {
                DependencyDiagnostics.reportFailure(
                        DependencyDiagnostics.DOMAIN_INTEGRITY,
                        DependencyDiagnostics.STAGE_SESSION_BOOTSTRAP,
                        "APP_ATTEST_EMPTY_SESSION",
                        "App attest did not return usable session",
                        R.string.secure_update_verification_failed
                );
                return "";
            }

            long expAt = now + ttl;
            memorySessionToken = session;
            memorySessionExp = expAt;
            clearIntegrityBackoffLocked(prefs);
            DependencyDiagnostics.reportSuccess(
                    DependencyDiagnostics.DOMAIN_INTEGRITY,
                    DependencyDiagnostics.STAGE_SESSION_BOOTSTRAP,
                    "SESSION_READY",
                    "expires_in=" + ttl
            );
            if (prefs != null) {
                try {
                    prefs.edit()
                            .putString(KEY_SESSION_TOKEN, session)
                            .putLong(KEY_SESSION_EXP, expAt)
                            .apply();
                } catch (Exception e) {
                    // Keep in-memory token valid for current runtime even if disk cache write fails.
                    Log.w(TAG, "Session cache write failed", e);
                }
            }
            return session;
        } catch (Exception e) {
            String code = DependencyDiagnostics.exceptionCode(e);
            if ("INTEGRITY_THROTTLED".equals(code)) {
                applyIntegrityBackoff(prefs);
            }
            DependencyDiagnostics.reportFailure(
                    DependencyDiagnostics.DOMAIN_INTEGRITY,
                    DependencyDiagnostics.STAGE_SESSION_BOOTSTRAP,
                    code,
                    e.getMessage(),
                    R.string.secure_update_verification_failed
            );
            return "";
        }
    }

    public static synchronized void clearSession() {
        SharedPreferences prefs = null;
        try {
            prefs = MyApplication.getSharedPreferences();
        } catch (Exception e) {
            Log.w(TAG, "SharedPreferences unavailable while clearing app session", e);
        }
        clearSessionLocked(prefs);
    }

    private static void clearSessionLocked(SharedPreferences prefs) {
        memorySessionToken = "";
        memorySessionExp = 0L;
        if (prefs != null) {
            try {
                prefs.edit()
                        .remove(KEY_SESSION_TOKEN)
                        .remove(KEY_SESSION_EXP)
                        .apply();
            } catch (Exception e) {
                Log.w(TAG, "Failed to clear app session cache", e);
            }
        }
    }

    private static long getIntegrityBackoffUntil(SharedPreferences prefs) {
        long inMemory = memoryIntegrityBackoffUntil;
        if (inMemory > System.currentTimeMillis()) {
            return inMemory;
        }
        if (prefs == null) {
            return 0L;
        }
        try {
            long storedUntil = prefs.getLong(KEY_INTEGRITY_BACKOFF_UNTIL, 0L);
            int storedLevel = prefs.getInt(KEY_INTEGRITY_BACKOFF_LEVEL, 0);
            memoryIntegrityBackoffUntil = storedUntil;
            memoryIntegrityBackoffLevel = Math.max(storedLevel, 0);
            return storedUntil;
        } catch (Exception e) {
            Log.w(TAG, "Failed to read integrity cooldown", e);
            return 0L;
        }
    }

    private static void applyIntegrityBackoff(SharedPreferences prefs) {
        int level = Math.min(memoryIntegrityBackoffLevel + 1, THROTTLE_BACKOFF_MS.length);
        long until = System.currentTimeMillis() + THROTTLE_BACKOFF_MS[level - 1];
        memoryIntegrityBackoffLevel = level;
        memoryIntegrityBackoffUntil = until;
        if (prefs == null) {
            return;
        }
        try {
            prefs.edit()
                    .putLong(KEY_INTEGRITY_BACKOFF_UNTIL, until)
                    .putInt(KEY_INTEGRITY_BACKOFF_LEVEL, level)
                    .apply();
        } catch (Exception e) {
            Log.w(TAG, "Failed to persist integrity cooldown", e);
        }
    }

    private static void clearIntegrityBackoffLocked(SharedPreferences prefs) {
        memoryIntegrityBackoffUntil = 0L;
        memoryIntegrityBackoffLevel = 0;
        if (prefs == null) {
            return;
        }
        try {
            prefs.edit()
                    .remove(KEY_INTEGRITY_BACKOFF_UNTIL)
                    .remove(KEY_INTEGRITY_BACKOFF_LEVEL)
                    .apply();
        } catch (Exception e) {
            Log.w(TAG, "Failed to clear integrity cooldown", e);
        }
    }

    private static String trimForLog(String value) {
        if (value == null) return "";
        if (value.length() <= 300) return value;
        return value.substring(0, 300) + "...";
    }

    private static String generateNonce() {
        byte[] raw = new byte[24];
        NONCE_RANDOM.nextBytes(raw);
        return Base64.encodeToString(raw, Base64.NO_WRAP | Base64.NO_PADDING | Base64.URL_SAFE);
    }

    private static String buildAttestUrl(URL anyApiUrl) {
        StringBuilder sb = new StringBuilder();
        sb.append(anyApiUrl.getProtocol()).append("://").append(anyApiUrl.getHost());
        int port = anyApiUrl.getPort();
        if (port > 0 && port != anyApiUrl.getDefaultPort()) {
            sb.append(":").append(port);
        }
        String path = anyApiUrl.getPath();
        if (path == null || path.isEmpty()) {
            path = "/api/v2/index.php";
        } else {
            int slash = path.lastIndexOf('/');
            if (slash >= 0) {
                path = path.substring(0, slash + 1) + "index.php";
            } else {
                path = "/api/v2/index.php";
            }
        }
        sb.append(path).append("?action=app_attest");
        return sb.toString();
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
}
