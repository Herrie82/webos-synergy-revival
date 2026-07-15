/*global enyo, window */
/*
 * DropboxFiles - a minimal Dropbox browser / uploader for the revived connector.
 * All file I/O goes through com.palm.service.dropbox (which does modern TLS via the
 * bundled curl); this app only orchestrates and passes the account _id - never tokens.
 *
 *   listFolder(accountId, path)          -> browse folders/files
 *   downloadFile(accountId, dbxPath, ..) -> tap a file -> saves to /media/internal
 *   uploadFile(accountId, localPath, ..) -> Upload bar -> puts a local file in the folder
 */
enyo.kind({
	name: "DropboxFiles",
	kind: enyo.VFlexBox,
	className: "dbx-body",

	accountId: null,
	account:   null,
	path:      "",        // current Dropbox folder ("" = root)

	components: [
		{ kind: "Toolbar", className: "enyo-toolbar-light", pack: "center", components: [
			{ name: "header", kind: "Control", content: "Dropbox" }
		]},
		{ name: "pathLabel", className: "dbx-path", content: "/" },
		{ name: "status",    className: "dbx-status", content: "Loading…" },
		{ kind: "Scroller", flex: 1, components: [
			{ name: "list" }
		]},
		{ kind: "Toolbar", className: "dbx-uploadbar", components: [
			{ name: "localPath", kind: "Input", flex: 1, spellcheck: false,
				hint: "/media/internal/file-to-upload" },
			{ kind: "Button", caption: "Upload", onclick: "uploadTapped" },
			{ kind: "Button", caption: "↻", onclick: "refreshTapped" }
		]},

		{ name: "accts", kind: "PalmService", service: "palm://com.palm.service.accounts/" },
		{ name: "dbx",   kind: "PalmService", service: "palm://com.palm.service.dropbox/" }
	],

	create: function () {
		this.inherited(arguments);
		this._rows = [];
		this.log("dbxfiles: create -> listAccounts");
		this.$.accts.call({}, { method: "listAccounts",
			onSuccess: "gotAccounts", onFailure: "svcFail" });
	},

	setStatus: function (t) { this.$.status.setContent(t || ""); },

	gotAccounts: function (s, r) {
		var accts = (r && (r.results || r.accounts)) || [];   // listAccounts returns "results"
		this.log("dbxfiles: gotAccounts n=" + accts.length + " templates=" +
			accts.map(function (a) { return a.templateId; }).join(","));
		for (var i = 0; i < accts.length; i++) {
			if (accts[i].templateId === "com.palm.dropbox") { this.account = accts[i]; break; }
		}
		if (!this.account) {
			this.setStatus("No Dropbox account. Add one in Settings → Accounts, then reopen.");
			return;
		}
		this.accountId = this.account._id;
		this.$.header.setContent("Dropbox — " + (this.account.username || ""));
		this.browse("");
	},

	// --- browsing ------------------------------------------------------------
	browse: function (path) {
		this.path = path || "";
		this.$.pathLabel.setContent(this.path || "/");
		this.setStatus("Loading…");
		this.$.dbx.call({ accountId: this.accountId, path: this.path },
			{ method: "listFolder", onSuccess: "gotList", onFailure: "svcFail" });
	},

	gotList: function (s, r) {
		var entries = (r && r.entries) || [];
		this.log("dbxfiles: gotList entries=" + entries.length + " path=" + (this.path || "/"));
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
				{ className: "dbx-row dbx-up", content: "↑ up a folder", onclick: "upTapped" },
				{ owner: this }));
		}
		entries.forEach(function (e) {
			var isDir = (e.type === "folder");
			var row = self.$.list.createComponent({
				kind: "HFlexBox", className: "dbx-row", align: "center", onclick: "rowTapped",
				components: [
					{ flex: 1, className: "dbx-name", content: e.name + (isDir ? "/" : "") },
					{ className: "dbx-meta", content: isDir ? "" : self.fmtSize(e.size) }
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

	upTapped: function () {
		var parent = this.path.replace(/\/[^\/]*$/, "");
		this.browse(parent);
	},

	refreshTapped: function () { if (this.accountId) { this.browse(this.path); } },

	// --- download ------------------------------------------------------------
	downloadEntry: function (e) {
		var dest = "/media/internal/" + e.name;
		this.setStatus("Downloading " + e.name + "…");
		this.$.dbx.call({ accountId: this.accountId, dropboxPath: e.path, localPath: dest },
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
		var dbxPath = (this.path || "") + "/" + base;
		this.setStatus("Uploading " + base + "…");
		this.$.dbx.call({ accountId: this.accountId, localPath: local, dropboxPath: dbxPath },
			{ method: "uploadFile", onSuccess: "gotUpload", onFailure: "svcFail" });
	},

	gotUpload: function (s, r) {
		this.setStatus("Uploaded " + (r && r.name ? r.name : "") + ".");
		this.browse(this.path);   // refresh so the new file shows
	},

	// --- helpers -------------------------------------------------------------
	svcFail: function (s, r) {
		var code = (r && (r.errorText || r.errorCode)) || "request failed";
		this.log("dbxfiles: svcFail " + code);
		this.setStatus("Error: " + code);
	},

	fmtSize: function (n) {
		if (n == null) { return ""; }
		if (n < 1024) { return n + " B"; }
		if (n < 1048576) { return (n / 1024).toFixed(1) + " KB"; }
		return (n / 1048576).toFixed(1) + " MB";
	}
});
