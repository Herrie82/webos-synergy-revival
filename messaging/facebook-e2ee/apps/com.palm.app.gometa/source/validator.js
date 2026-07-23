// Facebook (E2EE) account custom-validator UI (webOS Synergy / Accounts customUI).
//
// Loaded as a cross-app IFRAME by the Accounts framework. Enyo 0.10 app that returns the
// account via enyo.CrossAppResult.sendResult:
//     { returnValue:true, username, credentials, config, template, templateId }
// The framework then calls palm://com.palm.service.accounts/createAccount; the MESSAGING/IM
// capability's onEnabled fires -> imlibpurpletransport logs the account in via the combined
// plugin's Facebook prpl ("prpl-gometa", messagix/mautrix-meta with E2EE).
//
// --- AUTHENTICATION ----------------------------------------------------------
// The account username is the Facebook EMAIL (or phone/username); the credential is the
// account PASSWORD. On connect the prpl drives messagix's MessengerLite/Bloks login: it
// posts the email+password and, if the account has two-factor auth, prompts for the code
// (via purple_request_input). On success it caches the session so later logins are instant.
// Unlike the legacy purple-facebook, TWO-FACTOR ACCOUNTS ARE SUPPORTED here.
//
// We do NOT verify credentials in this UI; the prpl performs the authoritative login on
// connect and any failure surfaces in the Messaging app.

enyo.kind({
    name: "Validator",
    kind: enyo.VFlexBox,
    className: "enyo-bg",

    components: [
        { kind: "Toolbar", className: "enyo-toolbar-light accounts-header", pack: "center", components: [
            { kind: "Image", src: "images/header-icon.png" },
            { kind: "Control", name: "title", content: "Facebook (E2EE)" }
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
                  content: "If your account uses <b>two-factor authentication</b>, you'll be prompted for a code the first time you connect." },
                { kind: "ActivityButton", name: "signInButton", caption: "Sign In", disabled: true, active: false,
                  className: "enyo-button-dark accounts-btn", onclick: "performSignIn" }
            ]}
        ]},
        { className: "accounts-footer-shadow" },
        { name: "removeBox", className: "box-center", showing: false, components: [
            { name: "removeButton", kind: "Button", caption: "Remove Account",
              className: "enyo-button-negative accounts-btn", onclick: "confirmRemove" }
        ]},
        { kind: "Toolbar", className: "enyo-toolbar-light", components: [
            { kind: "Button", name: "cancelButton", caption: "Cancel", className: "accounts-toolbar-btn", onclick: "cancel" }
        ]},
        { kind: "ModalDialog", name: "confirmDialog", lazy: false, caption: "Remove Account", components: [
            { className: "enyo-paragraph", content: "Are you sure you want to remove this account and all associated data from your device? Data from this account will be erased from all applications." },
            { kind: "HFlexBox", components: [
                { kind: "Button", caption: "Cancel", flex: 0.8, className: "enyo-button-light", onclick: "closeConfirm" },
                { kind: "Button", name: "confirmRemoveBtn", caption: "Remove Account", flex: 1, className: "enyo-button-negative", onclick: "doRemove" }
            ]}
        ]},
        { kind: "PalmService", name: "acctService", service: "palm://com.palm.service.accounts/",
          onSuccess: "removeDone", onFailure: "removeDone" },
        { kind: "CrossAppResult" }
    ],

    create: function() {
        this.inherited(arguments);
        this.handleLaunch(enyo.windowParams || {});
    },

    handleLaunch: function(params) {
        this.params = params || {};
        this.template = null;
        if (params.template && params.template.templateId === "com.palm.gometa") {
            this.template = params.template;
        } else if (params.allTemplates) {
            for (var i = 0; i < params.allTemplates.length; i++) {
                if (params.allTemplates[i].templateId === "com.palm.gometa") {
                    this.template = params.allTemplates[i];
                    break;
                }
            }
        }
        // Re-auth of an existing account: lock the username, prompt for the password only, and
        // offer "Remove Account" (this re-auth flow otherwise has no path to delete the account).
        this.accountId = (params.account && (params.account._id || params.account.id)) || params.accountId || null;
        if (params.account && params.account.username) {
            this.$.username.setValue(params.account.username);
            this.$.username.setDisabled(true);
            if (params.account.alias && params.account.alias !== params.account.username) {
                this.$.displayName.setValue(params.account.alias);
            }
            if (this.accountId) {
                this.$.removeBox.show();
            }
        }
        this.validateInput();
    },

    confirmRemove: function() {
        this.$.confirmDialog.openAtCenter();
    },

    closeConfirm: function() {
        this.$.confirmDialog.close();
    },

    doRemove: function() {
        if (!this.accountId) { this.closeConfirm(); return; }
        this.$.acctService.call({ accountId: this.accountId }, { method: "deleteAccount" });
    },

    // deleteAccount returns an odd shape (returnValue:false + "Account has been deleted" even on
    // success), so don't branch on it - the account is gone either way. Close the confirm + the
    // custom UI (sendResult false cancels the edit; the framework returns to the now-empty slot).
    removeDone: function() {
        this.$.confirmDialog.close();
        this.$.crossAppResult.sendResult({ returnValue: false });
    },

    getAlias: function(email) {
        var n = (this.$.displayName.getValue() || "").replace(/^\s+|\s+$/g, "");
        return n || email;
    },

    normalizeUser: function(v) {
        return (v || "").replace(/^\s+|\s+$/g, "");
    },

    // Permissive: non-empty username + non-empty password. Facebook accepts email, phone or
    // username, so no email regex; the prpl does the authoritative check on connect.
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
            template: this.template || { templateId: "com.palm.gometa" },
            templateId: "com.palm.gometa"
        };
        this.$.crossAppResult.sendResult(result);
    },

    cancel: function() {
        this.$.crossAppResult.sendResult({ returnValue: false });
    }
});
