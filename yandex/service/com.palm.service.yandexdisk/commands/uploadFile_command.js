/*global YandexApi, AccountCreds, Acl, console */
/* uploadFile - upload a local file to Yandex Disk. args:
 *   { accountId | credentials, localPath, path | folderId, name, replace }
 * Pass an accountId (service reads/persists the stored tokens) OR raw credentials.
 * Destination: give a full `path` (absolute Disk locator ending in the filename, e.g.
 * "disk:/Documents/foo.docx"), OR a `folderId` (folder locator) + `name`. name defaults
 * to the local basename. Yandex is path-based, so `replace` (QuickOffice save-back) is
 * just overwrite=true on the same path - the default here is already overwrite=true.
 * All TLS is via the modern curl.
 *
 * Restricted to the file-picker / photos consumers via allowedAppIds (enforced by
 * Acl.enforce). A raw luna-send from a shell carries no appId and is rejected.
 */
function UploadFileCommandAssistant() {}

UploadFileCommandAssistant.prototype = {
	allowedAppIds: ["com.palm.app.yandexdisk-files", "com.palm.app.photos",
		"com.quickoffice.webos", "com.quickoffice.ar"],

	run: function (future) {
		if (!Acl.enforce(this, future)) { return; }
		var self = this, args = this.controller.args || {};
		if (!args.localPath) {
			future.setException({ returnValue: false, errorCode: "MISSING_ARGS",
				detail: "need localPath" });
			return;
		}
		var name = args.name || args.localPath.split("/").pop();
		// Full destination path wins; otherwise join the folder locator + name.
		var dest = args.path || args.dropboxPath ||
			YandexApi._join(args.folderId || "disk:/", name);
		// Path-based replace == overwrite=true (which is also the create-default here).
		var overwrite = (args.replace === false) ? false : true;
		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; }
			catch (e) { future.setException(e); return; }
			var renewed = null;
			var call = YandexApi.uploadFile(creds, dest, args.localPath, overwrite,
				function (nc) { renewed = nc; });
			call.then(self, function () {
				var meta;
				try { meta = call.result || {}; }
				catch (e2) { future.setException(e2); return; }
				if (renewed && args.accountId) { AccountCreds.save(args.accountId, renewed); }
				future.result = { returnValue: true, renewedCredentials: renewed,
					name: meta.name, path: meta.path };
			});
		});
	}
};
