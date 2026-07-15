/*global YandexApi, AccountCreds, Acl, console */
/* downloadFile - download a Yandex Disk file to a local path. args:
 *   { accountId | credentials, path | dropboxPath, localPath }
 * Writes the bytes to localPath (curl streams to disk). All TLS is via the modern curl.
 * The Disk locator may arrive as `path` OR as `dropboxPath` so the generic QuickOffice /
 * file-picker consumers call this exactly as they call Dropbox.
 *
 * Restricted to the file-picker / photos consumers via allowedAppIds (enforced by
 * Acl.enforce). A raw luna-send from a shell carries no appId and is rejected.
 */
function DownloadFileCommandAssistant() {}

DownloadFileCommandAssistant.prototype = {
	allowedAppIds: ["com.palm.app.yandexdisk-files", "com.palm.app.photos",
		"com.quickoffice.webos", "com.quickoffice.ar"],

	run: function (future) {
		if (!Acl.enforce(this, future)) { return; }
		var self = this, args = this.controller.args || {};
		var path = args.path || args.dropboxPath;
		if (!path || !args.localPath) {
			future.setException({ returnValue: false, errorCode: "MISSING_ARGS",
				detail: "need path and localPath" });
			return;
		}
		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; }
			catch (e) { future.setException(e); return; }
			var renewed = null;
			var call = YandexApi.downloadFile(creds, path, args.localPath,
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
