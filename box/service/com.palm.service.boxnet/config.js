/* config.js - Box (box.com) OAuth2 + REST v2 endpoints for the modern connector.
 *
 * SCAFFOLD: the three CLIENT_* values below are placeholders. To go live you must
 * register a free Box app at https://app.box.com/developers/console (type:
 * "Custom App" -> "User Authentication (OAuth 2.0)"), then paste its values here
 * (or, better, wrap CLIENT_SECRET with com.palm.keymanager like the stock services
 * did with api_key, and load it at runtime - see oauth2.js:getClientSecret()).
 *
 * REDIRECT_URI must be added verbatim to the app's "OAuth 2.0 Redirect URIs" list.
 * On-device we intercept it in the auth webview (see accounts/com.palm.boxnet.json).
 */
var Config = {
	CLIENT_ID:     "PLACEHOLDER_BOX_CLIENT_ID",       // TODO: from Box dev console
	CLIENT_SECRET: "PLACEHOLDER_BOX_CLIENT_SECRET",   // TODO: prefer keymanager-wrapped
	REDIRECT_URI:  "https://webos.local/boxnet/oauth2callback",

	// OAuth2 (confirmed present in com.box.android 7.1.515)
	AUTHORIZE_URL: "https://account.box.com/api/oauth2/authorize",
	TOKEN_URL:     "https://api.box.com/oauth2/token",
	REVOKE_URL:    "https://api.box.com/oauth2/revoke",

	// REST v2 (confirmed: api.box.com/2.0/files/, folders, users/me)
	API_BASE:      "https://api.box.com/2.0",
	UPLOAD_BASE:   "https://upload.box.com/api/2.0",

	// "root" scope grants full read/write to the user's own content.
	SCOPE:         "root_readwrite"
};

if (typeof exports !== "undefined") { exports.Config = Config; }
