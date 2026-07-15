/*global BoxApi, AccountCreds, Acl, console */
/* uploadFile - upload a local file into a Box folder. args:
 *   { accountId | credentials, folderId | path, localPath, name }
 * folderId defaults to root "0"; name defaults to the local basename.
 */
function UploadFileCommandAssistant() {}

UploadFileCommandAssistant.prototype = {
	allowedAppIds: ["com.palm.app.boxnet-files", "com.palm.app.photos",
		"com.quickoffice.webos", "com.quickoffice.ar"],

	run: function (future) {
		if (!Acl.enforce(this, future)) { return; }
		var self = this, args = this.controller.args || {};
		if (!args.localPath) {
			future.setException({ returnValue: false, errorCode: "MISSING_ARGS",
				detail: "need localPath" });
			return;
		}
		var folderId = args.folderId || args.path || "0";
		var name = args.name || args.localPath.split("/").pop();
		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; }
			catch (e) { future.setException(e); return; }
			var renewed = null;
			var call = BoxApi.uploadFile(creds, folderId, args.localPath, name, function (nc) { renewed = nc; });
			call.then(self, function () {
				var data, meta;
				try { data = call.result; }
				catch (e2) { future.setException(e2); return; }
				meta = (data.entries && data.entries[0]) || {};
				if (renewed && args.accountId) { AccountCreds.save(args.accountId, renewed); }
				future.result = { returnValue: true, renewedCredentials: renewed,
					name: meta.name, id: meta.id, size: meta.size };
			});
		});
	}
};
