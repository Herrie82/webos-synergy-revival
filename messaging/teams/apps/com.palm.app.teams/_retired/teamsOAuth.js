/*
 * teamsOAuth.js — account-creation orchestration for the Teams Synergy account.
 *
 * IMPORTANT TLS CONSTRAINT: this page runs in the legacy webOS system webview
 * (WebKit ~2009, system OpenSSL 0.9.8 — no TLS 1.2/1.3). It therefore makes
 * *no* HTTPS calls to Microsoft. Every Microsoft endpoint (authorize page AND
 * the code->token exchange) is handled in a modern-TLS context:
 *   - the interactive login + code capture + token exchange run in Atlas
 *     "simple" mode (WPE + OpenSSL 1.1.1w, TLS 1.3), which returns a
 *     refresh_token to us; OR
 *   - the device-code fallback runs entirely inside the libteams plugin
 *     (also modern TLS via ssl-openssl), with this page only relaying the
 *     user_code for display.
 * This page only: launches Atlas, receives the refresh_token, and stores it as
 * the account credential so steady-state transport logins are silent.
 *
 * See TEAMS-SYNERGY-PORT-PLAN.md §9 and memory teams-oauth-atlas-simple.
 */
(function () {
    "use strict";

    // Public constants mirrored from purple-teams teams_login.c
    var CLIENT_ID    = "1fec8e78-bce4-4aaf-ab1b-5451cc387264";
    var REDIRECT_URI = "https://login.microsoftonline.com/common/oauth2/nativeclient";
    var SERVICE_NAME = "type_teams";
    var TEMPLATE_ID  = "com.palm.teams";

    var els = {
        status:     document.getElementById("status"),
        signin:     document.getElementById("signin"),
        cancel:     document.getElementById("cancel"),
        devicecode: document.getElementById("devicecode"),
        usercode:   document.getElementById("usercode")
    };

    // Account context handed to the custom validator UI by the Accounts framework.
    var launchParams = {};
    try {
        if (window.PalmSystem && PalmSystem.launchParams) {
            launchParams = JSON.parse(PalmSystem.launchParams) || {};
        }
    } catch (e) { /* no params in standalone test */ }

    function setStatus(t) { els.status.textContent = t; }

    /* --- minimal LS2 bridge (PalmServiceBridge) ------------------------- */
    function lunaCall(uri, params, onSuccess, onFailure, subscribe) {
        if (!window.PalmServiceBridge) {
            onFailure && onFailure({ errorText: "no PalmServiceBridge (host test)" });
            return null;
        }
        var bridge = new PalmServiceBridge();
        bridge.onservicecallback = function (msg) {
            var r; try { r = JSON.parse(msg); } catch (e) { r = {}; }
            if (r.returnValue === false || r.errorCode) { onFailure && onFailure(r); }
            else { onSuccess && onSuccess(r); }
        };
        var p = params || {};
        if (subscribe) { p.subscribe = true; }
        bridge.call(uri, JSON.stringify(p));
        return bridge;
    }

    /* --- build the Azure AD authorize URL ------------------------------ */
    function buildAuthorizeUrl() {
        var tenant = launchParams.tenant || "organizations";
        return "https://login.microsoftonline.com/" + encodeURIComponent(tenant) +
            "/oauth2/authorize" +
            "?client_id=" + CLIENT_ID +
            "&response_type=code" +
            "&display=popup" +
            "&prompt=select_account" +
            "&amr_values=mfa" +
            "&redirect_uri=" + encodeURIComponent(REDIRECT_URI);
    }

    /* --- SEAM 1: launch Atlas simple mode with redirect capture --------
     * Contract (to be provided by the Atlas simple-mode redirect-capture
     * feature — see plan §9): open `url`, watch for navigation to a URL
     * beginning with `redirectPrefix`, perform the code->token exchange over
     * WPE/TLS1.3, and return { refresh_token, username } to us. Until that
     * Atlas feature exists, fall back to the in-plugin device-code flow.
     */
    function startInteractiveLogin() {
        setStatus("Opening Microsoft sign-in…");
        lunaCall("luna://com.palm.applicationManager/launch", {
            id: "org.webosports.app.atlas",
            params: {
                mode: "simple",
                url: buildAuthorizeUrl(),
                oauthRedirectPrefix: REDIRECT_URI,
                oauthClientId: CLIENT_ID,
                returnService: "com.palm.app.teams"     // where Atlas posts the result
            }
        }, function () {
            // Atlas launched; await its result on the return channel.
            awaitAtlasResult();
        }, function (err) {
            console.log("atlas-simple launch failed: " + JSON.stringify(err));
            startDeviceCodeLogin();                      // fallback
        });
    }

    function awaitAtlasResult() {
        // Subscribe for the captured result Atlas posts back. The concrete
        // channel is defined together with the Atlas redirect-capture feature.
        lunaCall("luna://com.palm.app.teams/oauthResult", {}, function (r) {
            if (r && r.refresh_token) {
                finish(r.refresh_token, r.username || launchParams.username);
            }
        }, function () { /* keep waiting / user may cancel */ }, true);
    }

    /* --- SEAM 2 (fallback): device-code, fully in-plugin ---------------
     * No webview and no app HTTPS: the libteams plugin performs the device
     * flow over ssl-openssl. Creating the account with an empty credential
     * makes teams_login() take the device-code branch; the plugin surfaces
     * the user_code via the login-state record, which we display here.
     */
    function startDeviceCodeLogin() {
        setStatus("Use device code to sign in");
        els.devicecode.classList.remove("hidden");
        // Create the account now with no refresh_token; the transport's first
        // login triggers teams_do_devicecode_login and writes the user_code
        // into imloginstate, which the Accounts UI / this page can display.
        finish("", launchParams.username, /*deviceCode*/ true);
    }

    /* --- store credential + return to Accounts framework --------------- */
    function finish(refreshToken, username, deviceCode) {
        setStatus(deviceCode ? "Finishing setup…" : "Signed in — finishing…");
        // The captured refresh_token is stored as the account credential
        // (password); imlibpurpletransport passes it to libteams which then
        // logs in silently. Return the validated result to the Accounts
        // framework so it creates the com.palm.account (templateId com.palm.teams).
        var result = {
            returnValue: true,
            credentials: { common: { password: refreshToken || "" } },
            username: username || "",
            templateId: TEMPLATE_ID,
            serviceName: SERVICE_NAME
        };
        // The Accounts custom-validator return path: post the result back to the
        // launching Accounts UI. Exact method verified against the framework in
        // Phase 3; structurally this is the validated-credentials handoff.
        if (window.PalmSystem && PalmSystem.serviceReady) {
            try { PalmSystem.serviceReady(JSON.stringify(result)); } catch (e) {}
        }
        console.log("teams oauth result: " + JSON.stringify(result));
        if (window.PalmSystem && PalmSystem.close) { PalmSystem.close(); }
    }

    /* --- wire UI ------------------------------------------------------- */
    els.signin.addEventListener("click", startInteractiveLogin);
    els.cancel.addEventListener("click", function () {
        if (window.PalmSystem && PalmSystem.close) PalmSystem.close();
    });

    // Auto-start: prefer interactive (atlas-simple); it falls back to device code.
    setStatus("Sign in to your Microsoft Teams account");
    els.signin.classList.remove("hidden");
    startInteractiveLogin();
})();
