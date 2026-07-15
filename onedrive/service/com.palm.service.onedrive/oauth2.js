/*global IMPORTS, Config, HttpCurl, require, console */
/* oauth2.js - OAuth2 Authorization Code + PKCE for OneDrive (Microsoft identity
 * platform v2.0), mirroring the Box/Dropbox connectors.
 *
 * PUBLIC CLIENT via PKCE (RFC 7636): buildAuthorizeUrl() makes a random code_verifier
 * and sends its S256 challenge; exchangeCode() proves possession with the verifier.
 * Microsoft public clients redeem the code WITHOUT a secret, so nothing secret ships
 * (the _hasSecret() path stays only for symmetry with Box; the placeholder disables it).
 *
 * Microsoft requires `scope` on BOTH the code exchange and the refresh (to re-grant the
 * same scopes), so _postToken always includes it - unlike Box.
 *
 * All HTTPS runs through the modern curl (HttpCurl) because device node is 0.9.8k.
 * Access tokens live ~60-90 min; refresh tokens ROTATE on every use (90-day sliding
 * window) - the caller MUST persist the NEW refresh_token returned by refresh().
 */
var Foundations = IMPORTS.foundations;
var Future = Foundations.Control.Future;

var _reqf = (typeof require !== "undefined") ? require : (IMPORTS.require || null);
var _crypto = _reqf ? _reqf("crypto") : null;
var _fs = _reqf ? _reqf("fs") : null;

function _hasSecret() {
	return Config.CLIENT_SECRET &&
		Config.CLIENT_SECRET.indexOf("PLACEHOLDER") !== 0;
}

var OAuth2 = {
	_verifier: null,

	_b64url: function (b64) {
		return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
	},
	_genVerifier: function () {
		if (!_fs) { throw { returnValue: false, errorCode: "NO_FS",
			detail: "fs unavailable; PKCE verifier needs /dev/urandom" }; }
		var fd = _fs.openSync("/dev/urandom", "r");
		var buf = new Buffer(32);
		_fs.readSync(fd, buf, 0, 32, 0);
		_fs.closeSync(fd);
		return this._b64url(buf.toString("base64"));
	},
	_challenge: function (verifier) {
		if (!_crypto) { throw { returnValue: false, errorCode: "NO_CRYPTO",
			detail: "crypto.createHash needed for the S256 challenge" }; }
		return this._b64url(_crypto.createHash("sha256").update(verifier).digest("base64"));
	},

	// Build the consent URL; generates + stores a fresh PKCE verifier as a side effect.
	// The on-demand service is idle-killed during the web login, so the caller reads the
	// verifier back (getAuthorizeUrl_command returns it) and passes it to exchangeCode.
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
			"&state="                  + encodeURIComponent(state || "onedrive");
	},

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
				if (typeof console !== "undefined") {
					console.log("onedrive: token endpoint failed status=" + (r && r.status) +
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

	exchangeCode: function (code, verifier) {
		verifier = verifier || this._verifier;
		this._verifier = null;
		return this._postToken({
			grant_type:    "authorization_code",
			code:          code,
			redirect_uri:  Config.REDIRECT_URI,
			code_verifier: verifier,
			scope:         Config.SCOPE
		});
	},

	// Microsoft rotates the refresh token on every use - persist the new one.
	refresh: function (refreshToken) {
		return this._postToken({
			grant_type:    "refresh_token",
			refresh_token: refreshToken,
			scope:         Config.SCOPE
		});
	}
};

if (typeof exports !== "undefined") { exports.OAuth2 = OAuth2; }
