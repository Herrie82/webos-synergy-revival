/*jslint regexp: true, node: true, nomen: true, newcap: true */
/*global Contacts, fs, Log, Future, libPath, checkResult */

var path = require("path"); //required for vCard converter.
var Quoting = require(libPath + "Quoting.js");
var vCardReader = require(libPath + "vCardReader.js");
var vCardWriter = require(libPath + "vCardWriter.js");

var vCard = (function () {
	"use strict";
	var tmpPath = "/tmp/caldav-contacts/", //don't forget trailling slash!!
		photoPath = "/media/internal/.caldav_photos/",
		vCardIndex = 0;

	function applyHacks(data, server) {
		if (server === "egroupware") {
			data = data.replace(/TEL;TYPE=CELL,VOICE/g, "TEL;TYPE=CELL");
			data = data.replace(/CELL;VOICE/g, "CELL");
		}

		return data;
	}

	function repairNote(note, data) {
		//webos seems to "forget" the note field.. add it here.
		if (note) {
			note.replace(/[^\r]\n/g, "\r\n");
		}
		note = Quoting.fold(Quoting.quote(note));
		Log.log("Having note:", note);
		return data.replace("END:VCARD", "NOTE:" + note + "\r\nEND:VCARD");
	}

	//---- direct vCard -> contact db object mapping (fast path, avoids Contacts.vCardImporter) ----

	function decodeQuotedPrintable(str) {
		return str.replace(/=([0-9A-Fa-f]{2})/g, function (m, hex) {
			return String.fromCharCode(parseInt(hex, 16));
		});
	}

	//3.0 value un-escaping: \n \N -> newline, \\ -> \, \, -> , \; -> ;
	function unescapeValue(v) {
		if (v === undefined || v === null) {
			return "";
		}
		var out = "", i, c, n;
		for (i = 0; i < v.length; i += 1) {
			c = v.charAt(i);
			if (c === "\\" && i + 1 < v.length) {
				i += 1;
				n = v.charAt(i);
				if (n === "n" || n === "N") {
					out += "\n";
				} else {
					out += n;
				}
			} else {
				out += c;
			}
		}
		return out;
	}

	//split on an UN-escaped delimiter (structured values use ";", multi-values use ",")
	function splitUnescaped(v, delim) {
		var parts = [], cur = "", i, c;
		for (i = 0; i < v.length; i += 1) {
			c = v.charAt(i);
			if (c === "\\" && i + 1 < v.length) {
				cur += c + v.charAt(i + 1);
				i += 1;
			} else if (c === delim) {
				parts.push(cur);
				cur = "";
			} else {
				cur += c;
			}
		}
		parts.push(cur);
		return parts;
	}

	function parseLine(line) {
		var colon = line.indexOf(":"), head, value, segs, name, dot, params, i;
		if (colon < 0) {
			return null;
		}
		head = line.substring(0, colon);
		value = line.substring(colon + 1);
		segs = head.split(";");
		name = segs[0];
		dot = name.indexOf("."); //strip group prefix, e.g. "item1.EMAIL"
		if (dot >= 0) {
			name = name.substring(dot + 1);
		}
		name = name.toUpperCase();
		params = [];
		for (i = 1; i < segs.length; i += 1) {
			params.push(segs[i]);
		}
		return {name: name, params: params, value: value};
	}

	function parseParams(params) {
		var types = [], pref = false, encoding = "", i, p, eq, k, val, vs, j, up;
		for (i = 0; i < params.length; i += 1) {
			p = params[i];
			eq = p.indexOf("=");
			if (eq >= 0) {
				k = p.substring(0, eq).toUpperCase();
				val = p.substring(eq + 1);
				if (k === "TYPE") {
					vs = val.split(",");
					for (j = 0; j < vs.length; j += 1) {
						up = vs[j].toUpperCase();
						if (up === "PREF") {
							pref = true;
						} else {
							types.push(up);
						}
					}
				} else if (k === "ENCODING") {
					encoding = val.toUpperCase();
				} else if (k === "PREF") {
					pref = true;
				}
			} else {
				up = p.toUpperCase();
				if (up === "PREF") {
					pref = true;
				} else if (up === "QUOTED-PRINTABLE") {
					encoding = "QUOTED-PRINTABLE";
				} else if (up === "BASE64" || up === "B") {
					encoding = "BASE64"; //photo encodings; PHOTO lines are skipped anyway
				} else {
					types.push(up); //vCard 2.1 bare type token: HOME/WORK/CELL/FAX/...
				}
			}
		}
		return {types: types, pref: pref, encoding: encoding};
	}

	function decodeValue(value, meta) {
		if (meta.encoding === "QUOTED-PRINTABLE") {
			return decodeQuotedPrintable(value);
		}
		return value;
	}

	function mapEmailType(types) {
		var i;
		for (i = 0; i < types.length; i += 1) {
			if (types[i] === "WORK") { return "type_work"; }
			if (types[i] === "HOME") { return "type_home"; }
		}
		return "type_other";
	}

	function mapPhoneType(types) {
		var i, t, hasWork = false, hasHome = false, hasFax = false;
		for (i = 0; i < types.length; i += 1) {
			t = types[i];
			if (t === "CELL" || t === "MOBILE") { return "type_mobile"; }
			if (t === "PAGER") { return "type_pager"; }
			if (t === "MAIN") { return "type_main"; }
			if (t === "FAX") { hasFax = true; }
			if (t === "WORK") { hasWork = true; }
			if (t === "HOME") { hasHome = true; }
		}
		if (hasFax) { return "type_fax"; }
		if (hasWork) { return "type_work"; }
		if (hasHome) { return "type_home"; }
		return "type_other";
	}

	function mapGenericType(types) {
		var i;
		for (i = 0; i < types.length; i += 1) {
			if (types[i] === "WORK") { return "type_work"; }
			if (types[i] === "HOME") { return "type_home"; }
		}
		return "type_other";
	}

	//Build a com.palm.contact-shaped object straight from parsed vCard lines.
	//Returns null when nothing usable was found, so the caller can fall back to the
	//stock Contacts.vCardImporter for that single record.
	function buildContactObject(lines) {
		var obj = {
				name: {
					givenName: "",
					familyName: "",
					middleName: "",
					honorificPrefix: "",
					honorificSuffix: ""
				},
				emails: [],
				phoneNumbers: [],
				addresses: [],
				ims: [],
				photos: []
			},
			i, parsed, meta, val, name, structured, addr, org, pre, imval,
			hasData = false, dn;

		for (i = 0; i < lines.length; i += 1) {
			parsed = parseLine(lines[i]);
			if (!parsed) {
				continue;
			}
			name = parsed.name;
			if (name === "BEGIN" || name === "END" || name === "VERSION" || name === "PRODID" ||
					name === "REV" || name === "UID" || name === "CATEGORIES" || name === "PHOTO" ||
					name === "SOURCE" || name === "KIND" || name === "CLASS") {
				continue;
			}
			meta = parseParams(parsed.params);
			val = decodeValue(parsed.value, meta);

			if (name === "FN") {
				obj.displayName = unescapeValue(val);
				hasData = true;
			} else if (name === "N") {
				structured = splitUnescaped(val, ";");
				obj.name.familyName = unescapeValue(structured[0] || "");
				obj.name.givenName = unescapeValue(structured[1] || "");
				obj.name.middleName = unescapeValue(structured[2] || "");
				obj.name.honorificPrefix = unescapeValue(structured[3] || "");
				obj.name.honorificSuffix = unescapeValue(structured[4] || "");
				hasData = true;
			} else if (name === "NICKNAME") {
				obj.nickname = unescapeValue(splitUnescaped(val, ",")[0] || "");
			} else if (name === "EMAIL") {
				if (val) {
					obj.emails.push({value: unescapeValue(val), type: mapEmailType(meta.types), primary: meta.pref});
					hasData = true;
				}
			} else if (name === "TEL") {
				if (val) {
					obj.phoneNumbers.push({value: unescapeValue(val), type: mapPhoneType(meta.types), primary: meta.pref});
					hasData = true;
				}
			} else if (name === "ADR") {
				structured = splitUnescaped(val, ";");
				//ADR structured value: po-box;extended;street;locality;region;postal;country
				addr = {
					type: mapGenericType(meta.types),
					streetAddress: unescapeValue(structured[2] || "").replace(/\n/g, " "),
					locality: unescapeValue(structured[3] || ""),
					region: unescapeValue(structured[4] || ""),
					postalCode: unescapeValue(structured[5] || ""),
					country: unescapeValue(structured[6] || ""),
					primary: meta.pref
				};
				pre = (unescapeValue(structured[0] || "") + " " + unescapeValue(structured[1] || "")).replace(/^\s+|\s+$/g, "");
				if (pre) {
					addr.streetAddress = (pre + " " + addr.streetAddress).replace(/^\s+|\s+$/g, "");
				}
				if (addr.streetAddress || addr.locality || addr.region || addr.postalCode || addr.country) {
					obj.addresses.push(addr);
					hasData = true;
				}
			} else if (name === "ORG") {
				structured = splitUnescaped(val, ";");
				org = {name: unescapeValue(structured[0] || "")};
				if (structured[1]) {
					org.department = unescapeValue(structured[1]);
				}
				if (org.name || org.department) {
					if (!obj.organizations) { obj.organizations = []; }
					obj.organizations.push(org);
					hasData = true;
				}
			} else if (name === "TITLE") {
				if (!obj.organizations) { obj.organizations = []; }
				if (!obj.organizations.length) { obj.organizations.push({name: ""}); }
				obj.organizations[0].title = unescapeValue(val);
			} else if (name === "BDAY") {
				obj.birthday = unescapeValue(val);
			} else if (name === "ANNIVERSARY" || name === "X-ANNIVERSARY" || name === "X-EVOLUTION-ANNIVERSARY") {
				obj.anniversary = unescapeValue(val);
			} else if (name === "NOTE") {
				obj.note = unescapeValue(val);
			} else if (name === "URL") {
				if (val) {
					if (!obj.urls) { obj.urls = []; }
					obj.urls.push({value: unescapeValue(val), type: mapGenericType(meta.types)});
				}
			} else if (name === "IMPP" || name === "X-JABBER" || name === "X-AIM" || name === "X-MSN" ||
					name === "X-ICQ" || name === "X-SKYPE" || name === "X-GOOGLE-TALK") {
				imval = unescapeValue(val);
				if (imval) {
					obj.ims.push({value: imval, type: mapGenericType(meta.types)});
				}
			} else if (name === "X-GENDER" || name === "GENDER") {
				obj.gender = unescapeValue(val);
			}
		}

		if (!hasData) {
			return null;
		}

		if (!obj.displayName) {
			dn = (obj.name.givenName + " " + obj.name.familyName).replace(/^\s+|\s+$/g, "");
			if (!dn && obj.emails.length) { dn = obj.emails[0].value; }
			if (!dn && obj.phoneNumbers.length) { dn = obj.phoneNumbers[0].value; }
			if (!dn && obj.organizations && obj.organizations.length) { dn = obj.organizations[0].name || ""; }
			obj.displayName = dn;
		}

		return obj;
	}

	//public interface:
	return {
		/**
		 * Required for initialisation of vCard parser. Will basically create
		 * a temporary directory in /tmp
		 * @return future wait for future result to be sure that this is ready.
		 */
		initialize: function () {
			var photo = false, tmp = false, future = new Future(), finished = function () {
				if (tmp && photo) {
					var res = checkResult(future);
					if (!res) {
						res = {};
					}
					res.vCard = true;
					future.result = res;
				}
			};

			fs.mkdir(tmpPath, parseInt("777", 8), function (error) {
				if (error) {
					Log.log("Could not create tmp-path, error:", error);
				}
				tmp = true;
				finished();
			});

			//create path for photos:
			fs.mkdir(photoPath, parseInt("777", 8), function (error) {
				if (error) {
					Log.log("Could not create photo-path, error:", error);
				}
				photo = true;
				finished();
			});

			return future;
		},

		/**
		 * parses a vcard into a webOS data object.
		 * @param input text representation of vcard
		 * @return future, result.result will contain the object uppon success.
		 */
		parseVCard: function (input) {
			var resFuture = new Future(),
				future = new Future(),
				filename = tmpPath + (input.account.name || "nameless") + "_" + vCardIndex + ".vcf",
				vCardImporter,
				version,
				photo,
				uid,
				categories,
				directObj,
				photoName,
				filewritten = false,
				reader = new vCardReader();

			vCardIndex += 1;
			if (!input.vCard) {
				Log.log("Empty vCard received.");
				return new Future({returnValue: false});
			}

			Log.log_icalDebug("vCard data:", input.vCard);

			if (input.vCard.indexOf("VERSION:3.0") > -1) {
				version = "3.0";
			} else if (input.vCard.indexOf("VERSION:2.1") > -1) {
				version = "2.1";
			}

			// Large base64 photos (common in iOS/Android exports) get unfolded into one
			// massive string by processString, then decoded into a Buffer — this crashes
			// webOS's old Node.js. A plain contact VCF is 1-3 KB; anything over 25 KB
			// almost certainly contains a large embedded photo, so strip it first.
			// Photos don't display reliably in webOS anyway (see comment below).
			var vCardData = input.vCard;
			if (vCardData.length > 25360) {
				vCardData = vCardData.replace(/^PHOTO[^\r\n]*(\r?\n[\t ][^\r\n]*)*/mg, "");
			}
			reader.processString(vCardData, version);
			photo = reader.extractPhoto();
			uid = reader.extractUID();
			categories = reader.extractCategories();

			// FAST PATH: build the contact object directly from the parsed vCard lines. This
			// avoids writing a temp .vcf file and running the heavy stock Contacts.vCardImporter
			// for every single contact (the "Patch not installed" path) — the main slowness on
			// large address books. If the vCard has nothing we can map, fall through to the
			// framework importer below.
			directObj = buildContactObject(reader.getLines());
			if (directObj) {
				directObj._kind = input.account.kind;
				directObj.uid = uid;
				directObj.categories = categories;

				if (photo.photoData.length > 0) {
					photoName = photoPath + (input.account.name || "nameless") +
						directObj.name.givenName + directObj.name.familyName + photo.photoType;
					reader.writePhoto(photo, photoName).then(function () {
						// com.palm.contact:1 REQUIRES a "value" on every photos[] entry; without it db8
						// rejects the whole (transactional) put batch and the sync framework crashes.
						directObj.photos.push({value: photoName, localPath: photoName, primary: true, type: "type_big"});
						directObj.photos.push({value: photoName, localPath: photoName, primary: false, type: "type_square"});
						directObj.photos.push({value: photoName, localPath: photoName, primary: false, type: "type_list"});
						resFuture.result = {returnValue: true, result: directObj};
					});
				} else {
					resFuture.result = {returnValue: true, result: directObj};
				}
				return resFuture;
			}

			// FALLBACK: direct build produced nothing usable -> use the stock Contacts importer.
			Log.log("vCard direct build empty; falling back to Contacts.vCardImporter.");

			//setup importer
			vCardImporter = new Contacts.vCardImporter({
				filePath: filename,
				importToAccountId: input.account.accountId,
				version: version
			});

			if (vCardImporter.setVCardFileReader) {
				vCardImporter.setVCardFileReader(reader);
				future.result = {returnValue: true};
			} else {
				Log.log("Patch not installed => Need to write vCard to file.");
				future.nest(reader.writeToFile(filename));
				filewritten = true;
			}

			//do import:
			future.then(function () {
				var result = checkResult(future);
				if (result.returnValue) {
					future.nest(vCardImporter.readVCard());
				} else {
					resFuture.result = {returnValue: false};
				}
			});

			future.then(function () {
				var result = checkResult(future), obj, key;

				if (filewritten) {
					fs.unlink(filename);
				}

				if (result[0]) { //result[0] is a Contact!
					obj = result[0].getDBObject();
					obj._kind = input.account.kind;

					//prevent overriding of necessary stuff.
					for (key in obj) {
						if (obj.hasOwnProperty(key)) {
							if (obj[key] === undefined || obj[key] === null) {
								//log("Deleting entry " + key + " from obj.");
								delete obj[key];
							}
						}
					}
					delete obj.accounts;
					delete obj.accountId;
					delete obj.syncSource;
					obj.uid = uid;
					obj.categories = categories;

					if (photo.photoData.length > 0) { //got a photo!! :)
						filename = photoPath + (input.account.name || "nameless") + obj.name.givenName + obj.name.familyName + photo.photoType;
						reader.writePhoto(photo, filename).then(function () {
							//storing those here and NOT using ContactsLib to set photos introduces the issue that photos will always stay
							//but I did not manage to show the photo in all places in webos.
							obj.photos.push({value: filename, localPath: filename, primary: true, type: "type_big"});
							obj.photos.push({value: filename, localPath: filename, primary: false, type: "type_square"});
							obj.photos.push({value: filename, localPath: filename, primary: false, type: "type_list"});
							future.result = {returnValue: true, obj: obj};
						});
					} else {
						//no photo, continue.
						future.result = {returnValue: true, obj: obj};
					}
				} else { //no contact, some error must have happend.
					Log.log("No result from conversion: ", result);
					resFuture.result = {returnValue: false, result: {}};
				}
			});

			future.then(function () {
				var result = checkResult(future);
				Log.debug("Result from write photo: ", result);
				resFuture.result = {returnValue: true, result: result.obj};
			});

			return resFuture;
		},

		/**
		 * generates a textual vCard from webOS contact object
		 * @param input webOS contact object
		 * @return future, result.result will contain the text representation uppon success
		 */
		generateVCard: function (input) {
			var resFuture = new Future(),
				future = new Future(),
				filename = tmpPath + (input.accountName || "nameless") + "_" + vCardIndex + ".vcf",
				version = "3.0",
				data,
				contactId = input.contact._id,
				vCardExporter = new Contacts.VCardExporter({
					filePath: filename,
					version: version,
					charset: Contacts.VCard.CHARSET.UTF8,
					useFileCache: false
				}),
				writer = new vCardWriter(),
				filewritten = false,
				contact = new Contacts.Contact(input.contact),
				person = new Contacts.Person();

			Log.log("Got contact: ", input.contact);
			vCardIndex += 1;
			person.populateFromContact(contact);

			if (vCardExporter.setVCardFileWriter) {
				vCardExporter.setVCardFileWriter(writer);
			} else {
				Contacts.Utils.defineConstant("kind", input.kind, Contacts.Person);
				Log.log("Patch not installed => Need to write vCard to file.");
				filewritten = true;
			}

			Log.log("Get contact ", contactId, " transfer it to version ", version, " vCard.");
			future.nest(vCardExporter.exportOne(contactId, false, person));

			future.then(function () {
				Log.log("result: ", checkResult(future));
				if (filewritten) {
					Log.log("webOS saved vCard to ", filename);
					future.nest(writer.readFile(filename));
				} else {
					future.result = {returnValue: true, data: writer.getData()};
				}
			});

			future.then(function () {
				var result = checkResult(future);
				if (result.returnValue) {
					data = result.data;
					data = applyHacks(data, input.server);
					data = data.replace(/\nTYPE=:/g, "\nURL:"); //repair borked up URL thing on webOS 3.X. Omitting type here..

					//repair note if patch was not applied.
					if (filewritten) {
						data = repairNote(input.contact.note, data);
					}

					if (contact.uId) {
						contact.uid = contact.uid || contact.uId;
						delete contact.uId;
					}

					//need to add uId in any case, vCard export can't do that for us, because it works on contacts:
					if (input.contact.uid) {
						data = data.replace("END:VCARD", "UID:" + input.contact.uid + "\r\nEND:VCARD");
					}

					//add categories if contact had them
					if (input.contact.categories) {
						data = data.replace("END:VCARD", "CATEGORIES:" + input.contact.categories + "\r\nEND:VCARD");
					}

					if (input.contact.photos && input.contact.photos.length > 0) {
						future.nest(writer.createPhotoBlob(input.contact.photos));
					} else {
						future.result = { returnValue: true};
					}
				} else {
					resFuture.result = { returnValue: false };
				}
			});

			future.then(function photoBlobCB() {
				var result = checkResult(future);
				if (result.blob) {
					data = data.replace("END:VCARD", result.blob + "END:VCARD");
				}
				Log.debug("Modified data:", data);
				resFuture.result = { returnValue: true, result: data };
			});

			return resFuture;
		}
	}; //end of public interface
}());

module.exports = vCard;
