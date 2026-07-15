/*global IMPORTS, Config, HttpCurl, require, console */
/* oauth2.js - OAuth2 Authorization Code (+ PKCE) for Yandex, mirroring the
 * Dropbox/OneDrive connectors.
 *
 * Yandex is normally a CONFIDENTIAL client: the token endpoint accepts client_secret
 * (in the body, or as HTTP Basic). We send the secret when Config.CLIENT_SECRET is
 * real (not the "PLACEHOLDER..." default). We ALSO send an S256 code_challenge, so a
 * build MAY instead run as a pure public/PKCE client: leave CLIENT_SECRET as the
 * placeholder and exchangeCode proves possession with the code_verifier alone.
 *
 * Unlike Microsoft, Yandex's token endpoint does NOT take a `scope` param (scopes are
 * fixed at authorize time / on the app), so _postToken never sends one.
 *
 * All HTTPS runs through the modern curl (HttpCurl) because device node is 0.9.8k.
 * Access tokens live ~1 year but CAN be revoked; refresh tokens are long-lived. Always
 * persist the new refresh_token returned by refresh() in case Yandex rotates it.
 */
var Foundations = IMPORTS.foundations;
var Future = Foundations.Control.Future;

// PKCE crypto for the device's node (verified on-device for the Dropbox connector):
//   - crypto.createHash('sha256') EXISTS -> used for the S256 challenge;
//   - crypto.randomBytes does NOT exist on 0.4.x -> read 32 secure bytes from
//     /dev/urandom via fs.readSync instead. Both are synchronous.
var _reqf = (typeof require !== "undefined") ? require : (IMPORTS.require || null);
var _crypto = _reqf ? _reqf("crypto") : null;
var _fs = _reqf ? _reqf("fs") : null;

function _hasSecret() {
	return Config.CLIENT_SECRET &&
		Config.CLIENT_SECRET.indexOf("PLACEHOLDER") !== 0;
}

var OAuth2 = {
	_verifier: null,   // PKCE code_verifier for the in-flight account-add

	_b64url: function (b64) {
		return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
	},

	_genVerifier: function () {
		if (!_fs) {
			throw { returnValue: false, errorCode: "NO_FS",
				detail: "fs unavailable; PKCE verifier needs /dev/urandom" };
		}
		// node 0.4.12 has no crypto.randomBytes -> 32 secure bytes from /dev/urandom.
		var fd = _fs.openSync("/dev/urandom", "r");
		var buf = new Buffer(32);
		_fs.readSync(fd, buf, 0, 32, 0);
		_fs.closeSync(fd);
		return this._b64url(buf.toString("base64"));   // 43-char base64url verifier
	},

	_challenge: function (verifier) {
		if (!_crypto) {
			throw { returnValue: false, errorCode: "NO_CRYPTO",
				detail: "crypto.createHash needed for the S256 challenge" };
		}
		return this._b64url(_crypto.createHash("sha256").update(verifier).digest("base64"));
	},

	// Build the consent URL. Generates + stores a fresh PKCE verifier as a side effect.
	// IMPORTANT: this on-demand node service is idle-killed during the (long) web login,
	// so this._verifier does NOT survive to exchangeCode - the caller MUST read it back
	// (getAuthorizeUrl_command returns it) and pass it to exchangeCode(code, verifier).
	// The in-memory copy is only a same-process fallback.
	buildAuthorizeUrl: function (state) {
		this._verifier = this._genVerifier();
		var challenge = this._challenge(this._verifier);
		return Config.AUTHORIZE_URL +
			"?response_type=code" +
			"&client_id="              + encodeURIComponent(Config.CLIENT_ID) +
			"&redirect_uri="           + encodeURIComponent(Config.REDIRECT_URI) +
			"&scope="                  + encodeURIComponent(Config.SCOPE) +
			"&code_challenge="         + encodeURIComponent(challenge) +
			"&code_challenge_method=S256" +
			"&force_confirm=yes" +
			"&state="                  + encodeURIComponent(state || "yandex");
	},

	// POST to the token endpoint via the modern curl. client_id always; client_secret
	// only for a confidential build; code_verifier proves PKCE possession.
	_postToken: function (params) {
		var self = this;
		var f = new Future();
		var form = { client_id: Config.CLIENT_ID };
		if (_hasSecret()) { form.client_secret = Config.CLIENT_SECRET; }
		Object.keys(params).forEach(function (k) { if (params[k] != null) { form[k] = params[k]; } });
		f.now(this, function () {
			return HttpCurl.request({ method: "POST", url: Config.TOKEN_URL, form: form });
		});
		f.then(this, function () {
			var r = f.result;
			if (!r || r.status !== 200) {
				// Log the exact Yandex rejection (e.g. "invalid_grant", "bad_verification_code")
				// so token failures are diagnosable from the device log.
				if (typeof console !== "undefined") {
					console.log("yandexdisk: token endpoint failed status=" + (r && r.status) +
						" body=" + (r && r.responseText));
				}
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

	// authorization code -> tokens (PKCE: send code_verifier; confidential: also secret).
	// The verifier is passed in from the caller (returned by getAuthorizeUrl and carried
	// through the auth webview) because the service process that generated it has usually
	// been idle-killed by now; this._verifier is only a same-process fallback.
	exchangeCode: function (code, verifier) {
		verifier = verifier || this._verifier;
		this._verifier = null;   // one-time use
		return this._postToken({
			grant_type:    "authorization_code",
			code:          code,
			redirect_uri:  Config.REDIRECT_URI,
			code_verifier: verifier
		});
	},

	// refresh an expired access token. Persist any new refresh_token Yandex returns.
	refresh: function (refreshToken) {
		return this._postToken({
			grant_type:    "refresh_token",
			refresh_token: refreshToken
		});
	}
};

if (typeof exports !== "undefined") { exports.OAuth2 = OAuth2; }
