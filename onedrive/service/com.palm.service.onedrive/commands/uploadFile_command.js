/*global GraphApi, AccountCreds, Acl, console */
/* uploadFile - upload a local file into a OneDrive folder. args:
 *   { accountId | credentials, folderId | path, localPath, name }
 * folderId defaults to the drive root; name defaults to the local basename.
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
		var folderId = args.folderId || args.path || "root";
		var name = args.name || args.localPath.split("/").pop();
		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; }
			catch (e) { future.setException(e); return; }
			var renewed = null;
			var call = GraphApi.uploadFile(creds, folderId, args.localPath, name, function (nc) { renewed = nc; });
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
