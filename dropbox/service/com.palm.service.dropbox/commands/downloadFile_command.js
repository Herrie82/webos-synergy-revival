/*global DropboxApi, AccountCreds, Acl, console */
/* downloadFile - download a Dropbox file to a local path. args:
 *   { accountId | credentials, dropboxPath, localPath }
 * Writes the bytes to localPath (curl streams to disk). All TLS is via the modern curl.
 *
 * Restricted to the file-picker / photos consumers via allowedAppIds (enforced by
 * Acl.enforce). A raw luna-send from a shell carries no appId and is rejected.
 */
function DownloadFileCommandAssistant() {}

DownloadFileCommandAssistant.prototype = {
	allowedAppIds: ["com.palm.app.dropbox-files", "com.palm.app.photos"],

	run: function (future) {
		if (!Acl.enforce(this, future)) { return; }
		var self = this, args = this.controller.args || {};
		if (!args.dropboxPath || !args.localPath) {
			future.setException({ returnValue: false, errorCode: "MISSING_ARGS",
				detail: "need dropboxPath and localPath" });
			return;
		}
		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; }
			catch (e) { future.setException(e); return; }
			var renewed = null;
			var call = DropboxApi.downloadFile(creds, args.dropboxPath, args.localPath,
				function (nc) { renewed = nc; });
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
