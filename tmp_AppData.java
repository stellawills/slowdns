package com.iptunnel.tunnel.helper;

import com.iptunnel.tunnel.BuildConfig;

public class AppData {

    public static String api_v2_base = "https://iptunnel.internetshub.com/api/v2/";

    public static String admin = "https://t.me/iptunnel_bot";
    public static String telegram = "https://t.me/IPTunnelVPN";

    public static String config_update_api = api_v2_base + "index.php?action=app_config";
    public static String coins_manager_api = api_v2_base + "index.php?action=app_coin_updates";
    public static String coin_state_api = api_v2_base + "index.php?action=app_coin_state";
    public static String coin_sync_api = api_v2_base + "index.php?action=app_coin_sync";
    public static String redeem_api = api_v2_base + "index.php?action=app_redeem_code";
    public static String app_sign_import_api = api_v2_base + "index.php?action=app_sign_import";
    public static String app_cloud_publish_api = api_v2_base + "index.php?action=app_cloud_publish";
    public static String cloud_fetch_api = api_v2_base + "index.php?action=cloud_fetch";
    public static String cloud_touch_api = api_v2_base + "index.php?action=cloud_touch";
    public static String app_policy_public_api = api_v2_base + "index.php?action=app_policy_public";
    public static String support_submit_api = api_v2_base + "index.php?action=support_submit";
    public static String device_register_api = api_v2_base + "device_provisioning.php?action=device_register";
    public static String device_provision_api = api_v2_base + "device_provisioning.php?action=device_provision";
    public static String device_credentials_api = api_v2_base + "device_provisioning.php?action=device_credentials";
    public static String device_rotate_api = api_v2_base + "device_provisioning.php?action=device_rotate";
    public static String device_revoke_api = api_v2_base + "device_provisioning.php?action=device_revoke";
    public static String device_heartbeat_api = api_v2_base + "device_provisioning.php?action=device_heartbeat";
    // App API auth settings are now sourced from BuildConfig/AppAuthConfig (not embedded here).

    public static int default_time = 30;
    public static int default_coins = 2;
    public static int add_coins = 2;

    // Sensitive defaults are injected at build-time via CI/local secrets.
    public static String default_config = BuildConfig.APP_DEFAULT_CONFIG_ENC;
    public static String config_pass = BuildConfig.APP_CONFIG_PASS;

    public static String default_BannerAd = "ca-app-pub-6658506429674535/1422431994";
    public static String default_RewardedAd = "ca-app-pub-6658506429674535/5162683687";
    public static String default_InterstitialAd = "ca-app-pub-6658506429674535/2352370289";
    public static String default_AppOpenAd = "ca-app-pub-6658506429674535/3713870644";

    public static String udp_certificate = BuildConfig.APP_UDP_CERTIFICATE_B64;

    public static String file_extension = "ipt";

    // Signed .ipt imports (set key from backend signer public key)
    public static boolean require_signed_import = true;
    public static String import_sign_key_id = "k1";
    public static String import_sign_public_key_pem = "-----BEGIN PUBLIC KEY-----\n" +
            "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA4f0zk6auGU7Nmu2uBLxq\n" +
            "jCHYDf81IaH2x1exuqsJd9Eg5e9VFd4I6zCCsQZgOkvxfSEupKW4rOk77gfIcd03\n" +
            "oNkNw5HUTGrRR9V1xeVTDBgTxJrzt+uaClUL0IYzgkA2nxhcZ9q1BSWUduZjjSuY\n" +
            "M0LHmO3ebwdJU5Offy9F5QeJzuf7VMiVYFC77tqxIy3e95G6/1o6rQV1+iujKsOY\n" +
            "H0PVppzng5nYUFJH1ZVVCsBA88ATM4yDkXlAU0UeY/xIE/7Szd0AjlbNFEY0byqt\n" +
            "j9B3myDv5v2ssns7DCxvla8LmrADiRcXy65gWWNRlM2aZgmSfd+YAdDbqpKXeRN1\n" +
            "XwIDAQAB\n" +
            "-----END PUBLIC KEY-----\n";
}
