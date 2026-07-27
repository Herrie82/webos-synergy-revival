/*jslint browser: true */
/*global console */
/*exported UrlSchemes */

/* Browser-side copy of the service's urlschemes.js, used by the generic setup form to
 * populate the "Known Servers" picker (schemes with a `name`) and to force a urlScheme.
 * The service keeps the authoritative copy (service/javascript/urlschemes.js); keep the
 * `keys`/`name`/url templates in sync when adding providers. Log is shimmed to console. */
var UrlSchemes = (function () {
	"use strict";
	var Log = { debug: function () {}, log: function () {} };

	var self = {
		urlSchemes: {
			icloud: {
				keys:              ["icloud.com"],
				hidden:            true,
				checkCredentials:  "https://p02-contacts.icloud.com:443"
			},
			google: {
				oauth:             true,
				hidden:            true,
				keys:              [".googleapis.", ".google.", "apidata.googleusercontent."],
				calendar:          "https://apidata.googleusercontent.com:443/caldav/v2/%USERNAME%/",
				contact:           "https://www.googleapis.com:443/carddav/v1/principals/%USERNAME%/lists/",
				checkCredentials:  "https://apidata.googleusercontent.com:443/caldav/v2/%USERNAME%/user"
			},
			yahoo: {
				keys:              ["yahoo."],
				hidden:            true,
				calendar:          "https://caldav.calendar.yahoo.com/dav/%USERNAME%/Calendar/",
				contact:           "https://carddav.address.yahoo.com/dav/%USERNAME%/",
				checkCredentials:  "https://caldav.calendar.yahoo.com/dav/"
			},
			owncloud: {
				name:              "ownCloud / Nextcloud",
				keys:              ["/owncloud/", "/nextcloud/", "cloudu.de"],
				needPrefix:        true,
				calendar:          "%URL_PREFIX%remote.php/dav/calendars/%USERNAME%/",
				contact:           "%URL_PREFIX%remote.php/dav/addressbooks/users/%USERNAME%/",
				checkCredentials:  "%URL_PREFIX%remote.php/dav"
			},
			fruuxcom: {
				name:              "fruux.com",
				keys:              [".fruux.com"],
				checkCredentials:  "https://dav.fruux.com/"
			},
			mykolabcom: {
				name:              "mykolab.com",
				keys:              ["mykolab.com"],
				calendar:          "https://caldav.mykolab.com/calendars/%USERNAME%%40mykolab.com/",
				contact:           "https://carddav.mykolab.com/addressbooks/%USERNAME%%40mykolab.com/",
				checkCredentials:  "https://caldav.mykolab.com/calendars/%USERNAME%%40mykolab.com/"
			},
			posteode: {
				name:              "Posteo.de",
				keys:              ["posteo.de"],
				calendar:          "https://posteo.de:8443/calendars/%USERNAME%/",
				contact:           "https://posteo.de:8843/addressbooks/%USERNAME%/",
				checkCredentials:  "https://posteo.de:8443/calendars/"
			},
			mailboxorg: {
				name:              "Mailbox.org",
				keys:              [".mailbox.org"],
				checkCredentials:  "https://dav.mailbox.org/"
			},
			yandexru: {
				name:              "Yandex",
				keys:              [".yandex.ru", ".yandex.com"],
				calendar:          "https://caldav.yandex.ru/",
				contact:           "https://carddav.yandex.ru/",
				checkCredentials:  "https://caldav.yandex.ru/"
			},
			sabredav: {
				name:              "sabre/dav",
				keys:              ["/sabredav/"],
				needPrefix:        true,
				calendar:          "%URL_PREFIX%calendarserver.php/calendars/%USERNAME%/default/",
				contact:           "%URL_PREFIX%addressbookserver.php/addressbooks/%USERNAME%/",
				checkCredentials:  "%URL_PREFIX%calendarserver.php/calendars/%USERNAME%/default/"
			},
			sogo: {
				name:              "SOGo",
				keys:              ["/SOGo/"],
				needPrefix:        true,
				calendar:          "%URL_PREFIX%dav/%USERNAME%/Calendar/",
				contact:           "%URL_PREFIX%dav/%USERNAME%/Contacts/",
				checkCredentials:  "%URL_PREFIX%dav/%USERNAME%/"
			}
		},

		processScheme: function (scheme, type, username, prefix) {
			var newURL = false;
			if (scheme[type]) {
				if (typeof scheme[type] === "string") {
					newURL = scheme[type];
					if (scheme.needPrefix) {
						newURL = newURL.replace("%URL_PREFIX%", prefix);
					}
					newURL = newURL.replace("%USERNAME%", username);
					return newURL;
				}
				return scheme[type];
			}
		},

		resolveURL: function (url, username, type, forceScheme) {
			var i, j, scheme, index, prefix, newURL, searchUrl, tmpUrl, keys;
			if (!url) { url = ""; }
			searchUrl = url.toLowerCase();

			if (forceScheme && this.urlSchemes[forceScheme]) {
				scheme = this.urlSchemes[forceScheme];
				if (scheme.needPrefix) {
					tmpUrl = url;
					if (url.charAt(url.length - 1) !== "/") { tmpUrl += "/"; }
				}
				return this.processScheme(scheme, type, username, tmpUrl || url);
			}

			keys = Object.keys(this.urlSchemes);
			for (i = 0; i < keys.length; i += 1) {
				scheme = this.urlSchemes[keys[i]];
				for (j = 0; j < scheme.keys.length; j += 1) {
					index = searchUrl.indexOf(scheme.keys[j].toLowerCase());
					if (index >= 0) {
						if (scheme.needPrefix) {
							tmpUrl = url.substring(0, index + scheme.keys[j].length);
						}
						newURL = this.processScheme(scheme, type, username, tmpUrl || url);
						if (newURL) { return newURL; }
					}
				}
			}
			return false;
		}
	};

	return self;
}());
