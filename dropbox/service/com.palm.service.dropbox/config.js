/* config.js - Dropbox OAuth2 + API v2 endpoints.
 *
 * SCAFFOLD: register a free app at https://www.dropbox.com/developers/apps
 * (Scoped access; permissions: account_info.read, files.metadata.read,
 * files.content.read, files.content.write). Use token_access_type=offline so
 * you get a refresh_token (Dropbox access tokens are short-lived ~4h).
 */
var Config = {
	// Modern-TLS HTTP: the device node is OpenSSL 0.9.8k and cannot handshake with
	// api.dropboxapi.com, so ALL Dropbox HTTPS is shelled out to this curl.
	// deployment-bundle/usr/bin/curl = curl 7.88.1 + OpenSSL 1.1.1 (TLS 1.3) must be
	// installed at this path on-device.
	// Private modern-TLS curl bundle deployed at /var/dropbox-tls (curl 7.88.1 +
	// OpenSSL 1.1.1w; runs on the stock loader, needs only GLIBC_2.4). Its 3 libs
	// (libcurl.so.4, libssl.so.1.1, libcrypto.so.1.1) load via LD_LIBRARY_PATH.
	CURL:                "/var/dropbox-tls/curl",
	CURL_LD_LIBRARY_PATH: "/var/dropbox-tls",
	// CA bundle = the SYSTEM store. The stock rootfs ships a 2011 stub, so the
	// deployment-bundle (this connector's prerequisite) installs a current
	// ca-certificates.crt here - see deployment-bundle/install.sh "CA bundle" step.
	// No private copy: a reset/flashed device gets current CAs via that prerequisite.
	CURL_CAINFO:         "/etc/ssl/certs/ca-certificates.crt",

	// PUBLIC CLIENT (PKCE) - there is NO client_secret. The app key is not secret and
	// is the same on every device; PKCE (oauth2.js) replaces the secret. Nothing to
	// provision. Enable "Allow public clients" for this app in the Dropbox console.
	CLIENT_ID:     "2xpjb3ivnkensr9",                  // Dropbox app key (public)
	REDIRECT_URI:  "http://localhost/dropbox/oauth2callback",

	// OAuth2 (confirmed in com.dropbox.android 482.2.2)
	AUTHORIZE_URL: "https://www.dropbox.com/oauth2/authorize",
	TOKEN_URL:     "https://api.dropboxapi.com/oauth2/token",   // APK also shows api.dropbox.com/oauth2/token

	// API v2 is RPC-style: everything is POST with a JSON body.
	API_BASE:      "https://api.dropboxapi.com/2",              // /files/list_folder, /users/get_current_account
	CONTENT_BASE:  "https://content.dropboxapi.com/2",          // /files/download, /files/upload

	SCOPE:         "account_info.read files.metadata.read files.content.read files.content.write",
	ACCESS_TYPE:   "offline",                                   // -> refresh_token

	// --- _cloudcore generic wiring (consumed by ../_cloudcore) --------------------------
	SERVICE_NAME:  "com.palm.service.dropbox",
	DISPLAY_NAME:  "Dropbox",
	STATE:         "dropbox",
	ROOT_FOLDER:   "",                        // Dropbox root path (adapter treats ""/"root" as root)
	AUTHORIZE_EXTRA:  "&token_access_type=offline",
	TOKEN_SEND_SCOPE: false,
	AUTH_APP_IDS:  ["com.palm.app.cloud-auth"],
	FILE_APP_IDS:  ["com.quickoffice.webos", "com.quickoffice.ar"]
};

if (typeof exports !== "undefined") { exports.Config = Config; }
