/*global IMPORTS, Config, OAuth2, HttpCurl, console */
/* boxapi.js - Box API v2 client. Unlike Dropbox (RPC/POST/paths), Box is RESTful and
 * ID-addressed: GET /folders/{id}/items, GET /files/{id}/content, root folder id "0".
 * Transparent refresh-on-401 mirrors dropboxapi.js. All HTTPS runs through the modern
 * curl (HttpCurl) because the device node is OpenSSL 0.9.8k.
 */
var Foundations = IMPORTS.foundations;
var Future = Foundations.Control.Future;

var BoxApi = {
	// GET a JSON endpoint with Bearer + transparent refresh-on-401.
	//   get("/folders/0/items?fields=...", creds, cb)
	get: function (path, creds, onRenewed) {
		return this._req({ method: "GET", url: Config.API_BASE + path }, creds, onRenewed, false);
	},

	// Core request with refresh-on-401. `toFile` opts (follow/outFile) stream to disk.
	_req: function (base, creds, onRenewed, toFile) {
		var self = this, f = new Future();
		function fire(c) {
			var o = { method: base.method, url: base.url, bearer: c.accessToken };
			if (base.headers)  { o.headers = base.headers; }
			if (base.multipart){ o.multipart = base.multipart; }
			if (toFile)        { o.follow = true; o.outFile = base.outFile; }
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
						refreshToken: t.refreshToken || creds.refreshToken,   // Box rotates -> keep new
						expiresAt: Date.now() + (t.expiresIn * 1000) };
					if (onRenewed) { onRenewed(nc); }
					var retry = fire(nc);
					retry.then(self, function () { f.result = self._parse(retry.result, toFile, base); });
				});
				return;
			}
			f.result = self._parse(r, toFile, base);
		});
		return f;
	},

	_parse: function (r, toFile, base) {
		if (!r || r.status < 200 || r.status >= 300) {
			throw { returnValue: false, errorCode: "BOX_API_ERROR",
				status: r && r.status, body: r && r.responseText };
		}
		if (toFile) { return { path: base.outFile }; }
		return r.responseText ? JSON.parse(r.responseText) : {};
	},

	getAccountInfo: function (creds, cb) {            // GET /users/me
		return this.get("/users/me?fields=id,name,login", creds, cb);
	},

	// GET /folders/{id}/items -> { entries:[{type,id,name,size,modified_at}], total_count }
	listFolder: function (creds, folderId, cb) {
		var id = folderId || Config.ROOT_FOLDER;
		return this.get("/folders/" + encodeURIComponent(id) +
			"/items?limit=1000&fields=id,type,name,size,modified_at", creds, cb);
	},

	// GET /files/{id}/content -> 302 to dl.boxcloud.com (curl -L follows) -> bytes to disk.
	downloadFile: function (creds, fileId, localDest, cb) {
		return this._req({ method: "GET",
			url: Config.API_BASE + "/files/" + encodeURIComponent(fileId) + "/content",
			outFile: localDest }, creds, cb, true);
	},

	// POST upload.box.com/api/2.0/files/content (multipart: attributes JSON + file bytes).
	// Creates a NEW file; Box 409s if a file of that name already exists in the folder - use
	// uploadNewVersion() to overwrite an existing file (e.g. QuickOffice save-back).
	uploadFile: function (creds, folderId, localPath, name, cb) {
		var attrs = JSON.stringify({ name: name, parent: { id: folderId || Config.ROOT_FOLDER } });
		return this._req({ method: "POST", url: Config.UPLOAD_BASE + "/files/content",
			multipart: [ { name: "attributes", value: attrs }, { name: "file", file: localPath } ]
		}, creds, cb, false);
	},

	// POST upload.box.com/api/2.0/files/{fileId}/content - upload a NEW VERSION of an existing
	// file (Box's overwrite). Same response shape as uploadFile ({ entries:[fileObj] }).
	uploadNewVersion: function (creds, fileId, localPath, cb) {
		return this._req({ method: "POST",
			url: Config.UPLOAD_BASE + "/files/" + encodeURIComponent(fileId) + "/content",
			multipart: [ { name: "file", file: localPath } ]
		}, creds, cb, false);
	},

	// Photos: a token-in-query content URL the aggregator's curl can fetch with no header.
	// Box accepts ?access_token= on the /content endpoint (302 -> dl.boxcloud.com). The
	// token is short-lived, but the aggregator downloads immediately after listPhotos.
	contentUrl: function (creds, fileId) {
		return Config.API_BASE + "/files/" + encodeURIComponent(fileId) +
			"/content?access_token=" + encodeURIComponent(creds.accessToken);
	}
};

if (typeof exports !== "undefined") { exports.BoxApi = BoxApi; }
