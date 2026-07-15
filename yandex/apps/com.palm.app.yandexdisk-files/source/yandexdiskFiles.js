/*global enyo, window */
/*
 * YandexdiskFiles - a minimal Yandex Disk browser / uploader for the revived connector.
 * All file I/O goes through com.palm.service.yandexdisk (which does modern TLS via the
 * bundled curl); this app only orchestrates and passes the account _id - never tokens.
 *
 *   listFolder(accountId, path)          -> browse folders/files
 *   downloadFile(accountId, path, ..)    -> tap a file -> saves to /media/internal
 *   uploadFile(accountId, localPath, ..) -> Upload bar -> puts a local file in the folder
 *
 * Yandex Disk is path-based: the root is "" (the service normalises it to "disk:/"), and
 * each entry's `path` is a "disk:/.." locator handed straight back for browse/download.
 */
enyo.kind({
	name: "YandexdiskFiles",
	kind: enyo.VFlexBox,
	className: "ydx-body",

	accountId: null,
	account:   null,
	path:      "",        // current Disk folder ("" = root)

	components: [
		{ kind: "Toolbar", className: "enyo-toolbar-light", pack: "center", components: [
			{ name: "header", kind: "Control", content: "Yandex Disk" }
		]},
		{ name: "pathLabel", className: "ydx-path", content: "/" },
		{ name: "status",    className: "ydx-status", content: "Loading…" },
		{ kind: "Scroller", flex: 1, components: [
			{ name: "list" }
		]},
		{ kind: "Toolbar", className: "ydx-uploadbar", components: [
			{ name: "localPath", kind: "Input", flex: 1, spellcheck: false,
				hint: "/media/internal/file-to-upload" },
			{ kind: "Button", caption: "Upload", onclick: "uploadTapped" },
			{ kind: "Button", caption: "↻", onclick: "refreshTapped" }
		]},

		{ name: "accts", kind: "PalmService", service: "palm://com.palm.service.accounts/" },
		{ name: "ydx",   kind: "PalmService", service: "palm://com.palm.service.yandexdisk/" }
	],

	create: function () {
		this.inherited(arguments);
		this._rows = [];
		this.log("ydxfiles: create -> listAccounts");
		this.$.accts.call({}, { method: "listAccounts",
			onSuccess: "gotAccounts", onFailure: "svcFail" });
	},

	setStatus: function (t) { this.$.status.setContent(t || ""); },

	gotAccounts: function (s, r) {
		var accts = (r && (r.results || r.accounts)) || [];   // listAccounts returns "results"
		this.log("ydxfiles: gotAccounts n=" + accts.length + " templates=" +
			accts.map(function (a) { return a.templateId; }).join(","));
		for (var i = 0; i < accts.length; i++) {
			if (accts[i].templateId === "com.palm.yandexdisk") { this.account = accts[i]; break; }
		}
		if (!this.account) {
			this.setStatus("No Yandex Disk account. Add one in Settings → Accounts, then reopen.");
			return;
		}
		this.accountId = this.account._id;
		this.$.header.setContent("Yandex Disk — " + (this.account.username || ""));
		this.browse("");
	},

	// --- browsing ------------------------------------------------------------
	browse: function (path) {
		this.path = path || "";
		this.$.pathLabel.setContent(this.path || "/");
		this.setStatus("Loading…");
		this.$.ydx.call({ accountId: this.accountId, path: this.path },
			{ method: "listFolder", onSuccess: "gotList", onFailure: "svcFail" });
	},

	gotList: function (s, r) {
		var entries = (r && r.entries) || [];
		this.log("ydxfiles: gotList entries=" + entries.length + " path=" + (this.path || "/"));
		entries.sort(function (a, b) {
			if (a.type !== b.type) { return a.type === "folder" ? -1 : 1; }
			return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1;
		});
		this.renderList(entries);
		this.setStatus(entries.length ? "" : "(empty folder)");
	},

	renderList: function (entries) {
		var self = this;
		this._rows.forEach(function (row) { row.destroy(); });
		this._rows = [];

		if (this.path) {
			this._rows.push(this.$.list.createComponent(
				{ className: "ydx-row ydx-up", content: "↑ up a folder", onclick: "upTapped" },
				{ owner: this }));
		}
		entries.forEach(function (e) {
			var isDir = (e.type === "folder");
			var row = self.$.list.createComponent({
				kind: "HFlexBox", className: "ydx-row", align: "center", onclick: "rowTapped",
				components: [
					{ flex: 1, className: "ydx-name", content: e.name + (isDir ? "/" : "") },
					{ className: "ydx-meta", content: isDir ? "" : self.fmtSize(e.size) }
				]
			}, { owner: self });
			row.entry = e;
			self._rows.push(row);
		});
		this.$.list.render();
	},

	rowTapped: function (inSender) {
		var e = inSender.entry;
		if (!e) { return; }
		if (e.type === "folder") { this.browse(e.path); }
		else { this.downloadEntry(e); }
	},

	// Parent of a Disk locator: "disk:/A/B" -> "disk:/A"; "disk:/A" -> "disk:/" (root).
	upTapped: function () {
		var p = (this.path || "").replace(/\/+$/, "");
		if (!p || p === "disk:") { this.browse(""); return; }
		var idx = p.lastIndexOf("/");
		var parent = (idx > 5) ? p.substring(0, idx) : "disk:/";   // "disk:".length === 5
		if (parent === "disk:") { parent = "disk:/"; }
		this.browse(parent);
	},

	refreshTapped: function () { if (this.accountId) { this.browse(this.path); } },

	// --- download ------------------------------------------------------------
	downloadEntry: function (e) {
		var dest = "/media/internal/" + e.name;
		this.setStatus("Downloading " + e.name + "…");
		this.$.ydx.call({ accountId: this.accountId, path: e.path, localPath: dest },
			{ method: "downloadFile", onSuccess: "gotDownload", onFailure: "svcFail" });
	},

	gotDownload: function (s, r) {
		this.setStatus("Saved to " + (r && r.path ? r.path : "/media/internal"));
	},

	// --- upload --------------------------------------------------------------
	uploadTapped: function () {
		var local = (this.$.localPath.getValue() || "").replace(/^\s+|\s+$/g, "");
		if (!local) { this.setStatus("Enter a local file path to upload (e.g. /media/internal/pic.jpg)."); return; }
		var base = local.split("/").pop();
		this.setStatus("Uploading " + base + "…");
		// Send the folder locator + name; the service joins them into the destination path.
		this.$.ydx.call({ accountId: this.accountId, localPath: local, folderId: this.path, name: base },
			{ method: "uploadFile", onSuccess: "gotUpload", onFailure: "svcFail" });
	},

	gotUpload: function (s, r) {
		this.setStatus("Uploaded " + (r && r.name ? r.name : "") + ".");
		this.browse(this.path);   // refresh so the new file shows
	},

	// --- helpers -------------------------------------------------------------
	svcFail: function (s, r) {
		var code = (r && (r.errorText || r.errorCode)) || "request failed";
		this.log("ydxfiles: svcFail " + code);
		this.setStatus("Error: " + code);
	},

	fmtSize: function (n) {
		if (n == null) { return ""; }
		if (n < 1024) { return n + " B"; }
		if (n < 1048576) { return (n / 1024).toFixed(1) + " KB"; }
		return (n / 1048576).toFixed(1) + " MB";
	}
});
