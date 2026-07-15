/*global IMPORTS, Config, HttpCurl, require, console */
/* oauth2.js - OAuth2 Authorization Code + PKCE (public client) for Dropbox.
 *
 * PUBLIC CLIENT - NO client_secret. This connector ships to many devices, and a
 * confidential secret embedded in a distributed package is trivially extractable
 * (and revocable for everyone at once). PKCE (RFC 7636) replaces the secret:
 *   - buildAuthorizeUrl() makes a random code_verifier, sends its S256
 *     code_challenge in the authorize request, and remembers the verifier;
 *   - exchangeCode() proves possession by sending the code_verifier (not a
 *     secret) when redeeming the code.
 * So there is nothing secret to provision or protect - the same package ships to
 * every device. Enable "Allow public clients" for the app in the Dropbox console.
 *
 * All HTTPS runs through the modern curl (HttpCurl) because device node is 0.9.8k.
 * Tokens: access ~4 h; refresh long-lived, usually non-rotating (keep the old one).
 */
var Foundations = IMPORTS.foundations;
var Future = Foundations.Control.Future;

// PKCE crypto for the device's node v0.4.12 (verified on-device):
//   - crypto.createHash('sha256') EXISTS -> used for the S256 challenge;
//   - crypto.randomBytes does NOT exist on 0.4.x -> read 32 secure bytes from
//     /dev/urandom via fs.readSync instead. Both are synchronous.
var _reqf = (typeof require !== "undefined") ? require : (IMPORTS.require || null);
var _crypto = _reqf ? _reqf("crypto") : null;
var _fs = _reqf ? _reqf("fs") : null;

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
			"&token_access_type="      + encodeURIComponent(Config.ACCESS_TYPE) +
			"&code_challenge="         + encodeURIComponent(challenge) +
			"&code_challenge_method=S256" +
			"&state="                  + encodeURIComponent(state || "dropbox");
	},

	// POST to the token endpoint via the modern curl. Public client: client_id, no secret.
	_postToken: function (params) {
		var self = this;
		var f = new Future();
		var form = { client_id: Config.CLIENT_ID };
		Object.keys(params).forEach(function (k) { if (params[k] != null) { form[k] = params[k]; } });
		f.now(this, function () {
			return HttpCurl.request({ method: "POST", url: Config.TOKEN_URL, form: form });
		});
		f.then(this, function () {
			var r = f.result;
			if (!r || r.status !== 200) {
				// Log the exact Dropbox rejection (e.g. "code_verifier required",
				// "invalid_grant") so token failures are diagnosable from the device log.
				if (typeof console !== "undefined") {
					console.log("dropbox: token endpoint failed status=" + (r && r.status) +
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

	// Step 4: authorization code -> tokens (PKCE: send code_verifier, not a secret).
	// The verifier is passed in from the caller (it was returned by getAuthorizeUrl and
	// carried through the auth webview) because the service process that generated it has
	// usually been idle-killed by now; this._verifier is only a same-process fallback.
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

	// Step 6: refresh an expired access token (public client: client_id + refresh_token).
	refresh: function (refreshToken) {
		return this._postToken({
			grant_type:    "refresh_token",
			refresh_token: refreshToken
		});
	}
};

if (typeof exports !== "undefined") { exports.OAuth2 = OAuth2; }
