/*global BoxApi, console */
/* checkCredentials - re-validate stored tokens (called by accounts on demand).
 * Hits GET /users/me; a 200 means the access/refresh tokens still work.
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
		var call = BoxApi.getAccountInfo(creds, { onTokensRenewed: function (nc) { renewed = nc; } });
		future.nest(call);
		call.then(this, function () {
			var me = call.result;
			future.result = { returnValue: true, renewedCredentials: renewed,
				username: me.login, displayName: me.name };
		});
	}
};
