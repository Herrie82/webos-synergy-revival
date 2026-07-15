/*global GraphApi, AccountCreds, Acl, console */
/* uploadFile - upload a local file into a OneDrive folder. args:
 *   { accountId | credentials, folderId | path, localPath, name }         (create/overwrite by path)
 *   { accountId | credentials, fileId | path | dropboxPath, localPath, replace:true }
 *                                                                          (overwrite by item id)
 * folderId defaults to the drive root; name defaults to the local basename. `replace` (QuickOffice
 * save-back) overwrites an existing item's content by id.
 */
function UploadFileCommandAssistant() {}

UploadFileCommandAssistant.prototype = {
	allowedAppIds: ["com.palm.app.onedrive-files", "com.palm.app.photos",
		"com.quickoffice.webos", "com.quickoffice.ar"],

	run: function (future) {
		if (!Acl.enforce(this, future)) { return; }
		var self = this, args = this.controller.args || {};
		if (!args.localPath) {
			future.setException({ returnValue: false, errorCode: "MISSING_ARGS",
				detail: "need localPath" });
			return;
		}
		var replaceId = args.replace ? (args.fileId || args.path || args.dropboxPath) : null;
		var folderId = args.folderId || args.path || "root";
		var name = args.name || args.localPath.split("/").pop();
		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; }
			catch (e) { future.setException(e); return; }
			var renewed = null;
			var call = replaceId
				? GraphApi.uploadReplace(creds, replaceId, args.localPath, function (nc) { renewed = nc; })
				: GraphApi.uploadFile(creds, folderId, args.localPath, name, function (nc) { renewed = nc; });
			call.then(self, function () {
				var meta;
				try { meta = call.result || {}; }   // Graph PUT returns the driveItem directly
				catch (e2) { future.setException(e2); return; }
				if (renewed && args.accountId) { AccountCreds.save(args.accountId, renewed); }
				future.result = { returnValue: true, renewedCredentials: renewed,
					name: meta.name, id: meta.id, size: meta.size };
			});
		});
	}
};
