/* Single depends.js loaded by every entry page (index.html, accountSetup.html,
 * accountSetupGoogle.html). Enyo 1 auto-loads depends.js from the launched HTML's
 * directory; all our pages sit at the app root, so one depends.js registers every
 * kind and each page just instantiates the one it needs. */
enyo.depends(
	"source/oauthWindow.js",
	"source/urlschemes.js",
	"source/CDavApp.js",
	"source/GenericSetup.js",
	"source/GoogleSetup.js",
	"source/accounts.css"
);
