/*global IMPORTS, Config, OAuth2, HttpCurl, console */
/* yandexapi.js - Yandex Disk REST client. Yandex Disk is PATH-based (like Dropbox):
 * a resource is addressed by "disk:/Folder/file.docx", so the locator handed to
 * consumers IS a real path and rerouting maps cleanly.
 *
 * Every Disk/identity request sends "Authorization: OAuth <access_token>" (NOT the
 * Bearer scheme), so we pass it via the headers map rather than HttpCurl's `bearer`.
 * Transparent refresh-on-401 mirrors dropboxapi.js/graphapi.js. All HTTPS runs through
 * the modern curl (HttpCurl) because the device node is OpenSSL 0.9.8k.
 *
 * download/upload are TWO-STEP: the Disk API returns a short-lived signed href
 * (/resources/download -> GET href; /resources/upload -> PUT href) which is fetched
 * with a second, UNAUTHENTICATED curl (the href needs no OAuth token).
 */
var Foundations = IMPORTS.foundations;
var Future = Foundations.Control.Future;

var YandexApi = {
	// "Authorization: OAuth <token>" header for a credentials object.
	_hdr: function (c) { return { "Authorization": "OAuth " + c.accessToken }; },

	// Normalise a folder/file locator to the Disk namespace. "", "/", "disk:/" -> root;
	// a bare "/Foo/bar" -> "disk:/Foo/bar"; an already-qualified "disk:/..", "app:/..",
	// "trash:/.." is passed through unchanged (that is what listFolder hands back).
	_normPath: function (p) {
		if (!p || p === "/" || p === Config.ROOT_PATH) { return Config.ROOT_PATH; }
		if (p.indexOf("disk:/") === 0 || p.indexOf("app:/") === 0 || p.indexOf("trash:/") === 0) {
			return p;
		}
		return "disk:/" + p.replace(/^\/+/, "");
	},

	// Join a folder locator + a filename into a destination path (for uploads).
	_join: function (folder, name) {
		var base = this._normPath(folder);
		if (base.charAt(base.length - 1) !== "/") { base += "/"; }
		return base + name.replace(/^\/+/, "");
	},

	// Authenticated request to the Disk/identity API with transparent refresh-on-401.
	// Resolves to the raw HttpCurl result { status, responseText }.
	_req: function (base, creds, onRenewed) {
		var self = this, f = new Future();
		function fire(c) {
			var o = { method: base.method || "GET", url: base.url, headers: self._hdr(c) };
			if (base.headers) {
				Object.keys(base.headers).forEach(function (k) { o.headers[k] = base.headers[k]; });
			}
			return HttpCurl.request(o);
		}
		f.now(this, function () { return fire(creds); });
		f.then(this, function () {
			var r = f.result;
			if (r && r.status === 401 && creds.refreshToken) {
				var rf = OAuth2.refresh(creds.refreshToken);
				rf.then(self, function () {
					var t = rf.result;
					var nc = { accessToken: t.accessToken,
						refreshToken: t.refreshToken || creds.refreshToken,   // persist rotated token
						expiresAt: Date.now() + (t.expiresIn * 1000) };
					if (onRenewed) { onRenewed(nc); }
					var retry = fire(nc);
					retry.then(self, function () { f.result = retry.result; });
				});
				return;
			}
			f.result = r;
		});
		return f;
	},

	_parse: function (r) {
		if (!r || r.status < 200 || r.status >= 300) {
			throw { returnValue: false, errorCode: "YANDEX_API_ERROR",
				status: r && r.status, body: r && r.responseText };
		}
		return r.responseText ? JSON.parse(r.responseText) : {};
	},

	// GET https://login.yandex.ru/info -> { login, default_email, real_name, display_name }.
	// Used by exchangeCode to fill the required account `username`.
	getUserInfo: function (creds, cb) {
		var self = this, f = new Future();
		var call = this._req({ method: "GET", url: Config.LOGIN_INFO_URL }, creds, cb);
		call.then(this, function () { f.result = self._parse(call.result); });
		return f;
	},

	// GET /resources?path=..&limit=.. -> Resource with _embedded.items[]. path root = disk:/.
	listFolder: function (creds, path, cb) {
		var self = this, f = new Future();
		var p = this._normPath(path);
		var url = Config.API_BASE + "/resources?path=" + encodeURIComponent(p) +
			"&limit=" + Config.LIST_LIMIT;
		var call = this._req({ method: "GET", url: url }, creds, cb);
		call.then(this, function () { f.result = self._parse(call.result); });
		return f;
	},

	// Two-step download: GET /resources/download?path=.. -> { href, method } ; then GET
	// the signed href to disk (no auth header - the href is self-authenticating).
	downloadFile: function (creds, path, localDest, cb) {
		var self = this, f = new Future();
		var p = this._normPath(path);
		var url = Config.API_BASE + "/resources/download?path=" + encodeURIComponent(p);
		var call = this._req({ method: "GET", url: url }, creds, cb);
		f.now(this, function () { return call; });
		f.then(this, function () {
			var link = self._parse(call.result);
			if (!link.href) {
				throw { returnValue: false, errorCode: "YANDEX_NO_DOWNLOAD_HREF",
					body: call.result && call.result.responseText };
			}
			var dl = HttpCurl.request({ method: link.method || "GET", url: link.href,
				follow: true, outFile: localDest });
			dl.then(self, function () {
				var r = dl.result;
				if (!r || r.status < 200 || r.status >= 300) {
					throw { returnValue: false, errorCode: "YANDEX_DOWNLOAD_FAILED",
						status: r && r.status, body: r && r.responseText };
				}
				f.result = { path: localDest };
			});
		});
		return f;
	},

	// Two-step upload: GET /resources/upload?path=..&overwrite=.. -> { href, method:PUT } ;
	// then PUT the local file bytes to the signed href (no auth header needed).
	// overwrite=true REPLACES an existing file at the same path (see uploadReplace).
	uploadFile: function (creds, destPath, localPath, overwrite, cb) {
		var self = this, f = new Future();
		var p = this._normPath(destPath);
		var ow = (overwrite === false) ? "false" : "true";
		var url = Config.API_BASE + "/resources/upload?path=" + encodeURIComponent(p) +
			"&overwrite=" + ow;
		var call = this._req({ method: "GET", url: url }, creds, cb);
		f.now(this, function () { return call; });
		f.then(this, function () {
			var link = self._parse(call.result);
			if (!link.href) {
				throw { returnValue: false, errorCode: "YANDEX_NO_UPLOAD_HREF",
					body: call.result && call.result.responseText };
			}
			var up = HttpCurl.request({ method: link.method || "PUT", url: link.href,
				follow: true, dataFile: localPath });
			up.then(self, function () {
				var r = up.result;
				if (!r || r.status < 200 || r.status >= 300) {
					throw { returnValue: false, errorCode: "YANDEX_UPLOAD_FAILED",
						status: r && r.status, body: r && r.responseText };
				}
				f.result = { path: p, name: p.split("/").pop() };
			});
		});
		return f;
	},

	// Overwrite the file at destPath (QuickOffice save-back). Path-based, so a replace is
	// just an upload with overwrite=true to the same locator.
	uploadReplace: function (creds, destPath, localPath, cb) {
		return this.uploadFile(creds, destPath, localPath, true, cb);
	}
};

if (typeof exports !== "undefined") { exports.YandexApi = YandexApi; }
