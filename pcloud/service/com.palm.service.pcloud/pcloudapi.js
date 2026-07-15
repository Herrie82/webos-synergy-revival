/*global IMPORTS, Config, HttpCurl, console */
/* pcloudapi.js - pCloud REST client. Like Box/OneDrive it is RESTful and numeric-ID
 * addressed:
 *   - folder listing:  GET  /listfolder?folderid={id}       (root = folderid 0)
 *   - file download:   GET  /getfilelink?fileid={id} -> {hosts,path}; fetch host+path
 *   - upload:          POST /uploadfile?folderid={id}&filename={name}  (multipart body)
 *   - file metadata:   GET  /checksumfile?fileid={id} -> {metadata:{name,parentfolderid}}
 *   - account:         GET  /userinfo                       (email for the account name)
 *
 * TWO pCloud specifics baked in here:
 *   1. REGION HOST. Every call goes to the account's data-region host - api.pcloud.com (US)
 *      or eapi.pcloud.com (EU) - carried in creds.apiHost. _base() resolves it per call.
 *   2. RESULT ENVELOPE. pCloud returns HTTP 200 even on logical errors, flagged by a nonzero
 *      top-level `result` (0 = success). _parse() turns a nonzero result into an exception.
 *
 * There is NO transparent refresh-on-401 (unlike boxapi/graphapi): pCloud tokens are
 * long-lived and have no refresh flow, so the `cb`/onRenewed argument is accepted only for
 * call-site symmetry with the other connectors and is never invoked. All HTTPS runs through
 * the modern curl because the device node is OpenSSL 0.9.8k.
 */
var Foundations = IMPORTS.foundations;
var Future = Foundations.Control.Future;

var PcloudApi = {
	// Resolve the account's region API host (defaults to the US host).
	_host: function (creds) {
		return (creds && creds.apiHost) || Config.DEFAULT_API_HOST;
	},

	// Build a full method URL on the region host with the access_token + params as query.
	_url: function (creds, method, params) {
		var qs = ["access_token=" + encodeURIComponent(creds.accessToken)];
		if (params) {
			Object.keys(params).forEach(function (k) {
				if (params[k] != null) {
					qs.push(encodeURIComponent(k) + "=" + encodeURIComponent(params[k]));
				}
			});
		}
		return "https://" + this._host(creds) + "/" + method + "?" + qs.join("&");
	},

	// GET a pCloud JSON method with the access_token in the query string.
	_get: function (creds, method, params) {
		var self = this, f = new Future();
		f.now(this, function () {
			return HttpCurl.request({ method: "GET", url: self._url(creds, method, params) });
		});
		f.then(this, function () { f.result = self._parse(f.result); });
		return f;
	},

	// Validate transport status + pCloud's `result` envelope; return the parsed JSON.
	_parse: function (r) {
		if (!r || r.status < 200 || r.status >= 300) {
			throw { returnValue: false, errorCode: "PCLOUD_HTTP_ERROR",
				status: r && r.status, body: r && r.responseText };
		}
		var j = r.responseText ? JSON.parse(r.responseText) : {};
		if (j.result && j.result !== 0) {
			throw { returnValue: false, errorCode: "PCLOUD_API_ERROR",
				result: j.result, error: j.error };
		}
		return j;
	},

	// GET /userinfo -> { email, userid, ... } (the account display name / username).
	getAccountInfo: function (creds, cb) {
		return this._get(creds, "userinfo", null);
	},

	// GET /listfolder?folderid={id} -> raw pCloud { metadata:{ contents:[ item ] } }.
	// folderId falsy/"" -> root (folderid 0). Each item has name, isfolder(bool),
	// folderid|fileid, size, modified, contenttype.
	listFolder: function (creds, folderId, cb) {
		var id = (folderId == null || folderId === "") ? Config.ROOT_FOLDER : folderId;
		return this._get(creds, "listfolder", { folderid: id });
	},

	// GET /getfilelink?fileid={id} -> { hosts:[...], path }; then fetch https://<host><path>
	// to localDest via curl (the path carries an auth hash, so no token/header needed).
	downloadFile: function (creds, fileId, localDest, cb) {
		var self = this, f = new Future();
		var link = this._get(creds, "getfilelink", { fileid: fileId });
		f.now(this, function () { return link; });
		f.then(this, function () {
			var d;
			try { d = link.result; }
			catch (e) { f.setException(e); return; }
			var hosts = d && d.hosts;
			if (!hosts || !hosts.length || !d.path) {
				f.setException({ returnValue: false, errorCode: "PCLOUD_NO_LINK", detail: d });
				return;
			}
			var url = "https://" + hosts[0] + d.path;
			var dl = HttpCurl.request({ method: "GET", url: url, follow: true, outFile: localDest });
			dl.then(self, function () {
				var r = dl.result;
				if (!r || r.status < 200 || r.status >= 300) {
					f.setException({ returnValue: false, errorCode: "PCLOUD_DOWNLOAD_FAILED",
						status: r && r.status });
					return;
				}
				f.result = { path: localDest };
			});
		});
		return f;
	},

	// GET /getfilelink?fileid={id} -> resolve a temporary content URL as a STRING (no
	// download). Used by the Photos provider (listPhotos): the stock aggregator's curl fetches
	// this URL to local storage. The link is short-lived and its path carries an auth hash, so
	// no token/header is needed on the fetch.
	getFileLink: function (creds, fileId, cb) {
		var self = this, f = new Future();
		var link = this._get(creds, "getfilelink", { fileid: fileId });
		f.now(this, function () { return link; });
		f.then(this, function () {
			var d;
			try { d = link.result; }
			catch (e) { f.setException(e); return; }
			var hosts = d && d.hosts;
			if (!hosts || !hosts.length || !d.path) {
				f.setException({ returnValue: false, errorCode: "PCLOUD_NO_LINK", detail: d });
				return;
			}
			f.result = { url: "https://" + hosts[0] + d.path };
		});
		return f;
	},

	// POST /uploadfile?folderid={id}&filename={name}&nopartial=1 with the bytes as a
	// multipart file part. parentId falsy/"" -> root. pCloud OVERWRITES a same-named file
	// in the target folder when renameifexists is not set (the old copy is kept as a
	// revision), so a plain upload is create-or-overwrite - matching the OneDrive PUT.
	// Returns raw pCloud { fileids:[...], metadata:[ item ] }.
	uploadFile: function (creds, parentId, localPath, name, cb) {
		var id = (parentId == null || parentId === "") ? Config.ROOT_FOLDER : parentId;
		var url = this._url(creds, "uploadfile",
			{ folderid: id, filename: name, nopartial: 1 });
		var self = this, f = new Future();
		f.now(this, function () {
			return HttpCurl.request({ method: "POST", url: url,
				multipart: [{ name: "file", file: localPath }] });
		});
		f.then(this, function () { f.result = self._parse(f.result); });
		return f;
	},

	// GET /checksumfile?fileid={id} -> { metadata:{ name, parentfolderid, ... } }. Used by
	// uploadReplace to discover where an existing file lives so it can be overwritten in place.
	getFileInfo: function (creds, fileId, cb) {
		return this._get(creds, "checksumfile", { fileid: fileId });
	},

	// Overwrite an EXISTING file by fileid (QuickOffice save-back). pCloud has no
	// upload-by-fileid, but uploading the SAME filename into the SAME folder (without
	// renameifexists) overwrites it. So: look up the file's name + parent folder, then
	// re-upload the local bytes there.
	uploadReplace: function (creds, fileId, localPath, cb) {
		var self = this, f = new Future();
		var info = this.getFileInfo(creds, fileId);
		f.now(this, function () { return info; });
		f.then(this, function () {
			var meta;
			try { meta = (info.result && info.result.metadata) || {}; }
			catch (e) { f.setException(e); return; }
			if (meta.name == null || meta.parentfolderid == null) {
				f.setException({ returnValue: false, errorCode: "PCLOUD_NO_FILEINFO", detail: meta });
				return;
			}
			var up = self.uploadFile(creds, meta.parentfolderid, localPath, meta.name, cb);
			up.then(self, function () {
				try { f.result = up.result; }
				catch (e2) { f.setException(e2); }
			});
		});
		return f;
	}
};

if (typeof exports !== "undefined") { exports.PcloudApi = PcloudApi; }
