// Google Chat account custom-validator UI (webOS Synergy / Accounts customUI).
//
// Loaded as a cross-app IFRAME by the Accounts framework. Enyo 0.10 app that returns
// the account via enyo.CrossAppResult.sendResult({returnValue, username, credentials,
// config, template, templateId}); the framework then calls createAccount and the
// MESSAGING/IM capability's onEnabled hands off to imlibpurpletransport, which logs in
// via prpl-googlechat (EionRobb/purple-googlechat).
//
// --- WHY A CUSTOM UI + WHY COOKIES -------------------------------------------
// The stock 2011 imaccountvalidator rejects our templateId, so (like the other IM
// connectors) we use a customUI. Google Chat has no usable username/password or OAuth
// browser flow the legacy webview can drive; purple-googlechat authenticates with FIVE
// browser cookies (COMPASS, SSID, SID, OSID, HSID) that the user extracts after signing
// in to chat.google.com. See:  https://github.com/EionRobb/purple-googlechat#Authentication
//
// --- HOW THE COOKIES REACH THE PRPL ------------------------------------------
// purple-googlechat registers these as protocol string options: COMPASS_token, SSID_token,
// SID_token, OSID_token, HSID_token. imlibpurpletransport's Util::createPurpleAccount walks
// the prpl's protocol_options and, for each key present in the account `config`, calls
// purple_account_set_string(). So we return the five cookies in `config` under those exact
// keys and the prpl picks them up on connect. `username` is the account email (display /
// identity only); the credential password is an unused non-empty sentinel (imlibpurple
// rejects an empty password before login).

enyo.kind({
    name: "Validator",
    kind: enyo.VFlexBox,
    className: "enyo-bg",

    COOKIES: [
        { key: "COMPASS_token", label: "COMPASS COOKIE" },
        { key: "SSID_token",    label: "SSID COOKIE" },
        { key: "SID_token",     label: "SID COOKIE" },
        { key: "OSID_token",    label: "OSID COOKIE" },
        { key: "HSID_token",    label: "HSID COOKIE" }
    ],

    components: [
        { kind: "Toolbar", className: "enyo-toolbar-light accounts-header", pack: "center", components: [
            { kind: "Image", src: "images/header-icon.png" },
            { kind: "Control", name: "title", content: "Sign In"}
        ]},
        { className: "accounts-header-shadow" },
        { kind: "Scroller", flex: 1, components: [
            { name: "box", className: "box-center", components: [
                { kind: "RowGroup", caption: "EMAIL ADDRESS", className: "accounts-group", components: [
                    { kind: "Input", name: "username", hint: "you@gmail.com", spellcheck: false,
                      autocorrect: false, autoWordComplete: false, autoCapitalize: "lowercase", oninput: "validateInput" }
                ]},
                { className: "accounts-body-text", style: "padding: 12px 16px; line-height: 1.4;", allowHtml: true,
                  content: "Sign in to <b>chat.google.com</b> in a private/incognito window, then paste the five cookie values below. See the project notes for how to extract them." }
                // cookie RowGroups are appended in create()
            ]}
        ]},
        { className: "accounts-footer-shadow" },
        { kind: "Toolbar", className: "enyo-toolbar-light", components: [
            { kind: "Button", name: "cancelButton", caption: "Cancel", className: "accounts-toolbar-btn", onclick: "cancel" },
            { kind: "Button", name: "removeButton", caption: "Remove Account", showing: false, className: "accounts-toolbar-btn", onclick: "confirmRemove" }
        ]},
        { kind: "Dialog", name: "confirmDialog", modal: true, scrim: true, components: [
            { className: "accounts-body-text", style: "padding: 16px; line-height: 1.4;",
              content: "Remove this account? Its messages will be deleted from this device." },
            { kind: "HFlexBox", style: "padding: 8px 12px 12px;", components: [
                { kind: "Button", flex: 1, caption: "Cancel", onclick: "closeConfirm" },
                { kind: "Button", flex: 1, name: "confirmRemoveBtn", caption: "Remove", className: "enyo-button-negative", onclick: "doRemove" }
            ]}
        ]},
        { kind: "PalmService", name: "acctService", service: "palm://com.palm.service.accounts/", onSuccess: "removeDone", onFailure: "removeDone" },
        { kind: "CrossAppResult" }
    ],

    create: function() {
        this.inherited(arguments);
        // Build the five cookie inputs + the Sign In button dynamically.
        this._inputs = {};
        for (var i = 0; i < this.COOKIES.length; i++) {
            var c = this.COOKIES[i];
            var rg = this.$.box.createComponent(
                { kind: "RowGroup", caption: c.label, className: "accounts-group" }, { owner: this });
            var inp = rg.createComponent(
                { kind: "Input", name: c.key, hint: c.key, spellcheck: false, autocorrect: false,
                  autoWordComplete: false, autoCapitalize: "lowercase", oninput: "validateInput" }, { owner: this });
            this._inputs[c.key] = inp;
        }
        this.$.box.createComponent(
            { kind: "ActivityButton", name: "signInButton", caption: "Sign In", disabled: true, active: false,
              className: "enyo-button-dark accounts-btn", onclick: "performSignIn" }, { owner: this });
        this.render();
        this.handleLaunch(enyo.windowParams || {});
    },

    handleLaunch: function(params) {
        this.params = params || {};
        this.template = null;
        if (params.template && params.template.templateId === "com.palm.googlechat") {
            this.template = params.template;
        } else if (params.allTemplates) {
            for (var i = 0; i < params.allTemplates.length; i++) {
                if (params.allTemplates[i].templateId === "com.palm.googlechat") { this.template = params.allTemplates[i]; break; }
            }
        }
        // Re-auth of an existing account also offers Remove (this flow bypasses the framework
        // account-detail view, the only other place with a Remove button).
        this.accountId = (params.account && (params.account._id || params.account.id)) || params.accountId || null;
        if (this.accountId) { this.$.removeButton.show(); }
        if (params.account && params.account.username) {
            this.$.username.setValue(params.account.username);
            this.$.username.setDisabled(true);
        }
        this.validateInput();
    },

    trim: function(v) { return (v || "").replace(/^\s+|\s+$/g, ""); },

    validateInput: function() {
        var ok = this.trim(this.$.username.getValue()).length > 0;
        for (var k in this._inputs) { if (!this.trim(this._inputs[k].getValue())) { ok = false; } }
        this.$.signInButton.setDisabled(!ok);
    },

    performSignIn: function() {
        var user = this.trim(this.$.username.getValue());
        var config = {};
        for (var i = 0; i < this.COOKIES.length; i++) {
            var k = this.COOKIES[i].key;
            config[k] = this.trim(this._inputs[k].getValue());
            if (!user || !config[k]) { return; }
        }
        this.$.signInButton.setActive(true);
        this.$.signInButton.setDisabled(true);
        var result = {
            returnValue: true,
            username: user,
            alias: user,
            credentials: { common: { password: "cookie-auth" } },
            config: config,   // keys match purple-googlechat's protocol string options
            template: this.template || { templateId: "com.palm.googlechat" },
            templateId: "com.palm.googlechat"
        };
        this.$.crossAppResult.sendResult(result);
    },

    confirmRemove: function() {
        this.$.confirmRemoveBtn.setDisabled(false);
        this.$.confirmDialog.openAtCenter();
    },
    closeConfirm: function() {
        this.$.confirmDialog.close();
    },
    doRemove: function() {
        this.$.confirmRemoveBtn.setDisabled(true);
        if (!this.accountId) { this.closeConfirm(); return; }
        this.$.acctService.call({ accountId: this.accountId }, { method: "deleteAccount" });
    },
    // deleteAccount can return returnValue:false + "Account has been deleted" even on
    // success, so do not branch on it - the account is gone either way; close + exit.
    removeDone: function() {
        this.$.confirmDialog.close();
        this.$.crossAppResult.sendResult({ returnValue: false });
    },
    cancel: function() {
        this.$.crossAppResult.sendResult({ returnValue: false });
    }
});
