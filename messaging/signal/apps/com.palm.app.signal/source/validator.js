// Signal account custom-validator UI (webOS Synergy / Accounts customUI).
//
// Loaded as a cross-app IFRAME by the Accounts framework (entry-add.js ->
// Accounts.crossAppUI -> CrossAppUI). Enyo 0.10 app that returns the account via
// enyo.CrossAppResult.sendResult({returnValue, username, credentials, config,
// template, templateId}); the framework then calls createAccount and the
// MESSAGING/IM capability's onEnabled hands off to imlibpurpletransport, which
// would log in via prpl-hehoe-signal (hoehermann/purple-signal).
//
// --- BACKEND (now built) -----------------------------------------------------
// purple-signal is NOT a self-contained C plugin: it embeds a Java VM in-process
// (JNI_CreateJavaVM) and drives signal-cli (Java), whose crypto is the Rust
// libsignal. Both were cross-compiled for webOS ARMv7 (a softfp OpenJDK 11 via
// build-jvm.sh; libsignal_jni + libzkgroup via build-libsignal.sh) and are deployed
// by deploy-signal.sh. On-device end-to-end testing is the remaining validation
// step. See ../../BUILD-LOG.md for the full build.
//
// --- AUTH MODEL --------------------------------------------------------------
// Signal identifies an account by PHONE NUMBER (E.164, e.g. +15551234567). Real
// registration requires either (a) a fresh registration with an SMS/voice code +
// captcha token, or (b) linking as a secondary device by scanning a QR from an
// existing phone. This scene collects the phone number (like Telegram) + points the
// prpl at the deployed signal-cli jars (signal-cli-lib-dir); the code/link handshake
// is driven during connect from the Messaging app.

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
                  content: "After you tap <b>Sign In</b>, finish linking from the <b>Messaging</b> app (registration code or device-link). Signal runs a bundled Java backend, so the first connect is slow on this device." },
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
            // Point the prpl at the deployed signal-cli jars (Util::createPurpleAccount forwards
            // config keys matching the prpl's protocol options -> purple_account_set_string).
            config: { "signal-cli-lib-dir": "/media/cryptofs/apps/usr/palm/applications/com.palm.app.teams/backend/signal-cli/lib" },
            template: this.template || { templateId: "com.palm.signal" },
            templateId: "com.palm.signal"
        };
        this.$.crossAppResult.sendResult(result);
    },

    cancel: function() {
        this.$.crossAppResult.sendResult({ returnValue: false });
    }
});
