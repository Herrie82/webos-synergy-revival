/*global DropboxApi, AccountCreds, Acl, console */
/* uploadFile - upload a local file to Dropbox. args:
 *   { accountId | credentials, localPath, dropboxPath }
 * Pass an accountId (service reads/persists the stored tokens) OR raw credentials.
 * dropboxPath must be absolute in the Dropbox namespace, e.g. "/Apps/x/foo.txt".
 * All TLS is via the modern curl.
 *
 * Restricted to the file-picker / photos consumers via allowedAppIds (enforced by
 * Acl.enforce). A raw luna-send from a shell carries no appId and is rejected.
 */
function UploadFileCommandAssistant() {}

UploadFileCommandAssistant.prototype = {
	allowedAppIds: ["com.palm.app.dropbox-files", "com.palm.app.photos"],

	run: function (future) {
		if (!Acl.enforce(this, future)) { return; }
		var self = this, args = this.controller.args || {};
		if (!args.localPath || !args.dropboxPath) {
			future.setException({ returnValue: false, errorCode: "MISSING_ARGS",
				detail: "need localPath and dropboxPath" });
			return;
		}
		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; }
			catch (e) { future.setException(e); return; }
			var renewed = null;
			var call = DropboxApi.uploadFile(creds, args.dropboxPath, args.localPath,
				function (nc) { renewed = nc; });
			call.then(self, function () {
				var meta;
				try { meta = call.result; }
				catch (e2) { future.setException(e2); return; }
				if (renewed && args.accountId) { AccountCreds.save(args.accountId, renewed); }
				future.result = { returnValue: true, renewedCredentials: renewed,
					name: meta.name, path: meta.path_lower, size: meta.size, id: meta.id };
			});
		});
	}
};
