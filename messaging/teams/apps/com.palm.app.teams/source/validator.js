// Microsoft Teams account custom-validator UI (webOS Synergy / Accounts customUI).
//
// This is loaded as a cross-app IFRAME by the Accounts framework (entry-add.js ->
// Accounts.crossAppUI -> CrossAppUI). It must be an Enyo 0.10 app and return the
// validated account to the caller via enyo.CrossAppResult.sendResult(...):
//
//     { returnValue:true, username, credentials, config, template, templateId }
//
// The framework then shows its standard "Create Account" confirmation view and
// calls palm://com.palm.service.accounts/createAccount. On creation the
// MESSAGING/IM capability's onEnabled fires -> imlibpurpletransport logs the
// account in via prpl-teams (libteams). teams_login() sees an EMPTY password
// (no refresh_token) and starts the OAuth2 *device-code* flow, surfacing the
// one-time code + https://microsoft.com/devicelogin link into the Messaging app
// (purple_serv_got_im on the "TeamsLogin" buddy). So the setup UI itself does no
// Microsoft HTTPS -- it only collects the email and creates the account.

enyo.kind({
    name: "Validator",
    kind: enyo.VFlexBox,
    className: "enyo-bg",

    components: [
        { kind: "Toolbar", className: "enyo-toolbar-light accounts-header", pack: "center", components: [
            { kind: "Image", src: "images/header-icon.png" },
            { kind: "Control", name: "title", content: "Microsoft Teams" }
        ]},
        { className: "accounts-header-shadow" },
        // Teams OAuth redirect-capture channel: the browser sign-in path hands the captured
        // redirect URL back through a com.palm.systemservice preference we subscribe to here
        // (Atlas writes it; no custom db8 kind needed). See BrowserApp.js checkOAuthRedirect.
        { name: "sysPrefsGet", kind: "PalmService", service: "palm://com.palm.systemservice/",
          method: "getPreferences", onSuccess: "gotOAuthResult", onFailure: "oauthChannelError" },
        { name: "sysPrefsSet", kind: "PalmService", service: "palm://com.palm.systemservice/",
          method: "setPreferences" },
        { name: "appLaunch", kind: "PalmService", service: "palm://com.palm.applicationManager/",
          method: "launch", onFailure: "atlasLaunchFailed" },
        // Close the Atlas sign-in card once we have the result. A card can't close itself via
        // applicationManager/close, but we (a separate app) can close it by processId — which we
        // look up via applicationManager/running.
        { name: "appRunning", kind: "PalmService", service: "palm://com.palm.applicationManager/",
          method: "running", onSuccess: "gotRunningApps", onFailure: "gotRunningApps" },
        { name: "appClose", kind: "PalmService", service: "palm://com.palm.applicationManager/",
          method: "close" },
        { kind: "Scroller", flex: 1, components: [
            { className: "box-center", components: [
                { kind: "RowGroup", caption: "DISPLAY NAME (OPTIONAL)", className: "accounts-group", components: [
                    { kind: "Input", name: "displayName", hint: "e.g. LuneOS Test", spellcheck: false,
                      autocorrect: false, autoWordComplete: false }
                ]},
                { kind: "RowGroup", caption: "EMAIL ADDRESS", className: "accounts-group", components: [
                    { kind: "Input", name: "username", hint: "you@example.com", spellcheck: false,
                      autocorrect: false, autoCapitalize: "lowercase", autoWordComplete: false,
                      oninput: "validateInput", onkeydown: "checkForEnter" }
                ]},
                { name: "errorBox", kind: "HFlexBox", showing: false, align: "center", className: "error-box", components: [
                    { name: "errorMessage", className: "enyo-text-error", flex: 1 }
                ]},
                { className: "accounts-body-text", style: "padding: 12px 16px; line-height: 1.4;", allowHtml: true,
                  content: "Tap <b>Sign In</b> to open the Microsoft sign-in page in your browser. After you approve, you'll be returned here automatically." },
                { kind: "ActivityButton", name: "signInButton", caption: "Sign In", disabled: true, active: false,
                  className: "enyo-button-dark accounts-btn", onclick: "performBrowserSignIn" },
                { className: "accounts-body-text", style: "padding: 4px 16px 12px; line-height: 1.4; opacity: 0.7;", allowHtml: true,
                  content: "No browser? Use a <b>one-time device code</b> instead — Teams will message it to you in the Messaging app." },
                { kind: "Button", name: "deviceCodeButton", caption: "Use device code instead", disabled: true,
                  className: "accounts-btn", onclick: "performSignIn" }
            ]}
        ]},
        { className: "accounts-footer-shadow" },
        { kind: "Toolbar", className: "enyo-toolbar-light", components: [
            { kind: "Button", name: "cancelButton", caption: "Cancel", className: "accounts-toolbar-btn", onclick: "cancel" }
        ]},
        { kind: "CrossAppResult" }
    ],

    create: function() {
        this.inherited(arguments);
        this.log("teams prefs: params=" + enyo.json.stringify(enyo.windowParams));
        this.handleLaunch(enyo.windowParams || {});
    },

    // Resolve the Teams template out of the launch params and pre-fill the email
    // when we're re-entering an existing (broken-credentials) account.
    handleLaunch: function(params) {
        this.params = params || {};
        this.template = null;
        if (params.template && params.template.templateId === "com.palm.teams") {
            this.template = params.template;
        } else if (params.allTemplates) {
            for (var i = 0; i < params.allTemplates.length; i++) {
                if (params.allTemplates[i].templateId === "com.palm.teams") {
                    this.template = params.allTemplates[i];
                    break;
                }
            }
        }
        if (params.account && params.account.username) {
            this.$.username.setValue(params.account.username);
            this.$.username.setDisabled(true);
            // Re-auth of an existing account: keep its display name (unless it's just the email).
            if (params.account.alias && params.account.alias !== params.account.username) {
                this.$.displayName.setValue(params.account.alias);
            }
        }
        this.validateInput();
    },

    // The display-name field is optional; fall back to the email so the account
    // is never nameless. The Accounts app shows alias on the first line and
    // username (email) on the second.
    getAlias: function(email) {
        var n = (this.$.displayName.getValue() || "").replace(/^\s+|\s+$/g, "");
        return n || email;
    },

    validateInput: function() {
        var v = this.$.username.getValue();
        var empty = !v || v.length === 0;
        this.$.signInButton.setDisabled(empty);
        this.$.deviceCodeButton.setDisabled(empty);
    },

    checkForEnter: function(inSender, e) {
        if (e && e.keyCode === 13 && !this.$.signInButton.getDisabled()) {
            this.$.username.forceBlur();
            this.performSignIn();
        }
    },

    showError: function(msg) {
        this.$.errorMessage.setContent(msg || "");
        if (msg) { this.$.errorBox.show(); } else { this.$.errorBox.hide(); }
    },

    performSignIn: function() {
        var email = (this.$.username.getValue() || "").replace(/^\s+|\s+$/g, "");
        if (!email) { return; }
        this.showError("");
        this.$.signInButton.setActive(true);
        this.$.signInButton.setDisabled(true);

        // Store the "devicecode" sentinel as the password. It MUST be non-empty:
        // imlibpurpletransport (getCredentialsResult) rejects an empty password as
        // "AcctMgr_Credentials_Not_Found" and aborts before ever calling login. Our
        // patched teams_login() treats this sentinel (or empty) as "run the OAuth2
        // device-code flow" instead of as a refresh_token. The code + devicelogin
        // link then arrive as a Messaging chat from the "TeamsLogin" buddy.
        var result = {
            returnValue: true,
            username: email,
            alias: this.getAlias(email),
            credentials: { common: { password: "devicecode" } },
            config: {},
            template: this.template || { templateId: "com.palm.teams" },
            templateId: "com.palm.teams"
        };
        this.log("teams prefs: returning create result for " + email);
        this.$.crossAppResult.sendResult(result);
    },

    // --- Browser sign-in (Atlas simple-mode OAuth redirect-capture) -----------
    //
    // These OAuth constants MUST match the deployed purple-teams plugin flavor so the
    // authorization code we capture is redeemable by its teams_oauth_with_code(). The
    // current device build is the PERSONAL flavor (-DENABLE_TEAMS_PERSONAL): consumer
    // tenant + personal client_id + mt.readwrite scope, v2.0 endpoint (matching the
    // plugin's v2.0 /token exchange). When the work/personal dropdown lands, switch
    // these by the selection. See teams_login.c TEAMS_OAUTH_* and libteams.c tenant.
    OAUTH_TENANT:     "9188040d-6c67-4c5b-b112-36a304b66dad",
    OAUTH_CLIENT_ID:  "8ec6bc83-69c8-4392-8f08-b3c986009232",
    OAUTH_REDIRECT:   "msauth.com.microsoft.teams://auth",
    OAUTH_SCOPE:      "https://mtsvc.fl.teams.microsoft.com/teams.mt.readwrite openid profile offline_access",
    OAUTH_RESULT_KEY: "x_teams_oauth_result",

    buildAuthorizeUrl: function(email) {
        // Personal/MSA accounts REQUIRE the v2.0 protocol: v1 /oauth2/authorize renders the login but
        // fails at token issuance with AADSTS500201 ("unable to issue tokens from this API version for
        // a Microsoft account — use version 2.0"). And v2.0 for this Teams client only accepts the
        // NATIVE redirect msauth.com.microsoft.teams://auth — every web redirect (nativeclient,
        // live.com/oauth20_desktop.srf) gets invalid_request (curl-verified against MS). WPE can't load
        // that custom scheme, so the backend intercepts the post-login navigation to it and hands the
        // code back via msgActionData("oauthRedirect"). teams_oauth_with_code redeems at /oauth2/v2.0/
        // token with the SAME redirect_uri (TEAMS_OAUTH_REDIRECT_URI, personal build = msauth...).
        var u = "https://login.microsoftonline.com/" + encodeURIComponent(this.OAUTH_TENANT) +
            "/oauth2/v2.0/authorize" +
            "?client_id=" + encodeURIComponent(this.OAUTH_CLIENT_ID) +
            "&response_type=code" +
            "&redirect_uri=" + encodeURIComponent(this.OAUTH_REDIRECT) +
            "&scope=" + encodeURIComponent(this.OAUTH_SCOPE);
        // SMOOTH LOGIN: the Accounts app already collected the email, so pass it as login_hint and do NOT
        // force prompt=select_account. select_account shows MS's "pick an account" screen, which IGNORES
        // login_hint and makes the user retype the email. With login_hint alone (and no cached MS session
        // in the fresh WPE webview) MSA pre-fills the address and jumps straight to the password page.
        // Fall back to select_account only when we somehow have no email to hint.
        if (email) {
            u += "&login_hint=" + encodeURIComponent(email);
        } else {
            u += "&prompt=select_account";
        }
        return u;
    },

    performBrowserSignIn: function() {
        var email = (this.$.username.getValue() || "").replace(/^\s+|\s+$/g, "");
        if (!email) { return; }
        this.oauthEmail = email;
        this.oauthDone = false;
        this.showError("");
        this.$.signInButton.setActive(true);
        this.$.signInButton.setDisabled(true);
        this.$.deviceCodeButton.setDisabled(true);

        // 1) Clear any stale result, 2) launch Atlas, 3) POLL for the captured code. We poll rather
        // than rely on getPreferences subscribe-push (which did not deliver the change here); each
        // poll is a one-shot getPreferences -> gotOAuthResult.
        var prefsClear = {}; prefsClear[this.OAUTH_RESULT_KEY] = "";
        this.$.sysPrefsSet.call(prefsClear);

        this.log("teams prefs: launching Atlas browser sign-in for " + email);
        this.$.appLaunch.call({
            id: "org.webosports.app.atlas",
            params: {
                mode: "simple",
                url: this.buildAuthorizeUrl(email),
                oauthRedirectPrefix: this.OAUTH_REDIRECT,
                oauthResultKey: this.OAUTH_RESULT_KEY
            }
        });

        this._oauthPollCount = 0;
        this.stopOAuthPoll();
        var self = this;
        this._oauthPoll = window.setInterval(function () { self.pollOAuthResult(); }, 1500);
    },

    // Poll systemservice for the captured redirect the Atlas card writes. Robust against the
    // getPreferences subscription not pushing changes.
    pollOAuthResult: function() {
        if (this.oauthDone) { this.stopOAuthPoll(); return; }
        this._oauthPollCount = (this._oauthPollCount || 0) + 1;
        if (this._oauthPollCount > 160) {   // ~4 minutes
            this.stopOAuthPoll();
            this.$.signInButton.setActive(false);
            this.validateInput();
            this.showError("Sign-in timed out — please try again.");
            return;
        }
        this.$.sysPrefsGet.call({ keys: [this.OAUTH_RESULT_KEY] });
    },

    stopOAuthPoll: function() {
        if (this._oauthPoll) { window.clearInterval(this._oauthPoll); this._oauthPoll = null; }
    },

    // Fires on every getPreferences update. Ignore the initial/cleared empty value; act
    // only on a captured redirect URL (carries ?code=...). We hand the raw URL to the
    // plugin as a "webauth:" credential — the plugin does the TLS 1.3 token exchange
    // (this legacy webview can't) and persists the resulting refresh_token itself.
    gotOAuthResult: function(inSender, resp) {
        if (this.oauthDone) { return; }
        // systemservice getPreferences returns values at the TOP LEVEL (resp[key]), NOT under a
        // "preferences" object — reading resp.preferences[key] was the "spins forever" bug.
        var url = resp && resp[this.OAUTH_RESULT_KEY];
        if (!url || url.indexOf("code=") < 0) { return; }   // empty/cleared or not-yet-captured
        this.oauthDone = true;
        this.stopOAuthPoll();
        this.oauthCapturedUrl = url;
        this.log("teams prefs: captured OAuth redirect, creating account");
        // Consume the pref so a later account-add can't replay this one-time code.
        var prefsClear = {}; prefsClear[this.OAUTH_RESULT_KEY] = "";
        this.$.sysPrefsSet.call(prefsClear);
        // Close the Atlas sign-in card, then create the account (in gotRunningApps).
        this.$.appRunning.call({});
    },

    // Close every Atlas card (should be just the sign-in one), then finish account creation.
    gotRunningApps: function(inSender, resp) {
        try {
            var list = (resp && resp.running) || [];
            for (var i = 0; i < list.length; i++) {
                var app = list[i];
                if (app && app.id === "org.webosports.app.atlas" && app.processid) {
                    this.log("teams prefs: closing Atlas card processId=" + app.processid);
                    this.$.appClose.call({ processId: String(app.processid) });
                }
            }
        } catch (e) { this.log("teams prefs: close Atlas err " + e); }
        this.finishWithCredential("webauth:" + this.oauthCapturedUrl, this.oauthEmail);
    },

    oauthChannelError: function() {
        // Result channel unavailable — degrade gracefully to the device-code flow.
        if (this.oauthDone) { return; }
        this.log("teams prefs: OAuth result channel error, offer device code");
        this.$.signInButton.setActive(false);
        this.validateInput();
        this.showError("Could not open browser sign-in. Try 'Use device code instead'.");
    },

    atlasLaunchFailed: function(inSender, err) {
        if (this.oauthDone) { return; }
        this.log("teams prefs: Atlas launch failed: " + enyo.json.stringify(err));
        this.$.signInButton.setActive(false);
        this.validateInput();
        this.showError("Browser not available. Use 'Use device code instead'.");
    },

    finishWithCredential: function(password, email) {
        var result = {
            returnValue: true,
            username: email,
            alias: this.getAlias(email),
            credentials: { common: { password: password } },
            config: {},
            template: this.template || { templateId: "com.palm.teams" },
            templateId: "com.palm.teams"
        };
        this.$.crossAppResult.sendResult(result);
    },

    cancel: function() {
        this.stopOAuthPoll();
        // returnValue:false -> Accounts framework returns to the "Add Account" list.
        this.$.crossAppResult.sendResult({ returnValue: false });
    }
});
