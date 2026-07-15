/*global GraphApi, console */
/* checkCredentials - re-validate stored tokens (called by accounts on demand).
 * Hits GET /me; a 200 means the tokens still work.
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
		var call = GraphApi.getAccountInfo(creds, function (nc) { renewed = nc; });
		// Resolve `future` ourselves (no nest - nest would leak the raw API result).
		call.then(this, function () {
			var me;
			try { me = call.result; }
			catch (e) { future.setException(e); return; }
			future.result = { returnValue: true, renewedCredentials: renewed,
				username: me.userPrincipalName || me.mail, displayName: me.displayName };
		});
	}
};
