/*global PcloudApi, AccountCreds, Acl, console */
/* uploadFile - upload a local file into a pCloud folder. args:
 *   { accountId | credentials, folderId | path, localPath, name }         (create/overwrite in a folder)
 *   { accountId | credentials, fileId | path | dropboxPath, localPath, replace:true }
 *                                                                          (overwrite by file id)
 * folderId defaults to the pCloud root (0); name defaults to the local basename. A plain
 * upload OVERWRITES a same-named file in the target folder (pCloud keeps the old copy as a
 * revision). `replace` (QuickOffice save-back) overwrites an EXISTING file by its id: pCloud
 * has no upload-by-fileid, so PcloudApi.uploadReplace looks up the file's name+parent folder
 * and re-uploads there.
 */
function UploadFileCommandAssistant() {}

UploadFileCommandAssistant.prototype = {
	allowedAppIds: ["com.palm.app.pcloud-files", "com.palm.app.photos",
		"com.quickoffice.webos", "com.quickoffice.ar"],

	run: function (future) {
		if (!Acl.enforce(this, future)) { return; }
		var self = this, args = this.controller.args || {};
		if (!args.localPath) {
			future.setException({ returnValue: false, errorCode: "MISSING_ARGS",
				detail: "need localPath" });
			return;
		}
		var replaceId = args.replace
			? ((args.fileId != null) ? args.fileId : ((args.path != null) ? args.path : args.dropboxPath))
			: null;
		var folderId = (args.folderId != null) ? args.folderId
			: ((args.path != null) ? args.path : 0);
		var name = args.name || args.localPath.split("/").pop();
		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; }
			catch (e) { future.setException(e); return; }
			var call = (replaceId != null)
				? PcloudApi.uploadReplace(creds, replaceId, args.localPath, function () {})
				: PcloudApi.uploadFile(creds, folderId, args.localPath, name, function () {});
			call.then(self, function () {
				var data;
				try { data = call.result || {}; }
				catch (e2) { future.setException(e2); return; }
				// pCloud returns { fileids:[id], metadata:[ item ] }.
				var meta = (data.metadata && data.metadata[0]) || {};
				var fid  = (data.fileids && data.fileids[0]);
				future.result = { returnValue: true,
					name: meta.name, id: (meta.fileid != null ? meta.fileid : fid), size: meta.size };
			});
		});
	}
};
