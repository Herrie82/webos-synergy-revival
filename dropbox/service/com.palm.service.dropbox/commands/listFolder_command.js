/*global DropboxApi, AccountCreds, Acl, console */
/* listFolder - browse a Dropbox folder. args: { accountId | credentials, path }
 * Returns a normalized entry list a file-picker app can render.
 * Dropbox uses a string path, "" is the account root (NOT a folder id).
 */
function ListFolderCommandAssistant() {}

ListFolderCommandAssistant.prototype = {
	// new consumers + QuickOffice (rerouted off its dead MX proxy onto this service)
	allowedAppIds: ["com.palm.app.dropbox-files", "com.palm.app.photos",
		"com.quickoffice.webos", "com.quickoffice.ar"],

	run: function (future) {
		if (!Acl.enforce(this, future)) { return; }
		var self = this, args = this.controller.args || {};
		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; }
			catch (e) { future.setException(e); return; }
			var renewed = null;
			var call = DropboxApi.listFolder(creds, args.path || "", function (nc) { renewed = nc; });
			call.then(self, function () {
				var data;
				try { data = call.result; }
				catch (e2) { future.setException(e2); return; }
				if (renewed && args.accountId) { AccountCreds.save(args.accountId, renewed); }
				future.result = {
					returnValue: true,
					renewedCredentials: renewed,   // caller must persist if non-null
					entries: (data.entries || []).map(function (e) {
						return { id: e.id, type: e[".tag"], name: e.name,
							size: e.size, modified: e.server_modified, path: e.path_lower };
					})
				};
			});
		});
	}
};
