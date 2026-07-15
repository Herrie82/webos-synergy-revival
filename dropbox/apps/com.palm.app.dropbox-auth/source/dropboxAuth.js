/*global enyo, console, window */
/*
 * DropboxAuth - customUI account validator for the Dropbox Synergy connector.
 *
 * MIRRORS THE TEAMS PATTERN (com.palm.app.teams/source/validator.js). The legacy
 * webOS system webview is WebKit ~2009 on OpenSSL 0.9.8k and CANNOT render the
 * Dropbox OAuth consent page (no TLS 1.2/1.3, modern JS). So this app does NO
 * HTTPS itself. Instead:
 *   1. it launches Atlas ("simple" mode = WPE + modern OpenSSL/TLS 1.3) at the
 *      Dropbox authorize URL;
 *   2. Atlas renders the login, intercepts navigation to REDIRECT (our
 *      oauthRedirectPrefix) and writes the captured ?code=... URL into a
 *      com.palm.systemservice preference (oauthResultKey) - its BrowserApp.js
 *      checkOAuthRedirect hook, same channel Teams uses;
 *   3. we POLL getPreferences for that key (subscribe-push proved unreliable on
 *      device - see Teams notes) until the value carries "code=";
 *   4. we close the Atlas card, then hand the code to com.palm.service.dropbox
 *      /exchangeCode, which does the code->token exchange over the modern curl
 *      (node itself is 0.9.8k);
 *   5. we return { returnValue, credentials, template } to Accounts via
 *      enyo.CrossAppResult.sendResult(). Empty {} = cancelled.
 */

enyo.kind({
	name: "DropboxService",
	kind: "PalmService",
	service: "palm://com.palm.service.dropbox/"
});

enyo.kind({
	name: "DropboxAuth",
	kind: enyo.VFlexBox,

	// Must match Config.REDIRECT_URI in the service, and the systemservice key
	// Atlas writes the captured redirect into.
	redirectPrefix: "http://localhost/dropbox/oauth2callback",
	oauthResultKey: "x_dropbox_oauth_result",

	components: [
		{ kind: "Toolbar", className: "enyo-toolbar-light accounts-header", pack: "center", components: [
			{ kind: "Control", name: "title", content: "Dropbox" }
		]},
		{ name: "svc",        kind: "DropboxService", onFailure: "svcFailure" },
		{ name: "prefsGet",   kind: "PalmService", service: "palm://com.palm.systemservice/",
			method: "getPreferences", onSuccess: "gotOAuthResult", onFailure: "pollError" },
		{ name: "prefsSet",   kind: "PalmService", service: "palm://com.palm.systemservice/",
			method: "setPreferences" },
		{ name: "appLaunch",  kind: "PalmService", service: "palm://com.palm.applicationManager/",
			method: "launch", onFailure: "atlasLaunchFailed" },
		{ name: "appRunning", kind: "PalmService", service: "palm://com.palm.applicationManager/",
			method: "running", onSuccess: "gotRunningApps", onFailure: "gotRunningApps" },
		{ name: "appRunningPre", kind: "PalmService", service: "palm://com.palm.applicationManager/",
			method: "running", onSuccess: "atlasClosedThenLaunch", onFailure: "atlasClosedThenLaunch" },
		{ name: "appClose",   kind: "PalmService", service: "palm://com.palm.applicationManager/",
			method: "close" },
		{ kind: "Scroller", flex: 1, components: [
			{ className: "box-center", components: [
				{ name: "status", className: "accounts-body-text", style: "padding:16px; line-height:1.4;",
					content: "Tap Sign In to open the Dropbox sign-in page. After you approve access, you'll be returned here automatically." }
			]}
		]},
		{ kind: "Toolbar", className: "enyo-toolbar-light", components: [
			{ name: "signInButton", kind: "Button", caption: "Sign In", className: "enyo-button-dark accounts-btn", onclick: "performSignIn" },
			{ kind: "Button", caption: "Cancel", className: "accounts-toolbar-btn", onclick: "cancel" }
		]},
		{ name: "xresult", kind: "enyo.CrossAppResult" }
	],

	create: function () {
		this.inherited(arguments);
		this.done = false;
		this.params = enyo.windowParams || {};
		this.log("dropbox-auth: launch params " + enyo.json.stringify(this.params));
	},

	setStatus: function (t) { this.$.status.setContent(t); },

	// Step 1-3: get the authorize URL from the service, launch Atlas, start polling.
	performSignIn: function () {
		if (this.done) { return; }
		this.$.signInButton.setDisabled(true);
		this.setStatus("Opening Dropbox sign-in…");
		this.$.svc.call({ state: "dropbox" }, {
			method: "getAuthorizeUrl",
			onSuccess: "launchAtlas",
			onFailure: "svcFailure"
		});
	},

	launchAtlas: function (inSender, inResponse) {
		if (!inResponse || !inResponse.url) { this.svcFailure(inSender, inResponse); return; }
		// Clear any stale captured result so a previous add can't be replayed.
		var clear = {}; clear[this.oauthResultKey] = "";
		this.$.prefsSet.call(clear);

		this.oauthDone = false;
		this._authUrl = inResponse.url;
		// Hold the PKCE verifier here across the whole web login: the service that made it
		// gets idle-killed during sign-in, so exchangeCode must be given it explicitly.
		this._codeVerifier = inResponse.codeVerifier;
		// Atlas MUST cold-launch. An already-running Atlas card (from prior browsing or a
		// previous add attempt) only comes forward on relaunch WITHOUT re-navigating to our
		// URL - Atlas's documented "reused simple card does nothing" limitation - so the
		// Dropbox redirect is never captured and the pref stays empty (=> "credentials
		// incorrect"). Close any running Atlas first, then launch fresh.
		this.log("dropbox-auth: probing for a running Atlas to close before launch");
		this.$.appRunningPre.call({});
	},

	// Close any pre-existing Atlas card, then cold-launch a fresh one. Runs whether or not
	// Atlas was up (running-probe failure also routes here -> apps=[] -> immediate launch).
	atlasClosedThenLaunch: function (inSender, resp) {
		var apps = (resp && resp.running) || [];
		var closed = false;
		for (var i = 0; i < apps.length; i++) {
			if (apps[i].id === "org.webosports.app.atlas" && apps[i].processid) {
				this.log("dropbox-auth: closing stale Atlas pid " + apps[i].processid);
				this.$.appClose.call({ processId: apps[i].processid });
				closed = true;
			}
		}
		// Let BrowserServer tear the old card down before the fresh launch, else the new
		// simple card can collide with the dying one. No wait needed if nothing was open.
		var self = this;
		window.setTimeout(function () { self.doLaunchAtlas(); }, closed ? 1300 : 0);
	},

	doLaunchAtlas: function () {
		if (this.done) { return; }
		this.log("dropbox-auth: launching Atlas simple-mode (cold)");
		this.$.appLaunch.call({
			id: "org.webosports.app.atlas",
			params: {
				mode: "simple",
				url: this._authUrl,
				oauthRedirectPrefix: this.redirectPrefix,
				oauthResultKey: this.oauthResultKey
			}
		});
		// Poll systemservice for the captured redirect (subscribe-push unreliable).
		this._pollCount = 0;
		this.stopPoll();
		var self = this;
		this._poll = window.setInterval(function () { self.pollResult(); }, 1500);
	},

	pollResult: function () {
		if (this.oauthDone || this.done) { this.stopPoll(); return; }
		this._pollCount = (this._pollCount || 0) + 1;
		if (this._pollCount > 160) {   // ~4 min
			this.stopPoll();
			this.$.signInButton.setDisabled(false);
			this.setStatus("Sign-in timed out — please try again.");
			return;
		}
		this.$.prefsGet.call({ keys: [this.oauthResultKey] });
	},

	stopPoll: function () {
		if (this._poll) { window.clearInterval(this._poll); this._poll = null; }
	},

	// getPreferences returns values at the TOP LEVEL (resp[key]), NOT under
	// resp.preferences - reading resp.preferences[key] is the "spins forever" bug.
	gotOAuthResult: function (inSender, resp) {
		if (this.oauthDone || this.done) { return; }
		var url = resp && resp[this.oauthResultKey];
		if (!url || url.indexOf("code=") < 0) { return; }   // empty/cleared or not captured yet
		this.oauthDone = true;
		this.stopPoll();
		// Consume the one-time code so a later add can't replay it.
		var clear = {}; clear[this.oauthResultKey] = "";
		this.$.prefsSet.call(clear);

		var err  = this.queryParam(url, "error");
		if (err) { this.finish({ returnValue: false, errorCode: "OAUTH_DENIED", detail: err }); return; }
		this.capturedCode = this.queryParam(url, "code");
		// Close the Atlas card, then exchange (in gotRunningApps).
		this.$.appRunning.call({});
	},

	// Close the Atlas sign-in card by pid (a card can't close itself), then exchange.
	gotRunningApps: function (inSender, resp) {
		var apps = (resp && resp.running) || [];
		for (var i = 0; i < apps.length; i++) {
			if (apps[i].id === "org.webosports.app.atlas" && apps[i].processid) {
				this.$.appClose.call({ processId: apps[i].processid });
			}
		}
		this.exchange(this.capturedCode);
	},

	// Step 4: code -> tokens via the service (which uses the modern curl).
	exchange: function (code) {
		if (!code) { this.finish({ returnValue: false, errorCode: "NO_CODE" }); return; }
		this.setStatus("Signing in…");
		this.$.svc.call({ code: code, codeVerifier: this._codeVerifier }, {
			method: "exchangeCode",
			onSuccess: "exchangeSuccess",
			onFailure: "exchangeFailure"
		});
	},

	// Step 5: return credentials to Accounts (tag with template on create, like Skype/Teams).
	exchangeSuccess: function (inSender, inResponse) {
		if (this.params && this.params.template) {
			inResponse.templateId = this.params.template.templateId;
			inResponse.template   = this.params.template;
		}
		this.finish(inResponse);
	},

	exchangeFailure: function (inSender, inResponse) {
		this.finish({ returnValue: false, errorCode: "EXCHANGE_FAILED", detail: inResponse });
	},

	atlasLaunchFailed: function (inSender, inResponse) {
		this.stopPoll();
		this.finish({ returnValue: false, errorCode: "ATLAS_LAUNCH_FAILED", detail: inResponse });
	},

	pollError: function () { /* transient; keep polling until timeout */ },

	svcFailure: function (inSender, inResponse) {
		if (this.done) { return; }
		this.finish({ returnValue: false, errorCode: "SERVICE_UNAVAILABLE", detail: inResponse });
	},

	cancel: function () {
		if (this.done) { return; }
		this.stopPoll();
		this.finish({});   // empty result => cancelled
	},

	finish: function (result) {
		this.done = true;
		this.stopPoll();
		this.log("dropbox-auth: sending result " + enyo.json.stringify(result));
		this.$.xresult.sendResult(result);
	},

	// --- helpers ---------------------------------------------------------------
	queryParam: function (url, key) {
		var m = url.match(new RegExp("[?&]" + key + "=([^&#]*)"));
		return m ? decodeURIComponent(m[1].replace(/\+/g, " ")) : null;
	}
});
