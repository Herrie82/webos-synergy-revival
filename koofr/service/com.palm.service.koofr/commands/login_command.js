/*global Adapter, Config, console */
/* login - the account VALIDATOR for Koofr. The koofr-auth customUI collects the account EMAIL and
 * an APP PASSWORD (generated at app.koofr.net -> Preferences -> Password) and calls this command,
 * which VALIDATES them (GET /user) and resolves the user's PRIMARY mount id, then returns
 * credentials in the shape Accounts stores and the Adapter reads:
 *   { returnValue, username, credentials:{ common:{ accessToken(=app password), email, mountId } } }
 * The app password is stored but only ever sent as the HTTP Basic secret.
 */
function LoginCommandAssistant() {}

LoginCommandAssistant.prototype = {
	run: function (future) {
		var args = this.controller.args || {};
		var email = args.email || args.username;
		var appPassword = args.appPassword || args.password;
		if (!email || !appPassword) {
			future.setException({ returnValue: false, errorCode: "MISSING_CREDENTIALS",
				detail: "need email and app password" });
			return;
		}
		var creds = { accessToken: appPassword, email: email };
		// Validate the Basic credentials + fetch identity.
		var info = Adapter.getAccountInfo(creds);
		info.then(this, function () {
			var u = {};
			try { u = (info.result && info.result.user) || {}; }
			catch (e) {
				future.setException({ returnValue: false, errorCode: "KOOFR_AUTH_FAILED",
					detail: "wrong email or app password" });
				return;
			}
			// Resolve the primary mount so file ops have a mountId without another round-trip.
			var mf = Adapter.resolveMount(creds);
			mf.then(this, function () {
				try { creds.mountId = mf.result; }
				catch (e2) { /* tolerate - the adapter resolves it lazily on first file op */ }
				future.result = {
					returnValue: true,
					username:    u.emailAddress || email,
					alias:       u.displayName || undefined,
					credentials: { common: creds }
				};
			});
		});
	}
};
