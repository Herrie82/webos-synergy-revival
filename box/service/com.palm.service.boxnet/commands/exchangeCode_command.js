/*global OAuth2, BoxApi, console */
/* exchangeCode - the account VALIDATOR. Called by com.palm.service.accounts (via the
 * customUI auth webview) with the ?code=... captured from the OAuth2 redirect.
 * Returns credentials in the shape the account DB stores and BoxApi later reads,
 * PLUS a username: accounts/handlers/create.js does Assert.require(args.username) and
 * refuses to create the account without one, so we fetch the Dropbox email here.
 */
function ExchangeCodeCommandAssistant() {}

ExchangeCodeCommandAssistant.prototype = {
	run: function (future) {
		var args = this.controller.args;
		if (!args.code) {
			future.setException({ returnValue: false, errorCode: "MISSING_CODE" });
			return;
		}
		// args.codeVerifier was returned by getAuthorizeUrl and carried through the auth
		// webview; the generating service process is usually gone by now, so this is the
		// authoritative PKCE verifier (in-memory OAuth2._verifier is only a fallback).
		// Do NOT future.nest(ex): nesting resolves `future` with OAuth2's RAW token result
		// ({accessToken,...}) the moment ex completes, and the command framework sends that
		// before the .then below can wrap it - so Accounts gets no `credentials` and stores
		// nothing. Instead resolve `future` ourselves, only with the wrapped shape.
		var ex = OAuth2.exchangeCode(args.code, args.codeVerifier);
		ex.then(this, function () {
			var t;
			try { t = ex.result; }               // throws if ex carried an exception
			catch (e) { future.setException(e); return; }
			var common = {
				accessToken:  t.accessToken,
				refreshToken: t.refreshToken,
				expiresAt:    Date.now() + (t.expiresIn * 1000)
			};
			// Fetch the account identity (email) for `username`. Tolerate a failure here
			// (still create the account with a fallback) - we already have valid tokens.
			var info = BoxApi.getAccountInfo(common);
			info.then(this, function () {
				var me = {};
				try { me = info.result || {}; } catch (e2) { me = {}; }
				future.result = {
					returnValue: true,
					username:    me.login || "Box",
					alias:       me.name || undefined,
					credentials: { common: common }
				};
			});
		});
	}
};
