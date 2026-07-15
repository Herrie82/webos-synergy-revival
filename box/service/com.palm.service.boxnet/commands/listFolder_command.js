/*global BoxApi, console */
/* listFolder - browse a Box folder. args: { credentials, folderId }
 * Returns a normalized entry list a file-picker app can render.
 * folderId "0" is the Box account root.
 */
function ListFolderCommandAssistant() {}

ListFolderCommandAssistant.prototype = {
	allowedAppIds: ["com.palm.app.boxnet-files", "com.palm.app.photos"],  // new consumers

	run: function (future) {
		var args = this.controller.args;
		var creds = args.credentials && args.credentials.common;
		if (!creds || !creds.accessToken) {
			future.setException({ returnValue: false, errorCode: "NO_CREDENTIALS" });
			return;
		}
		var renewed = null;
		var call = BoxApi.listFolder(creds, args.folderId || "0", function (nc) { renewed = nc; });
		future.nest(call);
		call.then(this, function () {
			var data = call.result;
			future.result = {
				returnValue: true,
				renewedCredentials: renewed,   // caller must persist if non-null
				entries: (data.entries || []).map(function (e) {
					return { id: e.id, type: e.type, name: e.name,
						size: e.size, modified: e.modified_at };
				})
			};
		});
	}
};
