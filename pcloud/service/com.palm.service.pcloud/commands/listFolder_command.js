/*global PcloudApi, AccountCreds, Acl, console */
/* listFolder - browse a pCloud folder. args: { accountId | credentials, path | folderId }
 * pCloud is ID-based: `path`/`folderId` is a numeric folderid (root = 0), not a slash path.
 * Each returned entry's `path` IS its numeric ID - a folderid for folders (hand back as the
 * next folderId to descend) or a fileid for files (hand back as the fileId to download) -
 * keeping consumers Dropbox-generic. `name` carries the real filename (the ID is opaque).
 */
function ListFolderCommandAssistant() {}

ListFolderCommandAssistant.prototype = {
	allowedAppIds: ["com.palm.app.pcloud-files", "com.palm.app.photos",
		"com.quickoffice.webos", "com.quickoffice.ar"],

	run: function (future) {
		if (!Acl.enforce(this, future)) { return; }
		var self = this, args = this.controller.args || {};
		var folderId = (args.folderId != null) ? args.folderId
			: ((args.path != null) ? args.path : 0);
		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; }
			catch (e) { future.setException(e); return; }
			var call = PcloudApi.listFolder(creds, folderId, function () {});
			call.then(self, function () {
				var data;
				try { data = call.result; }
				catch (e2) { future.setException(e2); return; }
				var contents = (data.metadata && data.metadata.contents) || [];
				future.result = {
					returnValue: true,
					entries: contents.map(function (e) {
						var id = e.isfolder ? e.folderid : e.fileid;
						return {
							id:       id,
							type:     e.isfolder ? "folder" : (e.contenttype || "file"),
							name:     e.name,
							size:     e.size,
							modified: e.modified,
							path:     id
						};
					})
				};
			});
		});
	}
};
