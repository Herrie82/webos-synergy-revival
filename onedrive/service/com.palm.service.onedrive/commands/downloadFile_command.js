/*global GraphApi, AccountCreds, Acl, console */
/* downloadFile - download a OneDrive file to a local path. args:
 *   { accountId | credentials, fileId | path | dropboxPath, localPath }
 * The drive-item ID may arrive as `fileId` OR as `path`/`dropboxPath` so the generic
 * QuickOffice / file-picker consumers call this exactly as they call Dropbox.
 */
function DownloadFileCommandAssistant() {}

DownloadFileCommandAssistant.prototype = {
	allowedAppIds: ["com.palm.app.onedrive-files", "com.palm.app.photos",
		"com.quickoffice.webos", "com.quickoffice.ar"],

	run: function (future) {
		if (!Acl.enforce(this, future)) { return; }
		var self = this, args = this.controller.args || {};
		var fileId = args.fileId || args.path || args.dropboxPath;
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
			var call = GraphApi.downloadFile(creds, fileId, args.localPath, function (nc) { renewed = nc; });
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
