// Discord account custom-validator UI (webOS Synergy / Accounts customUI).
//
// Loaded as a cross-app IFRAME by the Accounts framework (entry-add.js ->
// Accounts.crossAppUI -> CrossAppUI). Enyo 0.10 app that returns the account via
// enyo.CrossAppResult.sendResult({returnValue, username, credentials, config,
// template, templateId}); the framework then calls createAccount, and on the
// MESSAGING/IM capability's onEnabled imlibpurpletransport logs in via prpl-discord.
//
// --- WHY A CUSTOM UI (not the generic checkCredentials validator) ------------
// The stock 2011 imaccountvalidator has a hardcoded template whitelist and rejects
// templateId "com.palm.discord" with "Invalid templateId in payload" (error 22) ->
// the accounts UI shows "Unknown error" before Discord is ever contacted. Teams and
// Telegram sidestep the stock validator with a customUI; Discord does the same here.
//
// --- HOW WE AUTHENTICATE: LOGIN TOKEN ----------------------------------------
// Discord blocks third-party email/password logins with a captcha, so purple-discord
// password login is unreliable. purple-discord instead supports a user AUTH TOKEN
// (Authorization header, discord_start_socket): purple_account_get_string(account,
// "token"). On this legacy device the imlibpurple config-kind path is disabled, so
// the "token" account option can't be pre-seeded through account config. Instead we
// store the token as the account PASSWORD (the universal credentials path that every
// account uses), and the patched libdiscord.c uses the password as the token when the
// "token" option is empty (see discord-port libdiscord.c login patch). So: user pastes
// their Discord token here -> it becomes the account password -> prpl-discord logs in
// with it directly, no captcha.
//
// Get the token from the Discord WEB client: open Discord in a desktop browser, then
// DevTools (F12) -> Network -> filter "science" or any /api request -> Request Headers
// -> copy the "authorization" value. (Treat it like a password; it grants full access.)
//
// The USERNAME field is just the webOS account key + display alias (token login does
// not use it for authentication); enter your Discord handle or email.

enyo.kind({
    name: "Validator",
    kind: enyo.VFlexBox,
    className: "enyo-bg",

    components: [
        { kind: "Toolbar", className: "enyo-toolbar-light accounts-header", pack: "center", components: [
            { kind: "Image", src: "images/header-icon.png" },
            { kind: "Control", name: "title", content: "Discord" }
        ]},
        { className: "accounts-header-shadow" },
        { kind: "Scroller", flex: 1, components: [
            { className: "box-center", components: [
                { kind: "RowGroup", caption: "USERNAME (Discord handle or email)", className: "accounts-group", components: [
                    { kind: "Input", name: "username", hint: "e.g. myname", spellcheck: false,
                      autocorrect: false, autoWordComplete: false, autoCapitalize: "lowercase",
                      oninput: "validateInput", onkeydown: "checkForEnter" }
                ]},
                { kind: "RowGroup", caption: "AUTH TOKEN (optional — leave blank for QR)", className: "accounts-group", components: [
                    { kind: "Input", name: "token", hint: "leave blank to sign in with a QR code", spellcheck: false,
                      autocorrect: false, autoWordComplete: false, autoCapitalize: "lowercase",
                      oninput: "validateInput", onkeydown: "checkForEnter" }
                ]},
                { name: "errorBox", kind: "HFlexBox", showing: false, align: "center", className: "error-box", components: [
                    { name: "errorMessage", className: "enyo-text-error", flex: 1 }
                ]},
                { className: "accounts-body-text", style: "padding: 12px 16px; line-height: 1.4;", allowHtml: true,
                  content: "<b>Easiest: leave the token blank and tap Sign In.</b> A <b>Logon QR Code</b> chat will appear in the Messaging app with a link — open it (or scan the QR) on your phone's Discord app to approve. No password, no captcha." },
                { className: "accounts-body-text", style: "padding: 4px 16px 12px; line-height: 1.4; opacity: 0.7;", allowHtml: true,
                  content: "Advanced: to skip the phone step, paste your Discord web <b>auth token</b> (DevTools → Network → any request → <b>authorization</b> header). Keep it private — it grants full account access." },
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
        if (params.template && params.template.templateId === "com.palm.discord") {
            this.template = params.template;
        } else if (params.allTemplates) {
            for (var i = 0; i < params.allTemplates.length; i++) {
                if (params.allTemplates[i].templateId === "com.palm.discord") {
                    this.template = params.allTemplates[i];
                    break;
                }
            }
        }
        if (params.account && params.account.username) {
            this.$.username.setValue(params.account.username);
            this.$.username.setDisabled(true);
        }
        this.validateInput();
    },

    getAlias: function(username) {
        var n = (this.$.username.getValue() || "").replace(/^\s+|\s+$/g, "");
        return n || username;
    },

    trim: function(v) { return (v || "").replace(/^\s+|\s+$/g, ""); },

    validateInput: function() {
        // Username is the account key/label; token is OPTIONAL (blank => QR login).
        var user = this.trim(this.$.username.getValue());
        this.$.signInButton.setDisabled(user.length === 0);
    },

    checkForEnter: function(inSender, e) {
        if (e && e.keyCode === 13 && !this.$.signInButton.getDisabled()) {
            this.$.token.forceBlur();
            this.performSignIn();
        }
    },

    showError: function(msg) {
        this.$.errorMessage.setContent(msg || "");
        if (msg) { this.$.errorBox.show(); } else { this.$.errorBox.hide(); }
    },

    performSignIn: function() {
        var user = this.trim(this.$.username.getValue());
        var token = this.trim(this.$.token.getValue());
        if (!user) { return; }
        this.showError("");
        this.$.signInButton.setActive(true);
        this.$.signInButton.setDisabled(true);
        // The account PASSWORD carries the credential (universal imlibpurple path):
        //  - token entered  -> patched libdiscord.c uses it as the auth token (direct login)
        //  - token blank    -> "QRLOGIN" sentinel selects the QR / remote-auth flow; the
        //                       approve-link + QR arrive in a "Logon QR Code" Messaging chat.
        var secret = token ? token : "QRLOGIN";
        var result = {
            returnValue: true,
            username: user,
            alias: this.getAlias(user),
            credentials: { common: { password: secret } },
            config: {},
            template: this.template || { templateId: "com.palm.discord" },
            templateId: "com.palm.discord"
        };
        this.$.crossAppResult.sendResult(result);
    },

    cancel: function() {
        this.$.crossAppResult.sendResult({ returnValue: false });
    }
});
