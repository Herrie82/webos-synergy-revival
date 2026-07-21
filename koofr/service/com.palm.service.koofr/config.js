/* config.js - Koofr REST v2 endpoints for the modern connector.
 *
 * Koofr uses HTTP BASIC auth with an APP PASSWORD (not OAuth): the account owner generates an app
 * password at https://app.koofr.net/app/admin/preferences/password and signs in with their email
 * + that password. So - like the Mega/S3 connectors - Koofr has its OWN credentials form
 * (com.palm.app.koofr-auth) and a `login` command; there is nothing to register centrally.
 * (Koofr does have OAuth2, but third-party client registration is support-gated, so the
 * self-service app-password path is the pragmatic one, and it is what rclone's Koofr backend uses.)
 *
 * Koofr is MOUNT + PATH based: files live under a mount (the user's primary personal storage),
 * addressed by (mountId, absolute path). The connector resolves the primary mount at login and
 * stores its id in the credentials. Every request sends "Authorization: Basic <email:apppw>" and
 * shells through the modern curl (device node is 0.9.8k).
 */
var Config = {
	CURL:                 "/var/dropbox-tls/curl",
	CURL_LD_LIBRARY_PATH: "/var/dropbox-tls",
	CURL_CAINFO:          "/etc/ssl/certs/ca-certificates.crt",

	// Same host for API and content - only the path prefix differs.
	API_BASE:     "https://app.koofr.net/api/v2",
	CONTENT_BASE: "https://app.koofr.net/content/api/v2",
	KOOFR_VERSION: "2.1",   // sent as X-Koofr-Version on every request

	ROOT_FOLDER: "/",   // mount root; the sentinel "root"/"" also maps here

	PHOTO_ALBUM_NAME: "Camera Uploads",   // one folder surfaced as one album

	// --- _cloudcore generic wiring (consumed by ../_cloudcore) --------------------------
	SERVICE_NAME:  "com.palm.service.koofr",
	DISPLAY_NAME:  "Koofr",
	STATE:         "koofr",
	AUTH_APP_IDS:  ["com.palm.app.koofr-auth"],
	FILE_APP_IDS:  ["com.palm.app.koofr-files", "com.quickoffice.webos", "com.quickoffice.ar"]
};

if (typeof exports !== "undefined") { exports.Config = Config; }
