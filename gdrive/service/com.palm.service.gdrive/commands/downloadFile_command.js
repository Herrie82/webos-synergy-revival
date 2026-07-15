/*global DriveApi, AccountCreds, Acl, console */
/* downloadFile - download a Google Drive file to a local path. args:
 *   { accountId | credentials, fileId | path | dropboxPath, localPath }
 * The file ID may arrive as `fileId` OR as `path`/`dropboxPath`. Pass `exportMime` to export a
 * Google-native doc (Docs/Sheets/Slides); plain files ignore it. Generic consumers call it like Dropbox.
 */
function DownloadFileCommandAssistant() {}

DownloadFileCommandAssistant.prototype = {
	allowedAppIds: ["com.palm.app.gdrive-files",
		"com.quickoffice.webos", "com.quickoffice.ar"],

	run: function (future) {
		if (!Acl.enforce(this, future)) { return; }
		var self = this, args = this.controller.args || {};
		var fileId = args.fileId || args.path || args.dropboxPath;
		var exportMime = args.exportMime || null;
		if (!fileId || !args.localPath) {
			future.setException({ returnValue: false, errorCode: "MISSING_ARGS",
				detail: "need fileId and localPath" });
			return;
		}
		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; }
			catch (e) { future.setException(e); return; }
			var renewed = null;
			var call = DriveApi.downloadFile(creds, fileId, args.localPath, exportMime, function (nc) { renewed = nc; });
			call.then(self, function () {
				var res;
				try { res = call.result; }
				catch (e2) { future.setException(e2); return; }
				if (renewed && args.accountId) { AccountCreds.save(args.accountId, renewed); }
				future.result = { returnValue: true, renewedCredentials: renewed, path: res.path };
			});
		});
	}
};
