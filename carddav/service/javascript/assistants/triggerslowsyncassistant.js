/*jslint nomen: false */
/*global Future, Log, DB, KindsContacts, KindsCalendar, checkResult */

var TriggerSlowSyncAssistant = function () { "use strict"; };

TriggerSlowSyncAssistant.prototype.gotDBObject = function (future) {
	"use strict";
	var result = checkResult(future);
	if (result.returnValue) {
		future.nest(this.processAccount(result.results, 0));
	} else {
		Log.log("Could not get DB object: ", result);
		Log.log(future.error);
		future.result = {returnValue: false, success: false};
	}
};

TriggerSlowSyncAssistant.prototype.run = function (outerFuture) {
	"use strict";
	var args = this.controller.args || {},
		future = new Future(),
		query = {"from": KindsContacts.account.metadata_id};

	//If an accountId was passed, only reset that account. Otherwise reset all (backwards compatible).
	if (args.accountId) {
		query.where = [{prop: "accountId", op: "=", val: args.accountId}];
	}

	future.nest(DB.find(query, false, false));

	future.then(this, this.gotDBObject);

	future.then(this, function contactsFinished() {
		query.from = KindsCalendar.account.metadata_id;
		future.nest(DB.find(query, false, false));
	});

	future.then(this, this.gotDBObject);

	future.then(this, function dbFinished() {
		var result = checkResult(future);
		Log.log("triggerSlowSync finished.");
		outerFuture.result = result;
	});
	return outerFuture;
};

TriggerSlowSyncAssistant.prototype.processAccount = function (objs, index) {
	"use strict";
	var future = new Future(), syncKey, obj = objs[index], key, kindState, folders, i;

	if (obj) {
		syncKey = obj.syncKey || {};

		//Force a genuine full re-download.
		//db8 merge DEEP-merges the syncKey object, so replacing syncKey[kind] wholesale does NOT
		//drop the persisted per-collection ctags -- the next sync then reads a matching ctag and
		//logs "Don't need update. Return empty set." (the bug that left contacts/events empty after
		//an unclean reboot rolled back the records but kept the ctag). We instead zero every stored
		//folder.ctag: CalDav.checkForChanges reports needsUpdate when (ctag !== params.ctag) and
		//params.ctag is 0, so it re-scans etags and re-downloads everything. error=true keeps the
		//full per-object etag scan on as well.
		for (key in syncKey) {
			if (syncKey.hasOwnProperty(key)) {
				kindState = syncKey[key] || {};
				kindState.error = true;
				kindState.folderIndex = 0;
				folders = kindState.folders;
				if (folders && folders.length) {
					for (i = 0; i < folders.length; i += 1) {
						folders[i].ctag = 0;         //invalidate the collection checkpoint
						delete folders[i].entries;   //drop any queued/pre-downloaded entries
						delete folders[i].downloadsFailed;
					}
				}
				syncKey[key] = kindState;
			}
		}

		//Also flag the kinds this client manages, in case no syncKey entry exists yet (fresh account).
		if (this.client && this.client.kinds && this.client.kinds.objects) {
			for (key in this.client.kinds.objects) {
				if (this.client.kinds.objects.hasOwnProperty(key)) {
					if (!syncKey[key]) {
						syncKey[key] = { error: true, folderIndex: 0 };
					} else {
						syncKey[key].error = true;
					}
				}
			}
		}

		obj.syncKey = syncKey;

		future.nest(DB.merge([obj]));

		future.then(this, function storeCB() {
			var result = checkResult(future);
			Log.debug("Store came back: ", result);
			future.nest(this.processAccount(objs, index + 1));
		});
	} else {
		Log.log("All ", index, " objects processed.");
		future.result = { returnValue: true, success: true };
	}

	return future;
};
