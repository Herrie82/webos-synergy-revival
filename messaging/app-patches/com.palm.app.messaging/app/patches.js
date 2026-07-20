/* webOS Synergy Revival: show the real IM service name in the Messaging contact preview.
 *
 * The contacts framework's IMAddress only knows the legacy services (AIM, Skype, GTalk, ICQ, ...);
 * any synergy service type - "type_whatsapp", "type_discord", "type_telegram", ... - falls through
 * IMAddress.getDisplayType() to the generic "IM" default label. The contact preview shown when the
 * user taps the name in the top bar (contactsui DetailsInDialog) renders each IM row's label from
 * imAddress.x_displayType, whose getter calls the static Contacts.IMAddress.getDisplayType(type) -
 * so wrapping that one static gives every widget the real service name ("WhatsApp", "Discord", ...)
 * while leaving the legacy services untouched.
 *
 * Contacts.IMAddress and ContactsLib.IMAddress are the same Foundations module export, so patching
 * it once covers DetailWidget and DetailsInDialog alike. This file is loaded AFTER contactsui in
 * depends.js, so Contacts.IMAddress already exists when this runs (unlike the Contacts app's
 * patches.js, which loads before the library and has to defer). */
(function () {
	var SERVICE_LABELS = {
		type_whatsapp: "WhatsApp",
		type_telegram: "Telegram",
		type_discord:  "Discord",
		type_signal:   "Signal",
		type_teams:    "Teams",
		type_facebook: "Facebook",
		type_googlechat: "Google Chat",
		type_xmpp:     "XMPP",
		type_jabber:   "Jabber",
		type_irc:      "IRC"
	};

	function patch(IMAddress) {
		if (!IMAddress || IMAddress.__synergyLabelsPatched) { return false; }
		var original = IMAddress.getDisplayType;
		if (typeof original !== "function") { return false; }
		IMAddress.getDisplayType = function (type) {
			if (SERVICE_LABELS.hasOwnProperty(type)) { return SERVICE_LABELS[type]; }
			return original.apply(this, arguments);
		};
		IMAddress.__synergyLabelsPatched = true;
		return true;
	}

	// Contacts, ContactsLib and window.IMAddress all reference the same module export; patching the
	// first one found is enough (the flag guards against a double-apply if this file loads twice).
	var scopes = [
		(typeof Contacts !== "undefined") ? Contacts : null,
		(typeof ContactsLib !== "undefined") ? ContactsLib : null,
		(typeof window !== "undefined") ? window : null
	];
	for (var i = 0; i < scopes.length; i++) {
		if (scopes[i] && patch(scopes[i].IMAddress)) { return; }
	}
	if (typeof console !== "undefined" && console.warn) {
		console.warn("[synergy] IMAddress not found; IM service labels not patched");
	}
}());
