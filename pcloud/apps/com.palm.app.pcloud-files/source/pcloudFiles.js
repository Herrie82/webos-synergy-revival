/*global enyo, window */
/*
 * PcloudFiles - a minimal pCloud browser / uploader for the revived connector.
 * All file I/O goes through com.palm.service.pcloud (which does modern TLS via the bundled
 * curl and talks to the account's data-region host); this app only orchestrates and passes
 * the account _id - never tokens.
 *
 * pCloud is ID-based: a "folder" is a numeric folderid (root = 0), NOT a path, and an item
 * carries no parent pointer we use here. So we can't derive the parent by trimming a path the
 * way the Dropbox app does - we keep an explicit ancestor-id stack for "up a folder". Each
 * list entry's `path` field IS its pCloud id (folderid to descend / fileid to fetch).
 *
 *   listFolder(accountId, path=folderId)      -> browse folders/files
 *   downloadFile(accountId, dropboxPath=id..) -> tap a file -> saves to /media/internal
 *   uploadFile(accountId, localPath, folderId)-> Upload bar -> puts a local file here
 */
enyo.kind({
	name: "PcloudFiles",
	kind: enyo.VFlexBox,
	className: "pc-body",

	accountId: null,
	account:   null,
	path:      "",        // current pCloud folder id ("" -> service defaults to root 0)
	stack:     null,      // ancestor folder ids, for "up a folder" (pCloud has no parent ptr here)

	components: [
		{ kind: "Toolbar", className: "enyo-toolbar-light", pack: "center", components: [
			{ name: "header", kind: "Control", content: "pCloud" }
		]},
		{ name: "pathLabel", className: "pc-path", content: "/" },
		{ name: "status",    className: "pc-status", content: "Loading…" },
		{ kind: "Scroller", flex: 1, components: [
			{ name: "list" }
		]},
		{ kind: "Toolbar", className: "pc-uploadbar", components: [
			{ name: "localPath", kind: "Input", flex: 1, spellcheck: false,
				hint: "/media/internal/file-to-upload" },
			{ kind: "Button", caption: "Upload", onclick: "uploadTapped" },
			{ kind: "Button", caption: "↻", onclick: "refreshTapped" }
		]},

		{ name: "accts", kind: "PalmService", service: "palm://com.palm.service.accounts/" },
		{ name: "dbx",   kind: "PalmService", service: "palm://com.palm.service.pcloud/" }
	],

	create: function () {
		this.inherited(arguments);
		this._rows = [];
		this.stack = [];        // [{id,name}] ancestors of the current folder
		this.log("pcloudfiles: create -> listAccounts");
		this.$.accts.call({}, { method: "listAccounts",
			onSuccess: "gotAccounts", onFailure: "svcFail" });
	},

	setStatus: function (t) { this.$.status.setContent(t || ""); },

	gotAccounts: function (s, r) {
		var accts = (r && (r.results || r.accounts)) || [];   // listAccounts returns "results"
		this.log("pcloudfiles: gotAccounts n=" + accts.length + " templates=" +
			accts.map(function (a) { return a.templateId; }).join(","));
		for (var i = 0; i < accts.length; i++) {
			if (accts[i].templateId === "com.palm.pcloud") { this.account = accts[i]; break; }
		}
		if (!this.account) {
			this.setStatus("No pCloud account. Add one in Settings → Accounts, then reopen.");
			return;
		}
		this.accountId = this.account._id;
		this.$.header.setContent("pCloud — " + (this.account.username || ""));
		this.browse("");   // "" -> pCloud root (0)
	},

	// --- browsing ------------------------------------------------------------
	browse: function (folderId) {
		this.path = (folderId == null) ? "" : folderId;
		var crumb = this.stack.map(function (a) { return a.name; }).join(" / ");
		this.$.pathLabel.setContent(crumb ? "/ " + crumb : "/");
		this.setStatus("Loading…");
		this.$.dbx.call({ accountId: this.accountId, path: this.path },
			{ method: "listFolder", onSuccess: "gotList", onFailure: "svcFail" });
	},

	// Descend into a folder: remember where we came from, then load the child.
	descend: function (entry) {
		this.stack.push({ id: this.path, name: entry.name });
		this.browse(entry.path);
	},

	gotList: function (s, r) {
		var entries = (r && r.entries) || [];
		this.log("pcloudfiles: gotList entries=" + entries.length + " path=" + (this.path || "/"));
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

		if (this.path !== "" && this.path !== 0) {
			this._rows.push(this.$.list.createComponent(
				{ className: "pc-row pc-up", content: "↑ up a folder", onclick: "upTapped" },
				{ owner: this }));
		}
		entries.forEach(function (e) {
			var isDir = (e.type === "folder");
			var row = self.$.list.createComponent({
				kind: "HFlexBox", className: "pc-row", align: "center", onclick: "rowTapped",
				components: [
					{ flex: 1, className: "pc-name", content: e.name + (isDir ? "/" : "") },
					{ className: "pc-meta", content: isDir ? "" : self.fmtSize(e.size) }
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
		if (e.type === "folder") { this.descend(e); }
		else { this.downloadEntry(e); }
	},

	upTapped: function () {
		var parent = this.stack.pop();      // undefined at root -> guarded by row visibility
		this.browse(parent ? parent.id : "");
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
		this.setStatus("Uploading " + base + "…");
		// pCloud upload targets a folder ID (current folder; "" -> service root 0) with an
		// explicit name - there is no path string as in Dropbox.
		this.$.dbx.call({ accountId: this.accountId, localPath: local,
			folderId: this.path, name: base },
			{ method: "uploadFile", onSuccess: "gotUpload", onFailure: "svcFail" });
	},

	gotUpload: function (s, r) {
		this.setStatus("Uploaded " + (r && r.name ? r.name : "") + ".");
		this.browse(this.path);   // refresh so the new file shows
	},

	// --- helpers -------------------------------------------------------------
	svcFail: function (s, r) {
		var code = (r && (r.errorText || r.errorCode)) || "request failed";
		this.log("pcloudfiles: svcFail " + code);
		this.setStatus("Error: " + code);
	},

	fmtSize: function (n) {
		if (n == null) { return ""; }
		if (n < 1024) { return n + " B"; }
		if (n < 1048576) { return (n / 1024).toFixed(1) + " KB"; }
		return (n / 1048576).toFixed(1) + " MB";
	}
});
