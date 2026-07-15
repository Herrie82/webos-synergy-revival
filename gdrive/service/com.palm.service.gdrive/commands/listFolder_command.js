/*global DriveApi, AccountCreds, Acl, console */
/* listFolder - browse a Google Drive folder. args: { accountId | credentials, path | folderId }
 * Drive is ID-based: `path`/`folderId` is a file/folder ID (root alias = "root"), not a slash
 * path. Each returned entry's `path` IS the ID, so a consumer hands it straight back as the
 * next folderId (browse) or fileId (download) - keeping consumers Dropbox-generic. Entries
 * also carry `mimeType` and a `googleDoc` flag so a Drive-aware consumer can request an export.
 */
function ListFolderCommandAssistant() {}

ListFolderCommandAssistant.prototype = {
	allowedAppIds: ["com.palm.app.gdrive-files",
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
			var call = DriveApi.listFolder(creds, folderId, function (nc) { renewed = nc; });
			call.then(self, function () {
				var data;
				try { data = call.result; }
				catch (e2) { future.setException(e2); return; }
				if (renewed && args.accountId) { AccountCreds.save(args.accountId, renewed); }
				future.result = {
					returnValue: true,
					renewedCredentials: renewed,
					entries: (data.files || []).map(function (e) {
						var isFolder = (e.mimeType === "application/vnd.google-apps.folder");
						var isGoogleDoc = (!isFolder && e.mimeType &&
							e.mimeType.indexOf("application/vnd.google-apps.") === 0);
						return { id: e.id, type: (isFolder ? "folder" : "file"),
							name: e.name, size: e.size, modified: e.modifiedTime, path: e.id,
							mimeType: e.mimeType, googleDoc: isGoogleDoc };
					})
				};
			});
		});
	}
};
