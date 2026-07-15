/*global IMPORTS, Config, OAuth2, HttpCurl, console */
/* graphapi.js - Microsoft Graph client for OneDrive. Like Box it is RESTful and
 * ID-addressed, but the drive item tree is reached by URL segments rather than a
 * numeric id in the path:
 *   - root children:   GET /me/drive/root/children
 *   - folder children: GET /me/drive/items/{id}/children
 *   - file bytes:      GET /me/drive/items/{id}/content  (302 -> pre-signed URL)
 *   - upload:          PUT /me/drive/{root:|items/{id}:}/{name}:/content  (raw body)
 * A children listing WITHOUT $select returns each item's folder/file facet, size,
 * lastModifiedDateTime AND `@microsoft.graph.downloadUrl` - a short-lived pre-signed
 * URL the Photos aggregator's curl can fetch with no auth header. Transparent
 * refresh-on-401 mirrors boxapi.js. All HTTPS runs through the modern curl because the
 * device node is OpenSSL 0.9.8k.
 */
var Foundations = IMPORTS.foundations;
var Future = Foundations.Control.Future;

var GraphApi = {
	// GET a JSON endpoint with Bearer + transparent refresh-on-401.
	get: function (path, creds, onRenewed) {
		return this._req({ method: "GET", url: Config.API_BASE + path }, creds, onRenewed, false);
	},

	// Core request with refresh-on-401. `toFile` opts (follow/outFile) stream to disk.
	_req: function (base, creds, onRenewed, toFile) {
		var self = this, f = new Future();
		function fire(c) {
			var o = { method: base.method, url: base.url, bearer: c.accessToken };
			if (base.headers)   { o.headers = base.headers; }
			if (base.dataFile)  { o.dataFile = base.dataFile; }   // raw-body PUT upload
			if (toFile)         { o.follow = true; o.outFile = base.outFile; }
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
						refreshToken: t.refreshToken || creds.refreshToken,  // MS rotates -> keep new
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
			throw { returnValue: false, errorCode: "GRAPH_API_ERROR",
				status: r && r.status, body: r && r.responseText };
		}
		if (toFile) { return { path: base.outFile }; }
		return r.responseText ? JSON.parse(r.responseText) : {};
	},

	getAccountInfo: function (creds, cb) {            // GET /me
		return this.get("/me?$select=id,displayName,userPrincipalName,mail", creds, cb);
	},

	// GET children of a drive item -> raw Graph { value:[ driveItem ] }. NO $select, so the
	// folder/file facets and @microsoft.graph.downloadUrl come through. itemId falsy/"root"
	// lists the drive root.
	listFolder: function (creds, itemId, cb) {
		var seg = (!itemId || itemId === Config.ROOT_FOLDER)
			? "/me/drive/root/children"
			: "/me/drive/items/" + encodeURIComponent(itemId) + "/children";
		return this.get(seg + "?$top=1000", creds, cb);
	},

	// GET children of a named special folder (e.g. "cameraroll") -> raw Graph { value:[...] }.
	listSpecialChildren: function (creds, special, cb) {
		return this.get("/me/drive/special/" + encodeURIComponent(special) +
			"/children?$top=1000", creds, cb);
	},

	// GET /me/drive/items/{id}/content -> 302 to a pre-signed host (curl -L follows; curl
	// strips the Authorization header on the cross-host redirect) -> bytes to disk.
	downloadFile: function (creds, itemId, localDest, cb) {
		return this._req({ method: "GET",
			url: Config.API_BASE + "/me/drive/items/" + encodeURIComponent(itemId) + "/content",
			outFile: localDest }, creds, cb, true);
	},

	// PUT simple upload (raw file body). parentId falsy/"root" -> drive root. Good for files
	// up to ~250 MB; larger needs an upload session (not implemented). Returns the driveItem.
	uploadFile: function (creds, parentId, localPath, name, cb) {
		var seg = (!parentId || parentId === Config.ROOT_FOLDER)
			? "/me/drive/root:/" + encodeURIComponent(name) + ":/content"
			: "/me/drive/items/" + encodeURIComponent(parentId) + ":/" +
				encodeURIComponent(name) + ":/content";
		return this._req({ method: "PUT", url: Config.API_BASE + seg,
			headers: { "Content-Type": "application/octet-stream" },
			dataFile: localPath }, creds, cb, false);
	},

	// PUT new content to an EXISTING item (overwrite by id) - QuickOffice save-back.
	uploadReplace: function (creds, itemId, localPath, cb) {
		return this._req({ method: "PUT",
			url: Config.API_BASE + "/me/drive/items/" + encodeURIComponent(itemId) + "/content",
			headers: { "Content-Type": "application/octet-stream" },
			dataFile: localPath }, creds, cb, false);
	}
};

if (typeof exports !== "undefined") { exports.GraphApi = GraphApi; }
