/*global IMPORTS, Config, OAuth2, console */
/* boxapi.js - authenticated Box REST v2 client with transparent token refresh.
 *
 * Credentials come from the account DB (com.palm.service.accounts) in the shape
 * this connector stores them at auth time:
 *   creds = { accessToken, refreshToken, expiresAt }
 * On a 401 we refresh() once, persist the rotated tokens via the supplied
 * `onTokensRenewed` callback, and retry the original request.
 */
var Foundations = IMPORTS.foundations;
var Future = Foundations.Control.Future;
var AjaxCall = Foundations.Comms.AjaxCall;

var BoxApi = {
	_authHeader: function (creds) { return { "Authorization": "Bearer " + creds.accessToken }; },

	// method: "GET"|"POST", path: "/folders/0/items", creds, opts:{query,body,onTokensRenewed}
	request: function (method, path, creds, opts) {
		opts = opts || {};
		var self = this;
		var url = Config.API_BASE + path + (opts.query ? "?" + opts.query : "");
		var f = new Future();

		function fire(c) {
			var headers = self._authHeader(c);
			if (opts.body) { headers["Content-Type"] = "application/json"; }
			return (method === "POST")
				? AjaxCall.post(url, opts.body ? JSON.stringify(opts.body) : "", { headers: headers })
				: AjaxCall.get(url, null, { headers: headers });
		}

		f.now(this, function () { return fire(creds); });
		f.then(this, function () {
			var r = f.result;
			if (r && r.status === 401 && creds.refreshToken) {
				// token expired -> refresh + retry once
				var rf = OAuth2.refresh(creds.refreshToken);
				rf.then(self, function () {
					var t = rf.result;
					var newCreds = { accessToken: t.accessToken, refreshToken: t.refreshToken,
						expiresAt: Date.now() + (t.expiresIn * 1000) };
					if (opts.onTokensRenewed) { opts.onTokensRenewed(newCreds); }
					var retry = fire(newCreds);
					retry.then(self, function () { f.result = self._parse(retry.result); });
				});
				return;
			}
			f.result = self._parse(r);
		});
		return f;
	},

	_parse: function (r) {
		if (!r || r.status < 200 || r.status >= 300) {
			throw { returnValue: false, errorCode: "BOX_API_ERROR",
				status: r && r.status, body: r && r.responseText };
		}
		return r.responseText ? JSON.parse(r.responseText) : {};
	},

	// Convenience wrappers used by the command assistants -----------------------
	getAccountInfo: function (creds, cb) {           // GET /users/me
		return this.request("GET", "/users/me", creds, cb);
	},
	listFolder: function (creds, folderId, cb) {     // GET /folders/{id}/items
		return this.request("GET", "/folders/" + (folderId || "0") + "/items", creds,
			{ query: "fields=id,type,name,size,modified_at", onTokensRenewed: cb });
	}
};

if (typeof exports !== "undefined") { exports.BoxApi = BoxApi; }
