/*global PcloudApi, console */
/* checkCredentials - re-validate stored tokens (called by accounts on demand).
 * Hits /userinfo on the account's region host; result:0 means the token still works.
 * pCloud tokens are long-lived and there is no refresh, so there are no renewedCredentials.
 */
function CheckCredentialsCommandAssistant() {}

CheckCredentialsCommandAssistant.prototype = {
	run: function (future) {
		var args = this.controller.args || {};
		var creds = args.credentials && args.credentials.common;
		if (!creds || !creds.accessToken) {
			future.setException({ returnValue: false, errorCode: "401_UNAUTHORIZED" });
			return;
		}
		var call = PcloudApi.getAccountInfo(creds);
		// Resolve `future` ourselves (no nest - nest would leak the raw API result).
		call.then(this, function () {
			var me;
			try { me = call.result; }
			catch (e) { future.setException(e); return; }
			future.result = { returnValue: true, username: me.email, displayName: me.email };
		});
	}
};
