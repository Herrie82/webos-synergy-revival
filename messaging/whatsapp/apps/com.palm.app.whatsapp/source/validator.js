// WhatsApp account custom-validator UI (webOS Synergy / Accounts customUI).
//
// Loaded as a cross-app IFRAME by the Accounts framework. Enyo 0.10 app that returns
// the account via enyo.CrossAppResult.sendResult({returnValue, username, credentials,
// config, template, templateId}); the framework then calls createAccount and the
// MESSAGING/IM capability's onEnabled hands off to imlibpurpletransport, which logs in
// via prpl-hehoe-whatsmeow (hoehermann/purple-gowhatsapp, whatsmeow backend).
//
// --- WHY A CUSTOM UI + HOW LOGIN COMPLETES -----------------------------------
// The stock 2011 imaccountvalidator rejects our templateId, so (like the other IM
// connectors) we use a customUI. WhatsApp multi-device auth is an interactive
// handshake the prpl runs on connect: it either shows a QR code to scan from the phone
// (WhatsApp > Linked Devices > Link a Device) or, with a phone number set, offers an
// 8-character pairing code. Neither exists until the prpl connects, so this scene only
// collects the phone number up front; the QR image / pairing code is surfaced during
// login (getAuthChallenge / request_input) and completed from the Messaging app.
//
// The stored credential password is a non-empty sentinel — imlibpurpletransport rejects
// an empty password before login; whatsmeow persists its own session in the prpl's
// account store after the first successful link.

enyo.kind({
    name: "Validator",
    kind: enyo.VFlexBox,
    className: "enyo-bg",

    components: [
        { kind: "Toolbar", className: "enyo-toolbar-light accounts-header", pack: "center", components: [
            { kind: "Image", src: "images/header-icon.png" },
            { kind: "Control", name: "title", content: "WhatsApp" }
        ]},
        { className: "accounts-header-shadow" },
        { kind: "Scroller", flex: 1, components: [
            { className: "box-center", components: [
                { kind: "RowGroup", caption: "DISPLAY NAME (OPTIONAL)", className: "accounts-group", components: [
                    { kind: "Input", name: "displayName", hint: "e.g. My WhatsApp", spellcheck: false,
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
                  content: "Enter your phone number in <b>international format</b> (with country code, e.g. +15551234567), then tap <b>Sign In</b>." },
                { className: "accounts-body-text", style: "padding: 4px 16px 12px; line-height: 1.4; opacity: 0.7;", allowHtml: true,
                  content: "Finish linking from the <b>Messaging</b> app: on your phone open <b>WhatsApp → Linked Devices → Link a Device</b> and scan the QR code (or enter the pairing code shown)." },
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
        if (params.template && params.template.templateId === "com.palm.whatsapp") {
            this.template = params.template;
        } else if (params.allTemplates) {
            for (var i = 0; i < params.allTemplates.length; i++) {
                if (params.allTemplates[i].templateId === "com.palm.whatsapp") { this.template = params.allTemplates[i]; break; }
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
            credentials: { common: { password: "whatsapp-link-pending" } },
            config: {},
            template: this.template || { templateId: "com.palm.whatsapp" },
            templateId: "com.palm.whatsapp"
        };
        this.$.crossAppResult.sendResult(result);
    },

    cancel: function() {
        this.$.crossAppResult.sendResult({ returnValue: false });
    }
});
