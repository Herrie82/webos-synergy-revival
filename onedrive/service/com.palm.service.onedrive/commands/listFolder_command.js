/*global GraphApi, AccountCreds, Acl, console */
/* listFolder - browse a OneDrive folder. args: { accountId | credentials, path | folderId }
 * Graph is ID-based: `path`/`folderId` is a drive-item ID (root = "root" sentinel), not a
 * slash path. Each returned entry's `path` IS the item ID, so a consumer hands it straight
 * back as the next folderId (browse) or fileId (download) - keeping consumers Dropbox-generic.
 */
function ListFolderCommandAssistant() {}

ListFolderCommandAssistant.prototype = {
	allowedAppIds: ["com.palm.app.onedrive-files", "com.palm.app.photos",
		"com.quickoffice.webos", "com.quickoffice.ar"],

	run: function (future) {
		if (!Acl.enforce(this, future)) { return; }
		var self = this, args = this.controller.args || {};
		var folderId = args.folderId || args.path || "root";
		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; }
			catch (e) { future.setException(e); return; }
			var renewed = null;
			var call = GraphApi.listFolder(creds, folderId, function (nc) { renewed = nc; });
			call.then(self, function () {
				var data;
				try { data = call.result; }
				catch (e2) { future.setException(e2); return; }
				if (renewed && args.accountId) { AccountCreds.save(args.accountId, renewed); }
				future.result = {
					returnValue: true,
					renewedCredentials: renewed,
					entries: (data.value || []).map(function (e) {
						return { id: e.id, type: (e.folder ? "folder" : "file"),
							name: e.name, size: e.size, modified: e.lastModifiedDateTime, path: e.id };
					})
				};
			});
		});
	}
};
