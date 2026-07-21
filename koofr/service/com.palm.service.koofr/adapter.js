/*global IMPORTS, Config, HttpCurl, Buffer, require, console */
/* adapter.js - Koofr provider ADAPTER for _cloudcore. Koofr is MOUNT + PATH based: files live
 * under a mount (the user's primary personal storage), addressed by (mountId, absolute path). The
 * primary mount id is resolved at login and carried in the credentials; a locator handed to
 * consumers is the absolute path within that mount (the ROOT_FOLDER sentinel "/" is the mount
 * root). Auth is HTTP Basic (email:app-password) - app passwords don't expire, so there is no
 * refresh. All HTTPS runs through the modern curl (device node is 0.9.8k). The content host is the
 * same host with a "/content/api/v2" path prefix.
 *
 * Credentials (creds): { accessToken:<app password>, email, mountId }. The app password doubles
 * as _cloudcore's accessToken so AccountCreds + the generic commands work unchanged.
 */
var Foundations = IMPORTS.foundations;
var Future = Foundations.Control.Future;

var Adapter = {
	_b64: function (s) {
		if (typeof Buffer !== "undefined") {
			return (Buffer.from ? Buffer.from(s, "utf8") : new Buffer(s, "utf8")).toString("base64");
		}
		return s;   // should not happen in the node service
	},
	_hdr: function (c) {
		return { "Authorization": "Basic " + this._b64((c.email || "") + ":" + (c.accessToken || "")),
			"X-Koofr-Version": Config.KOOFR_VERSION || "2.1" };
	},
	_enc: function (p) { return encodeURIComponent(p); },
	_norm: function (p) {
		if (!p || p === "root" || p === "" || p === Config.ROOT_FOLDER) { return "/"; }
		return (p.charAt(0) === "/") ? p : ("/" + p);
	},
	_join: function (folder, name) {
		var base = (folder === "/") ? "" : String(folder).replace(/\/+$/, "");
		return base + "/" + name;
	},
	_leaf: function (p) { var s = String(p).replace(/\/+$/, ""); var i = s.lastIndexOf("/"); return i >= 0 ? s.substring(i + 1) : s; },
	_dirOf: function (p) { var s = String(p).replace(/\/+$/, ""); var i = s.lastIndexOf("/"); return i > 0 ? s.substring(0, i) : "/"; },
	_mime: function (name, isFolder, contentType) {
		if (contentType) { return contentType; }
		if (isFolder) { return "application/x-directory"; }
		var m = /\.([a-z0-9]+)$/i.exec(name || ""); var ext = m ? m[1].toLowerCase() : "";
		var map = { jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", gif: "image/gif",
			bmp: "image/bmp", heic: "image/heic", webp: "image/webp", pdf: "application/pdf" };
		return map[ext] || null;
	},

	// Basic-auth HttpCurl call (no refresh - app passwords are static). opts: { method, url,
	// headers, outFile, dataFile, multipart, body }. Resolves to { status, responseText }.
	_req: function (creds, opts) {
		var self = this, f = new Future();
		var o = { method: opts.method || "GET", url: opts.url, headers: this._hdr(creds) };
		if (opts.headers) { Object.keys(opts.headers).forEach(function (k) { o.headers[k] = opts.headers[k]; }); }
		if (opts.outFile) { o.outFile = opts.outFile; o.follow = true; }
		if (opts.dataFile) { o.dataFile = opts.dataFile; }
		if (opts.multipart) { o.multipart = opts.multipart; }
		if (opts.body != null) { o.body = opts.body; }
		var call = HttpCurl.request(o);
		f.now(this, function () { return call; });
		f.then(this, function () { f.result = call.result; });
		return f;
	},
	_parse: function (r) {
		if (!r || r.status < 200 || r.status >= 300) {
			throw { returnValue: false, errorCode: "KOOFR_API_ERROR", status: r && r.status, body: r && r.responseText };
		}
		return r.responseText ? JSON.parse(r.responseText) : {};
	},

	// GET /mounts -> the primary personal mount id (isPrimary==true), else the first mount.
	resolveMount: function (creds, cb) {
		var self = this, f = new Future();
		var call = this._req(creds, { method: "GET", url: Config.API_BASE + "/mounts" });
		call.then(this, function () {
			try {
				var d = self._parse(call.result) || {}; var mounts = d.mounts || [];
				var primary = null;
				for (var i = 0; i < mounts.length; i++) { if (mounts[i].isPrimary) { primary = mounts[i]; break; } }
				if (!primary && mounts.length) { primary = mounts[0]; }
				if (!primary) { throw { returnValue: false, errorCode: "KOOFR_NO_MOUNT" }; }
				f.result = primary.id;
			} catch (e) { f.setException(e); }
		});
		return f;
	},
	// mountId from creds, or resolve it (and remember on creds for the rest of this call chain).
	_mount: function (creds, cb) {
		var self = this, f = new Future();
		if (creds.mountId) { f.result = creds.mountId; return f; }
		var rm = this.resolveMount(creds, cb);
		f.now(this, function () { return rm; });
		f.then(this, function () { try { creds.mountId = rm.result; f.result = creds.mountId; } catch (e) { f.setException(e); } });
		return f;
	},

	// GET /user -> identity (validates the Basic credentials).
	getAccountInfo: function (creds, cb) {
		var self = this, f = new Future();
		var call = this._req(creds, { method: "GET", url: Config.API_BASE + "/user" });
		call.then(this, function () {
			try {
				var u = self._parse(call.result) || {};
				var name = ((u.firstName || "") + " " + (u.lastName || "")).replace(/^\s+|\s+$/g, "");
				f.result = { user: { emailAddress: u.email, displayName: name || u.email } };
			} catch (e) { f.setException(e); }
		});
		return f;
	},

	// GET /mounts/{mid}/files/list?path=.. -> normalised entries (Koofr returns basenames, so the
	// full path is composed from the folder path + name).
	listFolder: function (creds, folderId, cb) {
		var self = this, f = new Future();
		var folderPath = this._norm(folderId);
		var mf = this._mount(creds, cb);
		f.now(this, function () { return mf; });
		f.then(this, function () {
			var mid;
			try { mid = mf.result; } catch (e0) { f.setException(e0); return; }
			var url = Config.API_BASE + "/mounts/" + mid + "/files/list?path=" + self._enc(folderPath);
			var call = self._req(creds, { method: "GET", url: url });
			call.then(self, function () {
				try {
					var d = self._parse(call.result) || {}; var files = d.files || [];
					f.result = { entries: files.map(function (o) {
						var isFolder = (o.type === "dir");
						var full = self._join(folderPath, o.name);
						return { id: full, type: (isFolder ? "folder" : "file"), name: o.name,
							size: o.size || 0, modified: o.modified || 0, path: full,
							mimeType: self._mime(o.name, isFolder, o.contentType) };
					}) };
				} catch (e) { f.setException(e); }
			});
		});
		return f;
	},

	// GET content/mounts/{mid}/files/get?path=.. -> bytes to disk.
	downloadFile: function (creds, fileId, localDest, exportMime, cb) {
		var self = this, f = new Future();
		var mf = this._mount(creds, cb);
		f.now(this, function () { return mf; });
		f.then(this, function () {
			var mid;
			try { mid = mf.result; } catch (e0) { f.setException(e0); return; }
			var url = Config.CONTENT_BASE + "/mounts/" + mid + "/files/get?path=" + self._enc(self._norm(fileId));
			var call = self._req(creds, { method: "GET", url: url, outFile: localDest });
			call.then(self, function () {
				try {
					var r = call.result;
					if (!r || r.status < 200 || r.status >= 300) {
						throw { returnValue: false, errorCode: "KOOFR_DOWNLOAD_FAILED", status: r && r.status };
					}
					f.result = { path: localDest };
				} catch (e) { f.setException(e); }
			});
		});
		return f;
	},

	// POST content/mounts/{mid}/files/put?path=<folder>&filename=<name> (multipart "file").
	uploadFile: function (creds, folderId, localPath, name, mimeType, cb) {
		return this._put(creds, this._norm(folderId), name, localPath, cb);
	},
	uploadReplace: function (creds, fileId, localPath, mimeType, cb) {
		return this._put(creds, this._dirOf(this._norm(fileId)), this._leaf(fileId), localPath, cb);
	},
	_put: function (creds, folderPath, name, localPath, cb) {
		var self = this, f = new Future();
		var mf = this._mount(creds, cb);
		f.now(this, function () { return mf; });
		f.then(this, function () {
			var mid;
			try { mid = mf.result; } catch (e0) { f.setException(e0); return; }
			var url = Config.CONTENT_BASE + "/mounts/" + mid + "/files/put?path=" + self._enc(folderPath) +
				"&filename=" + self._enc(name) + "&info=true&overwrite=true";
			var call = self._req(creds, { method: "POST", url: url,
				multipart: [{ name: "file", file: localPath }] });
			call.then(self, function () {
				try {
					var meta = self._parse(call.result) || {};
					var full = self._join(folderPath, meta.name || name);
					f.result = { id: full, path: full, name: meta.name || name, size: meta.size };
				} catch (e) { f.setException(e); }
			});
		});
		return f;
	},

	// --- PHOTO.UPLOAD helpers ------------------------------------------------------------
	resolvePhotoAlbum: function (creds, cb) {
		var self = this, f = new Future();
		var name = Config.PHOTO_ALBUM_NAME || "Camera Uploads";
		var path = "/" + name;
		var mf = this._mount(creds, cb);
		f.now(this, function () { return mf; });
		f.then(this, function () {
			var mid;
			try { mid = mf.result; } catch (e) { f.result = { path: path, name: name, exists: false }; return; }
			var url = Config.API_BASE + "/mounts/" + mid + "/files/info?path=" + self._enc(path);
			var probe = self._req(creds, { method: "GET", url: url });
			probe.then(self, function () {
				var ok = false;
				try { var r = probe.result; ok = !!(r && r.status >= 200 && r.status < 300); } catch (e2) { ok = false; }
				f.result = { path: path, name: name, exists: ok };
			});
		});
		return f;
	},
	// POST /mounts/{mid}/files/folder?path=<parent> body {"name":..}.
	ensureAlbumFolder: function (creds, name, cb) {
		var self = this, f = new Future();
		var leaf = String(name).replace(/^\/+|\/+$/g, "");
		var mf = this._mount(creds, cb);
		f.now(this, function () { return mf; });
		f.then(this, function () {
			var mid;
			try { mid = mf.result; } catch (e0) { f.setException(e0); return; }
			var url = Config.API_BASE + "/mounts/" + mid + "/files/folder?path=" + self._enc("/");
			var call = self._req(creds, { method: "POST", url: url,
				headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: leaf }) });
			call.then(self, function () {
				var r = call.result;
				// 200/201 created, or 409 already exists -> success.
				if (r && (r.status === 409 || (r.status >= 200 && r.status < 300))) { f.result = "/" + leaf; }
				else { f.setException({ returnValue: false, errorCode: "KOOFR_MKDIR_FAILED", status: r && r.status }); }
			});
		});
		return f;
	},
	// GET /mounts/{mid}/files/download?path=.. -> { link } (a ready-to-GET URL for the aggregator).
	getTemporaryLink: function (creds, fileId, cb) {
		var self = this, f = new Future();
		var mf = this._mount(creds, cb);
		f.now(this, function () { return mf; });
		f.then(this, function () {
			var mid;
			try { mid = mf.result; } catch (e0) { f.setException(e0); return; }
			var url = Config.API_BASE + "/mounts/" + mid + "/files/download?path=" + self._enc(self._norm(fileId));
			var call = self._req(creds, { method: "GET", url: url });
			call.then(self, function () {
				try { var d = self._parse(call.result) || {}; f.result = { link: d.link, method: "GET" }; }
				catch (e) { f.setException(e); }
			});
		});
		return f;
	},
	// DELETE /mounts/{mid}/files/remove?path=..
	deletePhoto: function (creds, fileId, cb) {
		var self = this, f = new Future();
		var mf = this._mount(creds, cb);
		f.now(this, function () { return mf; });
		f.then(this, function () {
			var mid;
			try { mid = mf.result; } catch (e0) { f.setException(e0); return; }
			var url = Config.API_BASE + "/mounts/" + mid + "/files/remove?path=" + self._enc(self._norm(fileId));
			var call = self._req(creds, { method: "DELETE", url: url });
			call.then(self, function () {
				var r = call.result;
				if (r && (r.status === 200 || r.status === 204 || (r.status >= 200 && r.status < 300))) { f.result = { deleted: true }; }
				else { f.setException({ returnValue: false, errorCode: "KOOFR_DELETE_FAILED", status: r && r.status }); }
			});
		});
		return f;
	}
};

if (typeof exports !== "undefined") { exports.Adapter = Adapter; }
