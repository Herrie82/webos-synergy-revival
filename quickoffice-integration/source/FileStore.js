/*global Account, console, enyo, File, FileStore, Hash, QOWT, QuickofficeApp, setTimeout, window */

/**
 * @fileoverview This file handles service interaction and a possible cache (right now used as shortcuts for browser)
 *
 * @author Jelte
 * @version 1.0
 */


/**
 * Class for accessing the files on the device.
 *
 * @class
 */
enyo.kind({
    name: "LocalFileService",
    kind: "DbService",

    dbKind: "com.palm.media.misc.file:1", // Specified here, so we don't need 'from' in the query
    method: "find",
    //subscribe: true,        // PalmService will keep its request alive until explicitly canceled
                            // or the Service is destroyed (also sets 'watch' to true)

    statics: {
        /**
         * Creates a File component from a database record.
         *
         * @param {Object} inRecord A record from the com.palm.media.misc.file:1 table.
         *
         * @return {Object} A new File component based upon the specified record.
         *
         * @protected
         */
        makeFileComponent: function(inRecord) {
            return new File({
                // Properties we don't use (and their example values):
                //    _id:       ++Htch+6luORYCvi
                //    _kind:     com.palm.media.misc.file:1
                //    _rev:      723
                //    searchKey: my_document

                extension:  inRecord.extension,
                fileStem:   inRecord.name,
                uri:        inRecord.path,
                size:       inRecord.size,
                timestamp:  new Date(inRecord.modifiedTime * 1000)
            });
        }
    },

    /**
     * Returns a list of the files on the local device
     *
     * @param {Number} inLimit      The maximum number of records to return. This value is
     *                              currently honored only when the account is the local device).
     * @param {Object} inNextHandle A 'magic cookie' that may be returned with a batch of query
     *                              results, indicating that there is additional data. This value
     *                              can be used in a subsequent query to request the next 'page'
     *                              of data. At the time of this writing, our API for requesting
     *                              directory information from remote sources does not support
     *                              paging, so this property is currently used only when querying
     *                              directory information on the local device.
     */
    getFiles: function(inLimit, inNextHandle) {
        ///////////////////////////////////////////////////////////
        // BEGIN: Browser-mode only; can be removed before shipping
        if (window.fauxFile || !window.PalmSystem) {
            // If we're running on a browser...
            // then check if we are using the com.quickoffice.browser app and if so
            // try to get a file listing from the localhost (which should be running
            // the alacarte test server).
            
            if(enyo.fetchAppInfo().id === "com.quickoffice.browser") {
                enyo.xhrGet({
                   url:      "http://localhost:8080/root/?r={%22name%22:%22getFiles%22,%22id%22:%221234%22,%22path%22:%22.%22}",
                   sync:     false,
                   handleAs: "json",
                   load:     enyo.hitch(this, "browserMockCB")
               });
            } else {
                // else just query the list of files from our Mock object
                enyo.xhrGet({
                    url:      "source/cache/fileCache.json",
                    sync:     false,
                    handleAs: "json",
                    load:     enyo.hitch(this, "browserMockCB")
                });
            }
            return;
        }
        // END: Browser-mode only; can be removed before shipping
        ///////////////////////////////////////////////////////////

        // ...otherwise, query the database
        var query = {
            orderBy: "name",
            desc:    false
        };

        // If a maximum number of returned records was specified...
        if (inLimit && inLimit > 0) {
            // ...add that information to the query
            query.limit = inLimit;
        }

        // If a continuation of a previous query was requested...
        if (inNextHandle) {
            // ...add that information to the query
            query.page = inNextHandle;
        } else {
            // ...otherwise, this is the first query, so subscribe to watch notifications
            // NOTE: If we put this in the initializers for this kind, it will reset the subscribe
            //       each time a query is made to fetch an additional page of results, and only
            //       changes to the rows _in that result set_ will fire watch events.
            this.subscribe = true;
        }

        this.call({query: query});
    },

    ///////////////////////////////////////////////////////////
    // BEGIN: Browser-mode only; can be removed before shipping
    browserMockCB: function(inJSON) {
        inJSON = inJSON || "{}";

     /**
      * NOTE: Some very strange behavior observed here
      * The original code: eval("(" + inJSON + ")")
      * The updated code:  eval(inJSON)
      *
      * The original code worked in Alacarte, but don't understand
      *  why the inJSON was encased in brackets.
      *
      *  PF: eval returns last expression/statement result in code, brackets ensure expression.
      *  Try in browser mode:
      *
      *  alert(eval('{x:{x:5}}');
      *  alert(eval('({y:3, x:{z:4}})'));
      *  alert(eval('{y:3, x:{z:4}}'));  and see what happens...
      *
      *  OK Ill explain:
      *  Let's have inJSON == "{x:5}";
      *
      *     You may think that you evaluate object instance...
      *     To let you imagine: imagine you put that text into script and you load it in a page...
      *     you will realise that you are using LABELS (!). if you add soft brackets, then its an expression returning object!
      *     (that is why brackets are used with functions etc.)
      *     you have in reality:
      *     {
      *         x : 5
      *     }
      *     Braskets here are not object brackets but SCOPE brackets.
      *
      *  Try to put in code somewhere { x:5 }, jslint should warn u of using labels.
      *
      *  Take a look at fix, it should work whatever is set in inJSON (as long syntax of JSON is fine!);
      *  We could use brackets but its not ok in all cases.
      *  This one will work for case of empty string, undefined etc.
      *
      *  The updated code failed because the eval caused "SyntaxError: Parse error"
      *  even though the JSON was fully valid.
      *
      *  PF: Seems that parse method was implemented incorrectly.
      *
      *  Just use   ->    eval("(function(){return "+inJSON+";})()");
      * or brackets but check content first (if not empty string or semicolon only).
      *
      * Switching to use the JSON.parse method which seems
      * more robust and is obviously less "evil"


      * Josh: It actually doesn't work because all of those examples are invalid JSON.
      *
      * { "x": { "x": 5 } } // valid
      * {x:{x:5}}           // invalid
      *
      * @see http://timelessrepo.com/json-isnt-a-javascript-subset
      *
      * If one is using JavaScript to create the JSON one should call JSON.stringify() to ensure that the JSON is always valid
      * If a third-party is providing the invalid JSON and it's out of one's hands then one could always fix it with
      * a regular expression...
      *
      *   inJSON = inJSON.toString().replace(/(\w+)\s*:/g, '"$1":'); // converts {x:5} to {"x":5}
      *
      * But using eval is definitely not a good thing. Specially since I don't see any attempt here to validate the incoming data.
      */
      if(inJSON === "") {
            // THIS MEANS alacarte is not working hence fall back to fixures.
            enyo.xhrGet({
                url:      "source/cache/fileCache.json",
                sync:     false,
                handleAs: "json",
                load:     enyo.hitch(this, "browserFixtureCB")
            });
            return;
        }
        
        var results = eval("(" + inJSON + ")") || undefined;
        results = results.files;
        // TODO for now alacarte is not returning extension, size and modified time.
        // TODO remove this code once alacarte is updated.
        if(results) {
            var files = results;
            for (var i in files) {
                var file = files[i];
                if(file.name.endsWith("docx")) {
                    file.extension = "docx";
                } else if(file.name.endsWith("doc")) {
                    file.extension = "doc";
                } else if(file.name.endsWith("pptx")) {
                    file.extension = "pptx";
                } else if(file.name.endsWith("ppt")) {
                    file.extension = "ppt";
                } else if(file.name.endsWith("txt")) {
                    file.extension = "ppt";
                }
                file.type = File.typeFromExtension(file.extension);
            }
        }
       
        var response = {
            /*jslint evil: true */
            results: results || []
            /*jslint evil: false */
        };
        // Return the list of file info objects to the caller
        this.owner.onLocalFileSuccess(this, response);
    },

    /**
     * This code gets called when alacarte is not setup. Here we return list of files from FileCache.
     * @param inJSON
     */
    browserFixtureCB: function(inJSON) {
        var response = {
            /*jslint evil: true */
            results: eval("(" + inJSON + ")") || []
            /*jslint evil: false */
        };
        // Return the list of file info objects to the caller
        this.owner.onLocalFileSuccess(this, response);
    }
    // END: Browser-mode only; can be removed before shipping
    ///////////////////////////////////////////////////////////
});

/**
 * Decides who should handle file and account requests
 *
 * @class
 */
enyo.kind({
    name: "FileStore",
    kind: "Component",

    statics: {
        /**
         * Maps an error code returned from the LocalFileService component to one of the QOWT.ERROR
         * constants.
         *
         * @param {Number} inErrorCode
         *
         * @return {String} The errorId from one of the QOWT.ERROR constants.
         */
        qowtErrorFromErrorCode: function(inErrorCode) {
            switch (inErrorCode) {
                // Add cases here as appropriate to map these to QOWT.ERROR.<type>
                default:
                    return QOWT.ERROR.GenericError.errorId;
            }
        }
    },

    components: [{
            // Service to query information about remote file accounts
            name:                            "accounts",
            kind:                            "Accounts.getAccounts",
            onGetAccounts_AccountsAvailable: "onAccountsSuccess"
        }, {
            // Service to query credentials for a given account
            name:      "credentials",
            kind:      "PalmService",
            service:   "palm://com.palm.service.accounts/",
            method:    "readCredentialsPublic",
            onFailure: "fail"
        }, {
            // Service to query information about the files stored on the device
            name:      "localFileService",
            kind:      "LocalFileService",
            onSuccess: "onLocalFileSuccess",
            onFailure: "onLocalFileFailure",
            onWatch:   "onLocalFileWatch"
        }, {
            // Service to query information about the files stored remotely (e.g. Google Docs)
            name:             "remoteFileService",
            kind:             "RemoteFileService",
            onRootListError:  "onRemoteFileFailure", // Error getting the root list
            onOtherListError: "onRemoteFileFailure"  // Error getting a non-root list
        }
    ],

    // MODERN REROUTE: the revival cloud services have no push "watch", so saving/uploading a
    // file from the editor never fires the local-file watch that normally refreshes the browser
    // (that is why newly-added files needed a manual refresh). RemoteFileService dispatches
    // "qowt:remoteFileChanged" after a successful modern upload; treat it exactly like a watch
    // event so the current folder listing re-queries and the new/updated file appears at once.
    create: function() {
        this.inherited(arguments);
        this._remoteChangedBound = enyo.hitch(this, "_onRemoteFileChanged");
        QOWT.EVT.addListener(window.document, "qowt:remoteFileChanged", this._remoteChangedBound);
    },

    destroy: function() {
        if (this._remoteChangedBound) {
            QOWT.EVT.removeListener(window.document, "qowt:remoteFileChanged", this._remoteChangedBound);
            this._remoteChangedBound = undefined;
        }
        this.inherited(arguments);
    },

    _onRemoteFileChanged: function() {
        // Mirror onLocalFileWatch: hand the browser its watch callback so it clears its cache
        // and re-lists the current folder through the (always-fresh) modern getFiles path.
        // Skip destroyed stores (this event is broadcast to every FileStore instance) and don't
        // let a stale callback's synchronous work escape - the render it schedules is guarded
        // separately in FolderContentsList.showOverlay/hideOverlay.
        if (this.destroyed || !this.onWatchCb) { return; }
        try { this.onWatchCb([]); } catch (e) {
            QOWT.utils.log("FileStore _onRemoteFileChanged ignored stale watch: " + e);
        }
    },

    /**
     * Assigns a delegate to (or clears) the watch callback
     *
     * @param {Function} inWatchCb  Delegate to handle failure.
     */
    setWatchCallback: function(inWatchCb) {
        this.onWatchCb = inWatchCb;
    },

    /**
     * Queries files/folders from the specified account (local or remote) and folder.
     *
     * @param {Object}   inAccount    An Account component describing the account.
     * @param {Object}   inFolder     A File component describing the folder.
     * @param {Number}   inLimit      The maximum number of records to return. This value is
     *                                currently honored only when the account is the local device).
     * @param {Object}   inNextHandle A 'magic cookie' that may be returned with a batch of query
     *                                results, indicating that there is additional data. This value
     *                                can be used in a subsequent query to request the next 'page'
     *                                of data. At the time of this writing, our API for requesting
     *                                directory information from remote sources does not support
     *                                paging, so this property is currently used only when querying
     *                                directory information on the local device.
     * @param {Function} inSuccessCb  Delegate to handle data on success.
     * @param {Function} inFailureCb  Delegate to handle failure.
     * @param {Boolean}  inJustFolders If true, returns the folders. Otherwise files + folders. Ignored for local files.
     */
    getFileItems: function(inAccount, inFolder, inLimit, inNextHandle, inSuccessCb, inFailureCb, inJustFolders) {
        //console.log("FileStore.getFileItems(inAccount: " + inAccount + ", inFolder: " + inFolder + ", inLimit: " + inLimit + ", inNextHandle: " + inNextHandle + ", ...)");

        // If there are any pending requests with the remoteFileService, cancel them
        this.$.remoteFileService.cancelAll();

        // Store these for use in onLocalFileSuccess/onRemoteFileSuccess (where we translate
        // returned results into actual File components before returning them to the caller),
        // or onLocalFileFailure/onRemoteFileFailure
        this.fileSuccessCb = inSuccessCb;
        this.fileFailureCb = inFailureCb;

        // If the specified account is remote...
        if (inAccount.isRemote()) {
            // ...query the remote account for a list of files
            var source = {
                _id:       inAccount._id,
                folderUri: inFolder.uri,
                mxId:      inAccount.mxId,
                password:  inAccount.password,
                uri:       inAccount.uri, // URI will be undefined the first time we query a remote service root
                username:  inAccount.username
            };

            this.$.remoteFileService.getFiles(source, enyo.hitch(this, "onRemoteFileSuccess"), inJustFolders);
        }
        // ...otherwise, the account is local...
        else {
            // ...query for a list of files on the device
            this.$.localFileService.getFiles(inLimit, inNextHandle);
        }
    },

    /**
     * Delegate called by the local file service query when it has successfully returned results.
     *
     * @param {Object} inSender   The object that generated this event.
     * @param {Object} inResponse The query response object
     *
     * @protected
     */
    onLocalFileSuccess: function(inSender, inResponse) {
        var rec, records = (inResponse && inResponse.results) || [], result = {files: []};

        // Convert the array of records returned to File components
        for (var i = 0; i < records.length; ++i) {

            rec = records[i];

            // Replace the element in the array with a new File object constructed from
            // the original element
            result.files.push(new File({
                
                // JELTE TODO: alacarte has a typo; until this is fixed, just deal with it here
                extension:  rec.extension || rec.extention,
                fileStem:   rec.name,
                uri:        rec.path,
                size:       rec.size,
                mimeType:   rec.mimeType,
                type:       (rec.mimeType == "application/directory" ? File.kFILETYPE_DIR : undefined),
                timestamp:  new Date(rec.modifiedTime * 1000)

                // Properties we ignore (and their example values):
                //    _id:       ++Htch+6luORYCvi
                //    _kind:     com.palm.media.misc.file:1
                //    _rev:      723
                //    searchKey: my_document
            }));
        }

        // If these results came as part of a watch being triggered...
        if (inResponse.fired) {
            // ...set a flag to indicate that this is an update (vs. another page of data)
            result.fired = true;
        }

        // If we received a 'handle' to the next page of results...
        if (inResponse.next) {
            // ...pass it along to the caller as well.
            result.next = inResponse.next;
        }

        // Pass the results back to the caller
        this.fileSuccessCb(result);
    },

    /**
     * Delegate called by the local file service query when it returns a failure.
     *
     * @param {Object} inSender    The object that generated this event
     * @param {Object} inResponse
     *
     * @protected
     */
    onLocalFileFailure: function(inSender, inResponse) {
        console.warn("Local file service returned error #" + inResponse.errorCode + ": " + inResponse.errorText);

        // If the caller provided a failure delegate...
        if (this.fileFailureCb) {
            // ...inform the caller of the failure (map the local error code to the errorId of one
            // of the QOWT.ERROR constants)
            this.fileFailureCb(FileStore.qowtErrorFromErrorCode(inResponse.errorCode));
        }
    },

    /**
     * Delegate called by the local file service when data has changed.
     *
     * @param {Object} inSender   The object that generated this event.
     * @param {Object} inResponse The query response object
     * @param {Object} inRequest  The query request object
     *
     * @protected
     */
    onLocalFileWatch: function(inSender, inResponse, inRequest) {
        if (this.onWatchCb) {
            this.onWatchCb(arguments);
        }
    },

    /**
     * Delegate called by the remote file service query when it has successfully returned results.
     *
     * @param {Object} inFiles
     *
     * @protected
     */
    onRemoteFileSuccess: function(inFiles, inLocationUrl) {
        var fileInfo, files = inFiles || [], result = {};

        // These results may be cached by RemoteFileService. If we haven't converted them to File
        // components and sorted them yet...
        if (files.length > 0 && files[0].mimeType) {
            // Convert the array of objects returned to actual File objects
            for (var i = 0; i < files.length; ++i) {
                // The elements returned contain file info, but aren't File components (yet)
                fileInfo = files[i];

                // Replace the element in the array with a new File object constructed from the
                // original element
                files[i] = new File({
                    extension:  fileInfo.extension,
                    fileStem:   fileInfo.name,
                    uri:        fileInfo.uri,
                    size:       fileInfo.size,
                    timestamp:  File.parseUtcDate(fileInfo.modifiedTime),
                    type:       File.typeFromMimeType(fileInfo.mimeType)
                });
            }

            // Sort the files: Folders first (by name), then files, by full name
            files.sort(function(inA, inB) {
                var aIsFolder = inA.isFolder();
                var bIsFolder = inB.isFolder();

                if (aIsFolder && !bIsFolder) {
                    return -1;
                } else if (!aIsFolder && bIsFolder) {
                    return 1;
                }

                return inA.getFilename().localeCompare(inB.getFilename());
            });
        }

        result.files = files;
        result.uri = inLocationUrl;

        // Pass the results (now an array of actual File components) back to the caller
        this.fileSuccessCb(result);
    },

    /**
     * Delegate called by the remote file service query when it returns a failure.
     *
     * @param {Object} inSender
     * @param {Event}  inEvent
     *
     * @protected
     */
    onRemoteFileFailure: function(inSender, inEvent) {
        console.warn("Remote file service failed: " + ((inEvent && inEvent.detail && inEvent.detail.errorId) ? inEvent.detail.errorId : "no error information"));

        // If the caller provided a failure delegate...
        if (this.fileFailureCb) {
            // ...inform the caller of the failure
            this.fileFailureCb((inEvent && inEvent.detail && inEvent.detail.errorId) ? inEvent.detail.errorId : QOWT.ERROR.GenericError.errorId);
        }
    },

    /**
     * Called by the UI when it's not interested in the remote files anymore
     *
     * @public
     */
    cancelRemoteAction: function() {
        // If there are any pending requests with the remoteFileService, cancel them
        this.$.remoteFileService.cancelAll();
        
    },
    
    /**
     * Delegate called when a credential query returns a failure.
     *
     * @protected
     */
    fail: function() {
        console.warn("Credential service failed!");
        //console.warn(arguments);
    },

    /**
     * Called to request information about the accounts.
     *
     * @param {Function} inFoundCb   Delegate to handle accounts as they are found.
     * @param {Function} inRemovedCb Delegate to handle any accounts that are removed.
     */
    getAccounts: function(inFoundCb, inRemovedCb) {
        delete Object.prototype.toJSON;
        delete Array.prototype.toJSON;
        delete Hash.prototype.toJSON;
        delete String.prototype.toJSON;

        if (inFoundCb) {
            this.accountsFoundCb = inFoundCb;
        }

        if (inRemovedCb) {
            this.accountsRemovedCb = inRemovedCb;
        }

        ///////////////////////////////////////////////////////////
        // BEGIN: Browser-mode only; can be removed before shipping
        if (window.fauxFile || !window.PalmSystem) { // If we're running on a browser...
            // ...use mock data
            // Icons for remote accounts are now fetched from account call.
            this.accountsFoundCb(new Account({
                _id:         "blah box.net blah",
                accountType: Account.kACCT_TYPE_BOXNET,
                alias:       "Boxnet",
                mxId:        Account.kMXID_BOXNET,
                password:    "password",
                uri:         undefined,                     // "box://box.net",
                username:    "someone@somewhere.com"
            }));

            this.accountsFoundCb(new Account({
                _id:         "blah drop box blah",
                accountType: Account.kACCT_TYPE_DROP_BOX,
                alias:       "DropBox",
                mxId:        Account.kMXID_DROP_BOX,
                password:    "password",
                uri:         undefined,                     // "drop://getdropbox.com",
                username:    "someone@somewhere.com"
            }));

            this.accountsFoundCb(new Account({
                _id:         "blah google docs blah",
                accountType: Account.kACCT_TYPE_GOOGLE_DOCS,
                alias:       "Google Docs",
                mxId:        Account.kMXID_GOOGLE_DOCS,
                password:    "password",
                uri:         undefined,                     // "gdocs://google.com",
                username:    "someone@somewhere.com"
            }));

            this.accountsFoundCb(new Account({
                _id:         "blah mobile me blah",
                accountType: Account.kACCT_TYPE_MOBILE_ME,
                alias:       "Mobile Me",
                mxId:        Account.kMXID_MOBILE_ME,
                password:    "password",
                uri:         undefined,                     // "idisk://me.com",
                username:    "someone@somewhere.com"
            }));

            return;
        }
        // END: Browser-mode only; can be removed before shipping
        ///////////////////////////////////////////////////////////

        //this.$.listAccounts.call({capability: "DOCUMENTS"});
        this.$.accounts.getAccounts({capability: QuickofficeApp.kCAPABILITY}, "com.palm.palmprofile");
    },

    /**
     * Delegate to handle results from the 'listAccounts' Palm Service.
     *
     * @param {Object} inSender   The object that generated this event.
     * @param {Object} inResponse
     *
     * @protected
     */
    onAccountsSuccess: function(inSender, inResponse) {
        var found, i;

        // If we already have accounts cached from a previous query...
        if (this.accountsCache) {
            // Iterate across the cached accounts
            for (i = 0; i < this.accountsCache.length; i++) {
                found = false;
                // Iterate across the returned account results
                for (var j = 0; j < inResponse.accounts.length; j++) {
                    // If we have a match...
                    if (this.accountsCache[i]._id === inResponse.accounts[j]._id) {
                        // ...stop looking
                        found = true;
                        break;
                    }
                }

                // If the cached account wasn't found in the returned account results...
                if (!found) {
                    // ...notify the caller that it was removed
                    this.accountsRemovedCb(this.accountsCache[i]._id);
                }
            }
        }

        // Replace the cached accounts with the newly returned account results
        this.accountsCache = inResponse.accounts;

        // Request passwords
        for (i = 0; i < this.accountsCache.length; i++) {

            // Create or update the account
            this.addUpdateAccountCallback(i);

            this.$.credentials.call({
                accountId:    this.accountsCache[i]._id,
                name:         "common",
                accountIndex: i
            }, {
                onSuccess: "gotCredentials"
            });
        }
    },

    /**
     * Called when the 'credentials' Palm Service has successfully returned results.
     *
     * @param {Number} inAccountIndex
     * @param {Object} inCredentials
     * @param {Object} inRequest
     *
     * @protected
     */
    gotCredentials: function(inSender, inCredentials, inRequest) {
        var accountIndex = inRequest.params.accountIndex;

        this.accountsCache[accountIndex].password = inCredentials.credentials.password;

        // Update the account to add the password field.
        this.addUpdateAccountCallback(accountIndex);
    },

    // MODERN REROUTE (webos-synergy-revival): return the palm://com.palm.service.* URI that
    // implements this account's DOCUMENTS capability, or null for a legacy (MX) account. This
    // single check replaces the old per-provider loc_name switch: any account whose DOCUMENTS
    // capability is served by a _cloudcore service is handled generically, with no case needed.
    _modernServiceUri: function(acct) {
        var cps = acct && acct.capabilityProviders;
        if (!cps) { return null; }
        for (var i = 0; i < cps.length; i++) {
            if (cps[i] && cps[i].capability === "DOCUMENTS" && cps[i].implementation &&
                cps[i].implementation.indexOf("palm://com.palm.service.") === 0) {
                return cps[i].implementation;
            }
        }
        return null;
    },

    /**
     * Callback function called when a new account is added to our account cache.
     *
     * @param {Object} inAccountIndex The index into our account cache of the newly-loaded
     *                                account information object.
     */
    addUpdateAccountCallback: function(inAccountIndex) {
        var acct = this.accountsCache[inAccountIndex];
        var accountType, mxId;

        // MODERN REROUTE (webos-synergy-revival): if this account's DOCUMENTS capability is
        // served by a _cloudcore service, register _id -> serviceUri so RemoteFileService can
        // route to it, and mark it generically. accountType/mxId are inert for modern accounts
        // (the modern path is keyed on _id and bypasses the MX account-type/mxId logic).
        var svcUri = this._modernServiceUri(acct);
        if (svcUri) {
            QOWT.MX.modernServiceByAccountId = QOWT.MX.modernServiceByAccountId || {};
            QOWT.MX.modernServiceByAccountId[acct._id] = svcUri;
            accountType = "modernCloudAccount";
            mxId        = "modern";
        } else {
            // Legacy stock providers still resolve through the (now-dead) MX proxy path.
            switch (acct.loc_name.toLowerCase()) {
            case "google":
                accountType = Account.kACCT_TYPE_GOOGLE_DOCS;
                mxId        = Account.kMXID_GOOGLE_DOCS;
                break;

            case "dropbox":
                accountType = Account.kACCT_TYPE_DROP_BOX;
                mxId        = Account.kMXID_DROP_BOX;
                break;

            case "box.net":
                accountType = Account.kACCT_TYPE_BOXNET;
                mxId        = Account.kMXID_BOXNET;
                break;

            case "mobileme":
                accountType = Account.kACCT_TYPE_MOBILE_ME;
                mxId        = Account.kMXID_MOBILE_ME;
                break;

            default:
                console.error("Location of account not recognized!");
                console.error(acct.loc_name.toLowerCase());
                break;
            }
        }

        // Call the Accounts Found delegate with information about the specified account.
        this.accountsFoundCb(new Account({
            _id:         this.accountsCache[inAccountIndex]._id,
            accountType: accountType,
            alias:       this.accountsCache[inAccountIndex].alias,
            mxId:        mxId,
            password:    this.accountsCache[inAccountIndex].password,
            uri:         this.accountsCache[inAccountIndex].uri,
            username:    this.accountsCache[inAccountIndex].username,
            iconPath:    this.accountsCache[inAccountIndex].icon.loc_48x48
        }));
    }
});
