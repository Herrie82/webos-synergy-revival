/*global enyo, console */
/*
 * KoofrAuth - customUI account validator for the Koofr connector. EMAIL + APP PASSWORD: Koofr uses
 * HTTP Basic auth with an app password (not your main password), generated at app.koofr.net ->
 * Preferences -> Password -> App passwords. The user pastes their email + an app password and taps
 * Connect; the service's `login` command validates them (GET /user), resolves the primary mount,
 * and returns the stored credentials to Accounts. No OAuth webview.
 */
enyo.kind({
	name: "KoofrAuth",
	kind: enyo.VFlexBox,

	components: [
		{ kind: "Toolbar", className: "enyo-toolbar-light accounts-header", pack: "center", components: [
			{ kind: "Image", name: "headerIcon", className: "accounts-header-icon", showing: false },
			{ kind: "Control", name: "title", content: "Koofr Account" }
		]},
		{ name: "svc", kind: "PalmService", onFailure: "svcFailure" },
		{ name: "appLaunch", kind: "PalmService", service: "palm://com.palm.applicationManager/", method: "launch" },
		{ kind: "Scroller", flex: 1, components: [
			{ className: "box-center", style: "padding:16px;", components: [
				{ className: "accounts-body-text", style: "line-height:1.5; padding-bottom:8px;",
					content: "Sign in to Koofr with your email and an APP PASSWORD (not your main password)." },
				{ className: "accounts-body-text", style: "line-height:1.5; padding-bottom:10px;",
					content: "Create one on a computer at app.koofr.net → Preferences → Password → App passwords." },
				{ name: "getPwButton", kind: "Button", caption: "Open Koofr password page",
					className: "accounts-toolbar-btn", style: "margin-bottom:10px;", onclick: "openPwPage" },
				{ kind: "Input", name: "emailField", hint: "Koofr email address",
					type: "email", autoCapitalize: "lowercase", spellcheck: false, style: "width:100%;" },
				{ kind: "Input", name: "passwordField", hint: "App password",
					type: "password", spellcheck: false, style: "width:100%; margin-top:8px;" },
				{ name: "status", className: "accounts-body-text", style: "padding-top:10px; color:#b00000;" }
			]}
		]},
		{ kind: "Toolbar", className: "enyo-toolbar-light", components: [
			{ name: "connectButton", kind: "Button", caption: "Connect",
				className: "enyo-button-dark accounts-btn", onclick: "connectTap" },
			{ kind: "Button", caption: "Cancel", className: "accounts-toolbar-btn", onclick: "cancel" }
		]},
		{ name: "xresult", kind: "enyo.CrossAppResult" }
	],

	create: function () {
		this.inherited(arguments);
		this.done = false;
		this.params = enyo.windowParams || {};
		var tmpl = this.params.template || {};
		var addr = (tmpl.validator && tmpl.validator.address) || "";
		this.serviceUri = addr.replace(/login\/*$/, "");
		if (!this.serviceUri && this.params.account && this.params.account.capabilityProviders) {
			var cps = this.params.account.capabilityProviders;
			for (var i = 0; i < cps.length; i++) {
				if (cps[i] && cps[i].implementation) { this.serviceUri = cps[i].implementation; break; }
			}
		}
		if (this.serviceUri && this.serviceUri.charAt(this.serviceUri.length - 1) !== "/") { this.serviceUri += "/"; }
		if (this.serviceUri) { this.$.svc.setService(this.serviceUri); }
		if (tmpl.loc_name) { this.$.title.setContent(tmpl.loc_name); }
		var iconPath = tmpl.icon && (tmpl.icon.loc_48x48 || tmpl.icon.loc_32x32);
		if (iconPath) { this.$.headerIcon.setSrc(iconPath); this.$.headerIcon.setShowing(true); }
		if (this.params.account && this.params.account.username) {
			this.$.emailField.setValue(this.params.account.username);
		}
	},

	openPwPage: function () {
		this.$.appLaunch.call({ id: "com.palm.app.browser",
			params: { target: "https://app.koofr.net/app/admin/preferences/password" } });
	},

	connectTap: function () {
		if (this.done) { return; }
		var email = (this.$.emailField.getValue() || "").replace(/^\s+|\s+$/g, "");
		var appPassword = this.$.passwordField.getValue() || "";
		if (!email || !appPassword) { this.$.status.setContent("Please enter your email and app password."); return; }
		if (!this.serviceUri) { this.finish({ returnValue: false, errorCode: "NO_SERVICE" }); return; }
		this.$.status.setContent("Connecting…");
		this.$.connectButton.setDisabled(true);
		this.$.svc.call({ email: email, appPassword: appPassword },
			{ method: "login", onSuccess: "authSuccess", onFailure: "authFailed" });
	},

	authFailed: function (inSender, inResponse) {
		if (this.done) { return; }
		this.$.connectButton.setDisabled(false);
		this.$.status.setContent("Could not connect — check your email and app password.");
		this.log("koofr-auth: login failed " + enyo.json.stringify(inResponse));
	},

	authSuccess: function (inSender, inResponse) {
		if (this.params && this.params.template) {
			inResponse.templateId = this.params.template.templateId;
			inResponse.template   = this.params.template;
		}
		this.finish(inResponse);
	},

	svcFailure: function (inSender, inResponse) {
		if (this.done) { return; }
		this.$.connectButton.setDisabled(false);
		this.finish({ returnValue: false, errorCode: "SERVICE_UNAVAILABLE", detail: inResponse });
	},

	cancel: function () { if (this.done) { return; } this.finish({}); },

	finish: function (result) {
		this.done = true;
		this.log("koofr-auth: sending result " + enyo.json.stringify(result));
		this.$.xresult.sendResult(result);
	}
});
