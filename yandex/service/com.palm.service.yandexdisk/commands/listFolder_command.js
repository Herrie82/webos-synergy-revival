/*global YandexApi, AccountCreds, Acl, console */
/* listFolder - browse a Yandex Disk folder. args: { accountId | credentials, path }
 * Returns a normalized entry list a file-picker app can render.
 * Yandex Disk uses a string path; "", "/", "disk:/" all mean the account root. Each
 * entry's `path` is a real Disk locator (e.g. "disk:/Documents/foo.docx") the consumer
 * hands straight back as the next folder path (browse) or file path (download).
 */
function ListFolderCommandAssistant() {}

ListFolderCommandAssistant.prototype = {
	// new consumers + QuickOffice (rerouted off its dead MX proxy onto this service)
	allowedAppIds: ["com.palm.app.yandexdisk-files", "com.palm.app.photos",
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
			var call = YandexApi.listFolder(creds, args.path || "", function (nc) { renewed = nc; });
			call.then(self, function () {
				var data;
				try { data = call.result; }
				catch (e2) { future.setException(e2); return; }
				if (renewed && args.accountId) { AccountCreds.save(args.accountId, renewed); }
				var items = (data._embedded && data._embedded.items) || [];
				future.result = {
					returnValue: true,
					renewedCredentials: renewed,   // caller must persist if non-null
					entries: items.map(function (e) {
						return { type: (e.type === "dir" ? "folder" : (e.mime_type || "file")),
							name: e.name, path: e.path, size: e.size, modified: e.modified };
					})
				};
			});
		});
	}
};
