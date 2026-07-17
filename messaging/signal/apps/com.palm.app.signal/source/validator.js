// Signal account custom-validator UI (webOS Synergy / Accounts customUI).
//
// Loaded as a cross-app IFRAME by the Accounts framework (entry-add.js ->
// Accounts.crossAppUI -> CrossAppUI). Enyo 0.10 app that returns the account via
// enyo.CrossAppResult.sendResult({returnValue, username, credentials, config,
// template, templateId}); the framework then calls createAccount and the
// MESSAGING/IM capability's onEnabled hands off to imlibpurpletransport, which
// would log in via prpl-hehoe-signal (hoehermann/purple-signal).
//
// --- STATUS: SCAFFOLD ONLY (plugin not runnable on the TouchPad) -------------
// purple-signal is NOT a self-contained C plugin: it embeds a Java VM in-process
// (JNI_CreateJavaVM) and drives signal-cli (Java), whose crypto is the Rust
// libsignal. webOS 3.0.5 ARMv7 (glibc 2.23) has NO JVM, and no public ARMv7 build
// of libsignal_jni exists. So this UI + template exist for completeness and future
// work, but sign-in cannot currently succeed. See ../../BUILD-LOG.md for the full
// attempt log and the exact walls hit.
//
// --- AUTH MODEL (when/if a backend exists) -----------------------------------
// Signal identifies an account by PHONE NUMBER (E.164, e.g. +15551234567). Real
// registration requires either (a) a fresh registration with an SMS/voice code +
// captcha token, or (b) linking as a secondary device by scanning a QR from an
// existing phone. Neither can complete without the Java/Rust backend, so this
// scene only collects the phone number (like Telegram) and stores a non-empty
// sentinel credential; a future prpl would drive the code/link handshake.

enyo.kind({
    name: "Validator",
    kind: enyo.VFlexBox,
    className: "enyo-bg",

    components: [
        { kind: "Toolbar", className: "enyo-toolbar-light accounts-header", pack: "center", components: [
            { kind: "Image", src: "images/header-icon.png" },
            { kind: "Control", name: "title", content: "Signal" }
        ]},
        { className: "accounts-header-shadow" },
        { kind: "Scroller", flex: 1, components: [
            { className: "box-center", components: [
                { kind: "RowGroup", caption: "DISPLAY NAME (OPTIONAL)", className: "accounts-group", components: [
                    { kind: "Input", name: "displayName", hint: "e.g. My Signal", spellcheck: false,
                      autocorrect: false, autoWordComplete: false }
                ]},
                { kind: "RowGroup", caption: "PHONE NUMBER", className: "accounts-group", components: [
                    { kind: "Input", name: "username", hint: "+15551234567", spellcheck: false,
                      autocorrect: false, autoWordComplete: false, autoCapitalize: "lowercase",
                      oninput: "validateInput", onkeydown: "checkForEnter" }
                ]},
                { name: "errorBox", kind: "HFlexBox", showing: false, align: "center", className: "error-box", components: [
                    { name: "errorMessage", className: "enyo-text-error", flex: 1 }
                ]},
                { className: "accounts-body-text", style: "padding: 12px 16px; line-height: 1.4;", allowHtml: true,
                  content: "Enter your phone number in <b>international format</b> (with country code, e.g. +15551234567)." },
                { className: "accounts-body-text", style: "padding: 4px 16px 12px; line-height: 1.4; opacity: 0.7;", allowHtml: true,
                  content: "<b>Note:</b> Signal support is not yet functional on this device — the protocol backend cannot run here. See the project notes for details." },
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
        if (params.template && params.template.templateId === "com.palm.signal") {
            this.template = params.template;
        } else if (params.allTemplates) {
            for (var i = 0; i < params.allTemplates.length; i++) {
                if (params.allTemplates[i].templateId === "com.palm.signal") {
                    this.template = params.allTemplates[i];
                    break;
                }
            }
        }
        if (params.account && params.account.username) {
            this.$.username.setValue(params.account.username);
            this.$.username.setDisabled(true);
            if (params.account.alias && params.account.alias !== params.account.username) {
                this.$.displayName.setValue(params.account.alias);
            }
        }
        this.validateInput();
    },

    getAlias: function(phone) {
        var n = (this.$.displayName.getValue() || "").replace(/^\s+|\s+$/g, "");
        return n || phone;
    },

    normalizePhone: function(v) {
        v = (v || "").replace(/[^\d+]/g, "");
        if (v.indexOf("+") > 0) { v = "+" + v.replace(/\+/g, ""); }
        return v;
    },

    validateInput: function() {
        var v = this.normalizePhone(this.$.username.getValue());
        this.$.signInButton.setDisabled(!/^\+?\d{6,15}$/.test(v));
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
        var phone = this.normalizePhone(this.$.username.getValue());
        if (!phone) { return; }
        this.showError("");
        this.$.signInButton.setActive(true);
        this.$.signInButton.setDisabled(true);
        var result = {
            returnValue: true,
            username: phone,
            alias: this.getAlias(phone),
            credentials: { common: { password: "signal-link-pending" } },
            config: {},
            template: this.template || { templateId: "com.palm.signal" },
            templateId: "com.palm.signal"
        };
        this.$.crossAppResult.sendResult(result);
    },

    cancel: function() {
        this.$.crossAppResult.sendResult({ returnValue: false });
    }
});
