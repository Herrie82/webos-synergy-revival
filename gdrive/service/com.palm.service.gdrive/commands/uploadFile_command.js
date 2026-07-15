/*global DriveApi, AccountCreds, Acl, console */
/* uploadFile - upload a local file into a Google Drive folder. args:
 *   { accountId | credentials, folderId | path, localPath, name, mimeType }  (create new file)
 *   { accountId | credentials, fileId | path | dropboxPath, localPath, replace:true }
 *                                                                            (overwrite by file id)
 * folderId defaults to the drive root; name defaults to the local basename. `replace` (QuickOffice
 * save-back) updates an existing file's content in place.
 */
function UploadFileCommandAssistant() {}

UploadFileCommandAssistant.prototype = {
	allowedAppIds: ["com.palm.app.gdrive-files",
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
				? DriveApi.uploadReplace(creds, replaceId, args.localPath, args.mimeType, function (nc) { renewed = nc; })
				: DriveApi.uploadFile(creds, folderId, args.localPath, name, args.mimeType, function (nc) { renewed = nc; });
			call.then(self, function () {
				var meta;
				try { meta = call.result || {}; }   // Drive 2-step upload returns the file metadata
				catch (e2) { future.setException(e2); return; }
				if (renewed && args.accountId) { AccountCreds.save(args.accountId, renewed); }
				future.result = { returnValue: true, renewedCredentials: renewed,
					name: meta.name, id: meta.id, size: meta.size };
			});
		});
	}
};
