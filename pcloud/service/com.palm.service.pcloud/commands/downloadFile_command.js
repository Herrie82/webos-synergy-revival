/*global PcloudApi, AccountCreds, Acl, console */
/* downloadFile - download a pCloud file to a local path. args:
 *   { accountId | credentials, fileId | path | dropboxPath, localPath }
 * The numeric fileid may arrive as `fileId` OR as `path`/`dropboxPath` so the generic
 * QuickOffice / file-picker consumers call this exactly as they call Dropbox. The service
 * resolves a temporary content link (getfilelink) and streams the bytes to localPath via
 * curl (--create-dirs).
 */
function DownloadFileCommandAssistant() {}

DownloadFileCommandAssistant.prototype = {
	allowedAppIds: ["com.palm.app.pcloud-files", "com.palm.app.photos",
		"com.quickoffice.webos", "com.quickoffice.ar"],

	run: function (future) {
		if (!Acl.enforce(this, future)) { return; }
		var self = this, args = this.controller.args || {};
		var fileId = (args.fileId != null) ? args.fileId
			: ((args.path != null) ? args.path : args.dropboxPath);
		if (fileId == null || !args.localPath) {
			future.setException({ returnValue: false, errorCode: "MISSING_ARGS",
				detail: "need fileId and localPath" });
			return;
		}
		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; }
			catch (e) { future.setException(e); return; }
			var call = PcloudApi.downloadFile(creds, fileId, args.localPath, function () {});
			call.then(self, function () {
				var res;
				try { res = call.result; }
				catch (e2) { future.setException(e2); return; }
				future.result = { returnValue: true, path: res.path };
			});
		});
	}
};
