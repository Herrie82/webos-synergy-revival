/*jslint sloppy: true, browser: true */
/*global enyo, $L, console, PalmSystem */

/*
 * Google sign-in for the C+DAV connector, MODERN loopback OAuth 2.0.
 *
 * The upstream used Google's out-of-band flow (redirect_uri urn:ietf:wg:oauth:2.0:oob,
 * token read from the page title) which Google shut down in 2022. This uses the loopback
 * redirect flow instead: load the consent page in the WebView, and when Google redirects to
 * http://localhost/gdrive/oauth2callback?code=... (the page fails to load -- expected), read
 * the authorization code out of that URL via the WebView's load events, then exchange it for
 * tokens. The client is the user's own "luneos-location" OAuth client (loopback redirect is
 * already registered). In-app HTTPS to Google works because LunaSysMgr LD_PRELOADs a modern
 * OpenSSL shim for WebKit -- node's own TLS is too old, but the WebView/XHR path is fine.
 */

var GOOGLE = {
	CLIENT_ID:     "1088488468273-26r2gjnmjscukk0usmpa0krmlkm91ioc.apps.googleusercontent.com",
	// Real secret is NOT committed. deploy-cdav.sh injects it from the local client_secret
	// JSON (~/Downloads/client_secret_*.json) at deploy time, matching the gdrive convention.
	// Google treats loopback/installed-app secrets as non-confidential, but we keep it out of git.
	CLIENT_SECRET: "GOCSPX_INJECTED_AT_DEPLOY",
	REDIRECT_URI:  "http://localhost/gdrive/oauth2callback",
	AUTH_URL:      "https://accounts.google.com/o/oauth2/v2/auth",
	TOKEN_URL:     "https://oauth2.googleapis.com/token",
	USERINFO_URL:  "https://www.googleapis.com/oauth2/v2/userinfo",
	SCOPE:         "https://www.googleapis.com/auth/calendar" +
			   " https://www.googleapis.com/auth/carddav" +
			   " https://www.googleapis.com/auth/contacts" +
			   " https://www.googleapis.com/auth/userinfo.email" +
			   " https://www.googleapis.com/auth/userinfo.profile"
};

enyo.kind({
	name: "Main.CrossAppGoogle",
	width: "100%",
	height: "100%",
	kind: "VFlexBox",
	className: "enyo-bg",
	components: [
		{ name: "getAccessToken", kind: "WebService", url: GOOGLE.TOKEN_URL, method: "POST",
			handleAs: "json", onSuccess: "gotAccessToken", onFailure: "httpFailed" },
		{ name: "getUserName", kind: "WebService", url: GOOGLE.USERINFO_URL, method: "GET",
			handleAs: "json", onSuccess: "gotName", onFailure: "httpFailed" },
		//used when changing credentials on an existing account:
		{ name: "checkCredentials", kind: "PalmService", service: "palm://org.webosports.service.cdav/",
			method: "checkCredentials", onSuccess: "credentialsCameBack", onFailure: "credentialsCameBack" },
		{ kind: "ApplicationEvents", onWindowParamsChange: "windowParamsChangeHandler" },

		{ kind: "PageHeader", name: "pageHeader", content: $L("Sign in with Google"), pack: "center" },
		{ name: "alert", style: "margin:10px;text-align:center; background-color:red; color:yellow;", showing: false },
		{ name: "webView", kind: "WebView", flex: 1,
			onLoadStarted: "pageLoadStarted",
			onLoadFailed: "pageLoadFailed",
			onPageTitleChanged: "pageTitleChanged" },
		{ kind: "CrossAppResult", name: "crossAppResult" },
		{ className: "accounts-footer-shadow", tabIndex: -1 },
		{ kind: "Toolbar", className: "enyo-toolbar-light", components: [
			{ name: "doneButton", kind: "Button", caption: $L("Cancel"), onclick: "doBack", className: "accounts-toolbar-btn" }
		]}
	],

	create: function () {
		this.inherited(arguments);
		this.gotCode = false;

		if (window.PalmSystem && PalmSystem.launchParams) {
			try { this.params = JSON.parse(PalmSystem.launchParams); } catch (e1) {}
		}
		if (enyo.windowParams) {
			this.params = enyo.windowParams;
		}
		if (this.params && this.params.mode === "modify" && this.params.account) {
			this.accountId = this.params.account._id;
		}

		this.startAuth();
	},

	startAuth: function () {
		var url = GOOGLE.AUTH_URL +
				"?client_id=" + encodeURIComponent(GOOGLE.CLIENT_ID) +
				"&response_type=code" +
				"&redirect_uri=" + encodeURIComponent(GOOGLE.REDIRECT_URI) +
				"&scope=" + encodeURIComponent(GOOGLE.SCOPE) +
				"&access_type=offline&prompt=consent";

		if (this.params && this.params.account && this.params.account.credentials && this.params.account.credentials.user) {
			url += "&login_hint=" + encodeURIComponent(this.params.account.credentials.user);
		}

		console.error("CDAV-Google: loading auth url");
		this.$.webView.setUrl(url);
	},

	// Google redirects to REDIRECT_URI?code=...; that page cannot load, so we read the code
	// out of every URL the WebView tries. onLoadStarted fires first; onLoadFailed also carries
	// the URL when localhost refuses to connect. Either is fine -- gotCode guards against twice.
	pageLoadStarted: function (inSender, url) { this.handleUrl(url); },
	pageLoadFailed:  function (inSender, url) { this.handleUrl(url); },
	// Very old builds only surface the redirect via the title; keep as a belt-and-suspenders.
	pageTitleChanged: function (inSender, title) { this.handleUrl(title); },

	handleUrl: function (candidate) {
		if (this.gotCode || !candidate || typeof candidate !== "string") {
			return;
		}
		if (candidate.indexOf("oauth2callback") < 0 && candidate.indexOf("code=") < 0 && candidate.indexOf("error=") < 0) {
			return;
		}

		if (candidate.indexOf("error=") >= 0) {
			this.gotCode = true;
			this.showError($L("Google sign-in was cancelled or denied."));
			return;
		}

		var start = candidate.indexOf("code="), code;
		if (start >= 0) {
			this.gotCode = true;
			code = candidate.substring(start + 5);
			// strip any following params and decode
			if (code.indexOf("&") >= 0) { code = code.substring(0, code.indexOf("&")); }
			if (code.indexOf("#") >= 0) { code = code.substring(0, code.indexOf("#")); }
			code = decodeURIComponent(code);
			console.error("CDAV-Google: captured auth code, exchanging for tokens");
			this.exchangeCode(code);
		}
	},

	exchangeCode: function (code) {
		this.$.pageHeader.setContent($L("Getting access token..."));
		this.$.getAccessToken.call({
			code:          code,
			client_id:     GOOGLE.CLIENT_ID,
			client_secret: GOOGLE.CLIENT_SECRET,
			redirect_uri:  GOOGLE.REDIRECT_URI,
			grant_type:    "authorization_code"
		});
	},

	gotAccessToken: function (inSender, inResponse) {
		if (!inResponse || !inResponse.access_token) {
			this.showError($L("Could not get access token from Google."));
			return;
		}
		this.token_response = inResponse;
		this.$.pageHeader.setContent($L("Getting account info..."));
		this.$.getUserName.call({ access_token: inResponse.access_token });
	},

	gotName: function (inSender, inResponse) {
		var username = (inResponse && inResponse.email) ? inResponse.email : "",
			template = this.params && (this.params.template || this.params.account),
			credentials,
			config,
			i;

		this.$.pageHeader.setContent($L("Finishing up..."));

		credentials = {
			oauth:         true,
			access_token:  this.token_response.access_token,
			refresh_token: this.token_response.refresh_token,
			token_type:    this.token_response.token_type || "Bearer",
			authToken:     (this.token_response.token_type || "Bearer") + " " + this.token_response.access_token,
			client_id:     GOOGLE.CLIENT_ID,
			client_secret: GOOGLE.CLIENT_SECRET,
			refresh_url:   GOOGLE.TOKEN_URL,
			username:      username,
			user:          username
		};

		config = {
			name:        "Google",
			urlScheme:   "google",
			url:         "https://apidata.googleusercontent.com/caldav/v2",
			username:    username,
			credentials: credentials
		};

		if (!username) {
			username = "google-" + (this.token_response.access_token || "").substring(0, 8);
		}

		if (this.accountId) {
			// change-credentials on an existing account: hand new tokens to the service.
			this.accountSettings = { returnValue: true };
			this.$.checkCredentials.call({
				accountId: this.accountId,
				oauth:     credentials,
				url:       config.url,
				urlScheme: config.urlScheme,
				name:      config.name
			});
			return;
		}

		if (this.params && this.params.mode === "create" && template) {
			for (i = 0; i < template.capabilityProviders.length; i += 1) {
				if (template.capabilityProviders[i].capability === "CONTACTS") {
					template.capabilityProviders[i].enabled = true;
					template.capabilityProviders[i].loc_name = "Google Contacts";
				}
				if (template.capabilityProviders[i].capability === "CALENDAR") {
					template.capabilityProviders[i].enabled = true;
					template.capabilityProviders[i].loc_name = "Google Calendar";
				}
			}
			template.config = config;
			template.loc_name = "Google (" + username + ")";
		}

		this.accountSettings = {
			template:    template,
			username:    username,
			credentials: credentials,
			config:      config,
			alias:       username,
			returnValue: true
		};

		console.error("CDAV-Google: returning account settings to Accounts app");
		this.$.crossAppResult.sendResult(this.accountSettings);
	},

	credentialsCameBack: function (inSender, inResponse) {
		console.error("CDAV-Google: change-credentials came back: " + JSON.stringify(inResponse));
		this.$.crossAppResult.sendResult(this.accountSettings || { returnValue: true });
	},

	httpFailed: function (inSender, inResponse) {
		this.showError($L("Network error talking to Google. Please try again. ") + JSON.stringify(inResponse));
	},

	showError: function (msg) {
		console.error("CDAV-Google error: " + msg);
		this.$.alert.setContent(msg);
		this.$.alert.show();
	},

	windowParamsChangeHandler: function (inSender, event) {
		if (event && event.params && event.params.template) {
			this.params = event.params;
		}
	},

	doBack: function () {
		this.$.crossAppResult.sendResult({ returnValue: false });
	}
});
