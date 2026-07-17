// Facebook account custom-validator UI (webOS Synergy / Accounts customUI).
//
// Loaded as a cross-app IFRAME by the Accounts framework (entry-add.js ->
// Accounts.crossAppUI -> CrossAppUI). It is an Enyo 0.10 app that returns the
// account to the caller via enyo.CrossAppResult.sendResult(...):
//
//     { returnValue:true, username, credentials, config, template, templateId }
//
// The framework then calls palm://com.palm.service.accounts/createAccount. On
// creation the MESSAGING/IM capability's onEnabled fires -> imlibpurpletransport
// logs the account in via prpl-facebook (dequis/purple-facebook, id "prpl-facebook").
//
// --- WHY A CUSTOM UI (not the generic checkCredentials validator) ------------
// The stock 2011 imaccountvalidator has a hardcoded template whitelist and rejects
// templateId "com.palm.facebook" with "Invalid templateId in payload" (error 22) ->
// the accounts UI shows "Unknown error" before Facebook is ever contacted. Teams,
// Discord and Telegram all sidestep the stock validator with a customUI; Facebook
// does the same here.
//
// --- AUTHENTICATION ----------------------------------------------------------
// purple-facebook is a plain username/password prpl: the account username is the
// Facebook EMAIL (or phone/username) and the credential is the account PASSWORD.
// fb_api_auth() logs into Facebook's mobile API to obtain a token; there is no
// OAuth browser flow, so a native two-field scene is all the setup app needs.
// We do NOT verify the credentials here (the stock validator can't reach Facebook
// with our templateId); the prpl performs the authoritative login on connect and
// any failure surfaces in the Messaging app.
//
// NOTE: upstream purple-facebook is lightly maintained and Facebook's mobile-login
// endpoint is fragile; accounts with two-factor auth generally cannot log in. This
// UI intentionally keeps the plain email+password path only.

enyo.kind({
    name: "Validator",
    kind: enyo.VFlexBox,
    className: "enyo-bg",

    components: [
        { kind: "Toolbar", className: "enyo-toolbar-light accounts-header", pack: "center", components: [
            { kind: "Image", src: "images/header-icon.png" },
            { kind: "Control", name: "title", content: "Facebook" }
        ]},
        { className: "accounts-header-shadow" },
        { kind: "Scroller", flex: 1, components: [
            { className: "box-center", components: [
                { kind: "RowGroup", caption: "DISPLAY NAME (OPTIONAL)", className: "accounts-group", components: [
                    { kind: "Input", name: "displayName", hint: "e.g. My Facebook", spellcheck: false,
                      autocorrect: false, autoWordComplete: false }
                ]},
                { kind: "RowGroup", caption: "EMAIL ADDRESS", className: "accounts-group", components: [
                    { kind: "Input", name: "username", hint: "you@example.com", spellcheck: false,
                      autocorrect: false, autoWordComplete: false, autoCapitalize: "lowercase",
                      oninput: "validateInput", onkeydown: "checkForEnter" }
                ]},
                { kind: "RowGroup", caption: "PASSWORD", className: "accounts-group", components: [
                    { kind: "Input", name: "password", type: "password", hint: "Facebook password",
                      spellcheck: false, autocorrect: false, autoWordComplete: false, autoCapitalize: "lowercase",
                      oninput: "validateInput", onkeydown: "checkForEnter" }
                ]},
                { name: "errorBox", kind: "HFlexBox", showing: false, align: "center", className: "error-box", components: [
                    { name: "errorMessage", className: "enyo-text-error", flex: 1 }
                ]},
                { className: "accounts-body-text", style: "padding: 12px 16px; line-height: 1.4;", allowHtml: true,
                  content: "Enter the <b>email address</b> (or phone/username) and <b>password</b> for your Facebook account, then tap <b>Sign In</b>." },
                { className: "accounts-body-text", style: "padding: 4px 16px 12px; line-height: 1.4; opacity: 0.7;", allowHtml: true,
                  content: "Accounts protected by <b>two-factor authentication</b> cannot sign in here — Facebook's mobile login rejects them." },
                { kind: "ActivityButton", name: "signInButton", caption: "Sign In", disabled: true, active: false,
                  className: "enyo-button-dark accounts-btn", onclick: "performSignIn" }
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
        this.handleLaunch(enyo.windowParams || {});
    },

    handleLaunch: function(params) {
        this.params = params || {};
        this.template = null;
        if (params.template && params.template.templateId === "com.palm.facebook") {
            this.template = params.template;
        } else if (params.allTemplates) {
            for (var i = 0; i < params.allTemplates.length; i++) {
                if (params.allTemplates[i].templateId === "com.palm.facebook") {
                    this.template = params.allTemplates[i];
                    break;
                }
            }
        }
        // Re-auth of an existing account: lock the username, prompt for the password only.
        if (params.account && params.account.username) {
            this.$.username.setValue(params.account.username);
            this.$.username.setDisabled(true);
            if (params.account.alias && params.account.alias !== params.account.username) {
                this.$.displayName.setValue(params.account.alias);
            }
        }
        this.validateInput();
    },

    getAlias: function(email) {
        var n = (this.$.displayName.getValue() || "").replace(/^\s+|\s+$/g, "");
        return n || email;
    },

    normalizeUser: function(v) {
        return (v || "").replace(/^\s+|\s+$/g, "");
    },

    // Keep validation permissive: a non-empty username plus a non-empty password.
    // Facebook accepts email, phone or username, so we don't force an email regex;
    // the prpl does the authoritative check on connect.
    validateInput: function() {
        var user = this.normalizeUser(this.$.username.getValue());
        var pass = this.$.password.getValue() || "";
        this.$.signInButton.setDisabled(!(user.length > 0 && pass.length > 0));
    },

    checkForEnter: function(inSender, e) {
        if (e && e.keyCode === 13 && !this.$.signInButton.getDisabled()) {
            this.$.username.forceBlur();
            this.$.password.forceBlur();
            this.performSignIn();
        }
    },

    showError: function(msg) {
        this.$.errorMessage.setContent(msg || "");
        if (msg) { this.$.errorBox.show(); } else { this.$.errorBox.hide(); }
    },

    performSignIn: function() {
        var user = this.normalizeUser(this.$.username.getValue());
        var pass = this.$.password.getValue() || "";
        if (!user || !pass) { return; }
        this.showError("");
        this.$.signInButton.setActive(true);
        this.$.signInButton.setDisabled(true);
        var result = {
            returnValue: true,
            username: user,
            alias: this.getAlias(user),
            credentials: { common: { password: pass } },
            config: {},
            template: this.template || { templateId: "com.palm.facebook" },
            templateId: "com.palm.facebook"
        };
        this.$.crossAppResult.sendResult(result);
    },

    cancel: function() {
        this.$.crossAppResult.sendResult({ returnValue: false });
    }
});
