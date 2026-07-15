/*global OAuth2, console */
/* exchangeCode - the account VALIDATOR. Called by com.palm.service.accounts (via the
 * customUI auth webview) with the ?code=... captured from the OAuth2 redirect.
 * Returns credentials in the shape the account DB stores and BoxApi later reads.
 */
function ExchangeCodeCommandAssistant() {}

ExchangeCodeCommandAssistant.prototype = {
	run: function (future) {
		var args = this.controller.args;
		if (!args.code) {
			future.setException({ returnValue: false, errorCode: "MISSING_CODE" });
			return;
		}
		var ex = OAuth2.exchangeCode(args.code);
		future.nest(ex);
		ex.then(this, function () {
			var t = ex.result;
			future.result = {
				returnValue: true,
				credentials: {
					common: {
						accessToken:  t.accessToken,
						refreshToken: t.refreshToken,
						expiresAt:    Date.now() + (t.expiresIn * 1000)
					}
				}
			};
		});
	}
};
