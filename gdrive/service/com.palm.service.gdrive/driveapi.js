/*global IMPORTS, Config, OAuth2, HttpCurl, console */
/* driveapi.js - Google Drive API v3 client. Drive is REST + ID-based, but unlike Box/
 * OneDrive it is NOT a folder tree you walk by path: children are found by QUERY
 * (files?q='{parentId}' in parents). A "folder" is mimeType
 * application/vnd.google-apps.folder; the root alias id is "root".
 *
 * Two Drive quirks the other connectors don't have:
 *   - Google-native docs (Docs/Sheets/Slides, mimeType application/vnd.google-apps.*) are
 *     not downloadable as bytes; they must be EXPORTED to a real format
 *     (GET /files/{id}/export?mimeType=...). Plain files use GET /files/{id}?alt=media.
 *   - Simple media upload can't set name+parent in one shot with our curl primitives, so
 *     uploadFile() is two steps: POST bytes (uploadType=media) -> PATCH metadata (name +
 *     move into the target folder).
 *
 * Transparent refresh-on-401 mirrors the other connectors. All HTTPS runs through the
 * modern curl because the device node is OpenSSL 0.9.8k.
 */
var Foundations = IMPORTS.foundations;
var Future = Foundations.Control.Future;

var DriveApi = {
	get: function (path, creds, onRenewed) {
		return this._req({ method: "GET", url: Config.API_BASE + path }, creds, onRenewed, false);
	},

	// Core request with refresh-on-401. `toFile` opts (follow/outFile) stream to disk.
	_req: function (base, creds, onRenewed, toFile) {
		var self = this, f = new Future();
		function fire(c) {
			var o = { method: base.method, url: base.url, bearer: c.accessToken };
			if (base.headers)  { o.headers = base.headers; }
			if (base.dataFile) { o.dataFile = base.dataFile; }   // raw-body POST upload
			if (base.body)     { o.body = base.body; }           // JSON PATCH body
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
						refreshToken: t.refreshToken || creds.refreshToken,  // Google keeps the old one
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
			throw { returnValue: false, errorCode: "GDRIVE_API_ERROR",
				status: r && r.status, body: r && r.responseText };
		}
		if (toFile) { return { path: base.outFile }; }
		return r.responseText ? JSON.parse(r.responseText) : {};
	},

	getAccountInfo: function (creds, cb) {            // GET /about -> { user:{displayName,emailAddress} }
		return this.get("/about?fields=user", creds, cb);
	},

	// List a folder's children by query -> raw Drive { files:[...], nextPageToken }.
	// NOTE: capped at pageSize 1000; folders with more are truncated (no pagination loop).
	listFolder: function (creds, folderId, cb) {
		var id = folderId || Config.ROOT_FOLDER;
		var q = "'" + id + "' in parents and trashed = false";
		var url = "/files?q=" + encodeURIComponent(q) +
			"&fields=" + encodeURIComponent("files(id,name,mimeType,size,modifiedTime),nextPageToken") +
			"&pageSize=1000&orderBy=folder,name";
		return this.get(url, creds, cb);
	},

	// Download a file to disk. exportMime set -> export a Google-native doc; else raw bytes.
	downloadFile: function (creds, fileId, localDest, exportMime, cb) {
		var url = exportMime
			? Config.API_BASE + "/files/" + encodeURIComponent(fileId) +
				"/export?mimeType=" + encodeURIComponent(exportMime)
			: Config.API_BASE + "/files/" + encodeURIComponent(fileId) + "?alt=media";
		return this._req({ method: "GET", url: url, outFile: localDest }, creds, cb, true);
	},

	// Two-step upload: (1) POST the bytes (creates an "Untitled" file in My Drive), then
	// (2) PATCH the name and move it into the target folder. Returns the final metadata.
	uploadFile: function (creds, folderId, localPath, name, mimeType, cb) {
		var self = this, f = new Future();
		var renewed = null;
		function onR(nc) { renewed = nc; if (cb) { cb(nc); } }

		var step1 = self._req({ method: "POST",
			url: Config.UPLOAD_BASE + "/files?uploadType=media&fields=id",
			headers: { "Content-Type": mimeType || "application/octet-stream" },
			dataFile: localPath }, creds, onR, false);

		f.now(this, function () { return step1; });
		f.then(this, function () {
			var created;
			try { created = step1.result; }
			catch (e) { f.setException(e); return; }
			var curCreds = renewed || creds;
			var parentId = folderId || Config.ROOT_FOLDER;
			var url = Config.API_BASE + "/files/" + encodeURIComponent(created.id) + "?fields=id,name,size";
			if (parentId !== Config.ROOT_FOLDER) {
				// media upload dropped the file in My Drive (root); reparent it.
				url += "&addParents=" + encodeURIComponent(parentId) + "&removeParents=root";
			}
			var step2 = self._req({ method: "PATCH", url: url,
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ name: name }) }, curCreds, onR, false);
			step2.then(self, function () {
				try { f.result = step2.result; }
				catch (e2) { f.setException(e2); }
			});
		});
		return f;
	}
};

if (typeof exports !== "undefined") { exports.DriveApi = DriveApi; }
