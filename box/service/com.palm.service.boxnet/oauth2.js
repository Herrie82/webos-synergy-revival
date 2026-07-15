/*global IMPORTS, Config, require, console */
/* oauth2.js - shared OAuth2 helpers for the Box connector.
 *
 * Flow (Authorization Code grant, the same one com.box.android uses):
 *   1. account UI opens AUTHORIZE_URL?response_type=code&client_id&redirect_uri&state
 *   2. user logs in + consents in the webview; Box redirects to REDIRECT_URI?code=...
 *   3. the webview intercepts that redirect and hands `code` to exchangeCode
 *   4. exchangeCode POSTs to TOKEN_URL -> { access_token, refresh_token, expires_in }
 *   5. tokens are returned to com.palm.service.accounts as the account credentials
 *   6. every API call uses access_token; on 401 we refresh() and retry once.
 *
 * Box access tokens live ~60 min; refresh tokens ~60 days and ROTATE on every use,
 * so callers MUST persist the new refresh_token returned by refresh().
 */
var Foundations = IMPORTS.foundations;
var Future = Foundations.Control.Future;
var AjaxCall = Foundations.Comms.AjaxCall;

var OAuth2 = {
	// Build the consent URL the account webview should load first.
	buildAuthorizeUrl: function (state) {
		return Config.AUTHORIZE_URL +
			"?response_type=code" +
			"&client_id="    + encodeURIComponent(Config.CLIENT_ID) +
			"&redirect_uri=" + encodeURIComponent(Config.REDIRECT_URI) +
			"&scope="        + encodeURIComponent(Config.SCOPE) +
			"&state="        + encodeURIComponent(state || "boxnet");
	},

	// If CLIENT_SECRET is keymanager-wrapped, resolve it here. Scaffold returns the
	// plaintext placeholder from config so the flow is testable end to end.
	getClientSecret: function () {
		var f = new Future();
		f.result = Config.CLIENT_SECRET;   // TODO: swap for keymanager/fetchKey
		return f;
	},

	_postToken: function (params) {
		var self = this;
		var f = new Future();
		f.nest(this.getClientSecret());
		f.then(this, function () {
			var secret = f.result;
			var body =
				"client_id="     + encodeURIComponent(Config.CLIENT_ID) +
				"&client_secret=" + encodeURIComponent(secret);
			Object.keys(params).forEach(function (k) {
				body += "&" + k + "=" + encodeURIComponent(params[k]);
			});
			return AjaxCall.post(Config.TOKEN_URL, body, {
				headers: { "Content-Type": "application/x-www-form-urlencoded" }
			});
		});
		f.then(this, function () {
			var r = f.result;
			if (!r || r.status !== 200) {
				f.setException({ returnValue: false, errorCode: "OAUTH_TOKEN_FAILED",
					status: r && r.status, body: r && r.responseText });
				return;
			}
			var t = JSON.parse(r.responseText);
			f.result = {
				returnValue:  true,
				accessToken:  t.access_token,
				refreshToken: t.refresh_token,
				expiresIn:    t.expires_in,
				tokenType:    t.token_type
			};
		});
		return f;
	},

	// Step 4: authorization code -> tokens.
	exchangeCode: function (code) {
		return this._postToken({
			grant_type:   "authorization_code",
			code:         code,
			redirect_uri: Config.REDIRECT_URI
		});
	},

	// Step 6: refresh an expired access token. Returns a NEW refresh token too.
	refresh: function (refreshToken) {
		return this._postToken({
			grant_type:    "refresh_token",
			refresh_token: refreshToken
		});
	}
};

if (typeof exports !== "undefined") { exports.OAuth2 = OAuth2; }
