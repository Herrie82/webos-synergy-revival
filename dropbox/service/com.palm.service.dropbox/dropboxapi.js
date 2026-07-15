/*global IMPORTS, Config, OAuth2, HttpCurl, console */
/* dropboxapi.js - Dropbox API v2 client. Unlike Box (RESTful GET), Dropbox is
 * RPC-style: every endpoint is POST. Metadata calls go to API_BASE with a JSON
 * body; file bytes go to CONTENT_BASE with the args in a Dropbox-API-Arg header.
 * Transparent refresh-on-401 mirrors boxapi.js. All HTTPS runs through the modern
 * curl (HttpCurl) because the device node is OpenSSL 0.9.8k.
 */
var Foundations = IMPORTS.foundations;
var Future = Foundations.Control.Future;

var DropboxApi = {
	// rpc("/files/list_folder", {path:""}, creds, cb)
	rpc: function (path, argObj, creds, onRenewed) {
		var self = this, url = Config.API_BASE + path;
		var f = new Future();
		function fire(c) {
			return HttpCurl.request({ method: "POST", url: url, bearer: c.accessToken,
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify(argObj || {}) });
		}
		f.now(this, function () { return fire(creds); });
		f.then(this, function () {
			var r = f.result;
			if (r && r.status === 401 && creds.refreshToken) {
				var rf = OAuth2.refresh(creds.refreshToken);
				rf.then(self, function () {
					var t = rf.result;
					var nc = { accessToken: t.accessToken,
						refreshToken: t.refreshToken || creds.refreshToken,   // Dropbox may omit -> keep old
						expiresAt: Date.now() + (t.expiresIn * 1000) };
					if (onRenewed) { onRenewed(nc); }
					var retry = fire(nc);
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
			throw { returnValue: false, errorCode: "DROPBOX_API_ERROR",
				status: r && r.status, body: r && r.responseText };
		}
		return r.responseText ? JSON.parse(r.responseText) : {};
	},

	getAccountInfo: function (creds, cb) {           // POST /users/get_current_account  (body: null)
		return this.rpc("/users/get_current_account", null, creds, cb);
	},
	listFolder: function (creds, path, cb) {         // POST /files/list_folder  (root = "")
		return this.rpc("/files/list_folder", { path: path || "" }, creds, cb);
	},
	// POST /files/get_temporary_link -> { metadata, link }. `link` is a pre-signed,
	// no-auth https URL good for ~4h; a plain curl GET can fetch it (used by the Photos
	// provider so the aggregator's downloader needs no Dropbox token/headers).
	getTemporaryLink: function (creds, path, cb) {
		return this.rpc("/files/get_temporary_link", { path: path }, creds, cb);
	},

	// Content endpoints (content.dropboxapi.com): the API args ride in a Dropbox-API-Arg
	// HEADER, and the HTTP body is the file bytes. Same transparent refresh-on-401 as rpc().
	//   upload:   request body  = local file (opts.dataFile)   -> JSON metadata in response body
	//   download: response body = local file (opts.outFile)    -> file written to disk
	content: function (path, apiArg, opts, creds, onRenewed) {
		var self = this, url = Config.CONTENT_BASE + path;
		var f = new Future();
		function fire(c) {
			var headers = { "Dropbox-API-Arg": JSON.stringify(apiArg) };
			if (opts.dataFile) { headers["Content-Type"] = "application/octet-stream"; }
			return HttpCurl.request({ method: "POST", url: url, bearer: c.accessToken,
				headers: headers, dataFile: opts.dataFile, outFile: opts.outFile });
		}
		f.now(this, function () { return fire(creds); });
		f.then(this, function () {
			var r = f.result;
			if (r && r.status === 401 && creds.refreshToken) {
				var rf = OAuth2.refresh(creds.refreshToken);
				rf.then(self, function () {
					var t = rf.result;
					var nc = { accessToken: t.accessToken,
						refreshToken: t.refreshToken || creds.refreshToken,
						expiresAt: Date.now() + (t.expiresIn * 1000) };
					if (onRenewed) { onRenewed(nc); }
					var retry = fire(nc);
					retry.then(self, function () { f.result = self._parseContent(retry.result, opts); });
				});
				return;
			}
			f.result = self._parseContent(r, opts);
		});
		return f;
	},

	_parseContent: function (r, opts) {
		if (!r || r.status < 200 || r.status >= 300) {
			throw { returnValue: false, errorCode: "DROPBOX_API_ERROR",
				status: r && r.status, body: r && r.responseText };
		}
		if (opts.outFile) { return { path: opts.outFile }; }        // download: bytes on disk
		return r.responseText ? JSON.parse(r.responseText) : {};    // upload: JSON metadata
	},

	uploadFile: function (creds, dropboxPath, localPath, cb) {      // POST /files/upload
		return this.content("/files/upload",
			{ path: dropboxPath, mode: "overwrite", autorename: false, mute: false },
			{ dataFile: localPath }, creds, cb);
	},
	downloadFile: function (creds, dropboxPath, localDest, cb) {    // POST /files/download
		return this.content("/files/download",
			{ path: dropboxPath },
			{ outFile: localDest }, creds, cb);
	}
};

if (typeof exports !== "undefined") { exports.DropboxApi = DropboxApi; }
