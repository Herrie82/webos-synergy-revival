/*global DriveApi, console */
/* checkCredentials - re-validate stored tokens (called by accounts on demand).
 * Hits GET /about; a 200 means the tokens still work.
 */
function CheckCredentialsCommandAssistant() {}

CheckCredentialsCommandAssistant.prototype = {
	run: function (future) {
		var args = this.controller.args;
		var creds = args.credentials && args.credentials.common;
		if (!creds || !creds.accessToken) {
			future.setException({ returnValue: false, errorCode: "401_UNAUTHORIZED" });
			return;
		}
		var renewed = null;
		var call = DriveApi.getAccountInfo(creds, function (nc) { renewed = nc; });
		// Resolve `future` ourselves (no nest - nest would leak the raw API result).
		call.then(this, function () {
			var u;
			try { u = (call.result && call.result.user) || {}; }
			catch (e) { future.setException(e); return; }
			future.result = { returnValue: true, renewedCredentials: renewed,
				username: u.emailAddress, displayName: u.displayName };
		});
	}
};
