/*global console, enyo, QOWT */

/**
 * @fileoverview This file handles the remote file interaction
 *
 * @author Mikko Rintala
 * @version 1.0
 */


//
// This is the API to QO's MX server
//

/**
 *
 * @param {Object} errorcode
 * @return {Boolean}
 */
QOWT.MX.handleError = function(errorcode, msg) {
    var rsp;

    switch (errorcode) {
        case "-1":
        case "19":
            rsp = QOWT.ERROR.MXRemoteFileNotFound;
            break;
            
        case "1":
            rsp = QOWT.ERROR.MXRequestFailed;
            break;

        case "2":
            rsp = QOWT.ERROR.MXRemoteFolderNotFound;
            break;

        case "3":
        case "17":
        case "18":
        case "34":
            rsp = QOWT.ERROR.MXDocumentNotSupported;
            break;

        case "24":
            rsp = QOWT.ERROR.MXRemoteFileTooBig;
            break;

        case "30":
            rsp = QOWT.ERROR.NameTooLong;
            break;
            
        case "33":
            rsp = QOWT.ERROR.MXUploadFailed;
            break;

        case "35":
            rsp = QOWT.ERROR.MXRemoteFileAlreadyExists;
            break;

/*        case "":
            rsp = QOWT.ERROR.MXRemoteFolderAlreadyExists;
            break;*/

        case "37":
            rsp = QOWT.ERROR.NameHasIllegalChars;
            break;

        case "39":
            rsp = QOWT.ERROR.MXQuotaExceeded;
            break;

        case "53":
            rsp = QOWT.ERROR.MXNotSupported;
            break;

        case "out of sync":
            rsp = QOWT.ERROR.MXRemoteFileChanged;
            break;

        default:
            break;
    }
    
    if(!rsp && msg) { // If we got an error text from server but the error was not one of the above, then create a generic one
        rsp = QOWT.ERROR.GenericError;
        rsp.fatal = false;
    }
    
    if (rsp) {
        rsp.msg = msg;
        rsp.status = 'failed';
        QOWT.EVT.dispatchEvent(window.document, 'qowt:error', rsp);
        return true;
    }

    return false;
};

/**
 *
 * @param {Object} mxId
 * @return {String}
 */
QOWT.MX.getMXUriForService = function(mxId) {
    var services = QOWT.utils.restoreObject(QOWT.MXConfig.serviceListStorageName);

    if (services && services.service[mxId]) {
        return services.service[mxId].uri;
    }

    return undefined;
};

// MODERN REROUTE (webos-synergy-revival): a "modern" cloud account is any whose DOCUMENTS
// capability is implemented by a palm://com.palm.service.* LS2 service that speaks the shared
// _cloudcore contract (listFolder / downloadFile / uploadFile). FileStore discovers these from
// each account's capabilityProviders and publishes an _id -> serviceUri map here; every object
// that reaches a file op already carries the account _id, so routing is fully account-derived -
// adding a new cloud provider needs ZERO changes to this file (no component, no switch case).
QOWT.MX.modernServiceByAccountId = QOWT.MX.modernServiceByAccountId || {};
QOWT.MX.modernServiceUriForAccount = function(account) {
    var id = account && (account._id || account.id);
    if (!id) { return null; }
    return QOWT.MX.modernServiceByAccountId[id] || null;
};

/**
 * Creates a unique filename to be used in the MX cache folder for downloaded remote files
 * @param {Object} inCandidate Original filename
 *
 * @return {String} The unique target filename.
 */
QOWT.MX.createUniqueTargetFilename = function(inCandidate) {
    QOWT.utils.log("RemoteFileCacheService: createuniquetargetfilename for: " + inCandidate);

    var date = new Date();
    var uniqueTargetFilename = Math.abs(date.getTime()) + "-" + inCandidate;

    // prepend a timestamp to the target name
    uniqueTargetFilename = uniqueTargetFilename.replace(/['"*?<>]/g, "");

    // remove any disallowed chars from target filename
    // Temporary fix for target file names that contain "/", which the file system doesn't like
    var indexOfSlash = uniqueTargetFilename.indexOf("/");
    indexOfSlash > -1 ? (uniqueTargetFilename = uniqueTargetFilename.substring(indexOfSlash + 1)) : null;

    QOWT.utils.log("RemoteFileCacheService: createuniquetargetfilename created: " + uniqueTargetFilename);

    return uniqueTargetFilename;
};


// If the file has no mimetype, let's try to get it from the extension
QOWT.MX.getMimeType = function(extension) {
    var mime;

    if(extension && extension.toLowerCase) {
        
        switch (extension.toLowerCase()) {
            case "doc":
                mime = "application/vnd.ms-word";
                break;
            case "docx":
                mime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
                break;
            case "txt":
                mime = "application/plain";
                break;
            case "xls":
                mime = "application/vnd.ms-excel";
                break;
            case "xlsx":
                mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
                break;
            case "ppt":
                mime = "application/vnd.ms-powerpoint";
                break;
            case "pptx":
                mime = "application/vnd.openxmlformats-officedocument.presentationml.presentation";
                break;
            case "pdf":
                mime = "application/pdf";
                break;
            default:
                break;
        }
    }
    return mime;
};            



QOWT.MX.addOp = "add";
QOWT.MX.replaceOp = "replace";

/**
 * This component is used to upload files into the cloud. You can either add a new file into the
 * cloud or replace an existing file. HP's DownloadManager is used to upload files. You can upload
 * only files that have been downloaded to the device (i.e., they are in the cache). If you are
 * replacing a file in the cloud and the remote file has been changed in the server meanwhile,
 * then you will get an error.
 *
 * @class
 */
enyo.kind({
    name: "RemoteFileUploadService",
    kind: "Component",

    events: {
        onProgress: ""
    },

    components: [{
        name:      "dlManager",
        kind:      "PalmService",
        service:   "palm://com.palm.downloadmanager/",
        subscribe: true
    }, {
        // MODERN REROUTE: statically-declared cloud service, repointed per account by _modernSvc.
        // Static (not lazily createComponent'd) so it's fully wired at initial render - see _modernSvc.
        name:      "modernSvc",
        kind:      "PalmService"
    }],

    // MODERN REROUTE (webos-synergy-revival): return the account's revival cloud PalmService,
    // account-derived via QOWT.MX.modernServiceUriForAccount (null for a legacy MX account) - no
    // per-provider list here, so a new provider needs no change. The service is the STATIC
    // this.$.modernSvc repointed per account, NOT a lazily createComponent'd one: an Enyo
    // dynamically-created PalmService is not fully wired until its owner's next render() pass -
    // which only happened when navigating between providers - so the FIRST list/upload right after
    // opening a provider silently dropped its reply ("open kDrive first fails, but works after
    // visiting Box and back"). A statically-declared service is wired at initial render, so the
    // first call is reliable.
    _modernSvc: function(account) {
        var uri = QOWT.MX.modernServiceUriForAccount(account);
        if (!uri) { return null; }
        this.$.modernSvc.setService(uri);
        return this.$.modernSvc;
    },

    /**
     * Called when the object is first made.
     */
    create: function() {
        QOWT.utils.log("RemoteFileUploadService create");

        this.inherited(arguments);

        this.accountInfo              = {};
        this.gotRemoteFileInfoHandler = this._gotRemoteFileInfo.bindAsEventListener(this);
        this.mxError                  = this._handleMxError.bind(this);
    },

    /**
     *
     * @param {Object} inFile
     * @param {Object} inNewName
     * @param {Object} inAccount
     * @param {Object} inSuccess
     * @param {Object} inFailure
     */
    addFileInCloud: function(inFile, inNewName, inParent, inAccount, type, inSuccess, inFailure) {
        QOWT.utils.log("RemoteFileUploadService addFileInCloud");

        this.successCb   = inSuccess;
        this.failureCb   = inFailure;
        this.accountInfo = inAccount;
        this.parentUri   = inParent;
        this.currentOp   = QOWT.MX.addOp;
        this.newFileName = inNewName;
        this.cacheName   = inFile;

        // MODERN REROUTE: add a new file into a revived cloud folder via uploadFile. Pass both
        // a Dropbox-style path AND a folderId+name so each service uses what it needs.
        if (inAccount && this._modernSvc(inAccount)) {
            this.localInfo = QOWT.mxe.remoteFileInfoCache.getInfo(inFile);
            var parent = (inParent === undefined || inParent === null) ? "" : String(inParent);
            this._modernUpload({
                localPath:   QOWT.MXConfig.downloadFolder + inFile,
                dropboxPath: parent.replace(/\/+$/, "") + "/" + inNewName,  // Dropbox path form
                folderId:    parent,                                        // Box/OneDrive/Drive id
                name:        inNewName
            }, { success: true, operation: QOWT.MX.addOp, newName: inNewName });
            return;
        }

        var src = QOWT.MXConfig.downloadFolder + inFile;
        uri = QOWT.mxe.getAddFileUrl(this.parentUri, this.newFileName, this.accountInfo);
        this.localInfo = QOWT.mxe.remoteFileInfoCache.getInfo(inFile);
        if(this.localInfo && !type) { // TODO: What to do with un-cached files and the mimetype??
            type = this.localInfo.type;
        }
        
        this._startUpload(src, this.newFileName, uri, type);
    },

    /**
     *
     * @param {Object} inFile
     * @param {Object} inAccount
     * @param {Object} inSuccess
     * @param {Object} inFailure
     */
    replaceFileInCloud: function(inFile, inAccount, inSuccess, inFailure) {
        QOWT.utils.log("RemoteFileUploadService replaceFileInCloud");

        this.successCb   = inSuccess;
        this.failureCb   = inFailure;
        this.accountInfo = inAccount;
        this.currentOp   = QOWT.MX.replaceOp;
        this.newFileName = undefined;

        // MODERN REROUTE: save an edited cloud doc straight back via uploadFile (overwrite),
        // skipping the dead MX GetRemoteItemInfo out-of-sync round-trip.
        if (inAccount && this._modernSvc(inAccount)) {
            this._modernReplace(inFile);
            return;
        }

        this._getRemoteInfo(inFile);
    },

    // MODERN REROUTE: replace (save-back) an edited cloud file. The cache holds the local copy
    // (uniqueTargetFilename) and the remote locator (uri = Dropbox path OR Box/OneDrive/Drive
    // file id); overwrite it in place (replace:true selects each service's version endpoint).
    _modernReplace: function(inFile) {
        var info = QOWT.mxe.remoteFileInfoCache.getInfo(inFile);
        if (!info) { QOWT.MX.handleError("-1"); this.failureCb(); return; }
        this.localInfo = info;
        this._modernUpload({
            localPath:   QOWT.MXConfig.downloadFolder + info.uniqueTargetFilename,
            dropboxPath: info.uri,      // Dropbox path (overwrite mode)
            fileId:      info.uri,      // Box/OneDrive/Drive file id
            replace:     true
        }, { success: true, operation: QOWT.MX.replaceOp });
    },

    // Shared modern upload: push a local file to the account's revival service, then fire
    // QuickOffice's existing success/failure contract and keep remoteFileInfoCache consistent
    // (mirrors _handleUpload). callArgs carries the superset of params each service reads.
    _modernUpload: function(callArgs, res) {
        this._muRes = res;
        callArgs.accountId = this.accountInfo._id;
        this._modernSvc(this.accountInfo).call(callArgs,
            { method: "uploadFile", onSuccess: "_modernUploadOk", onFailure: "_modernUploadFail" });
    },

    _modernUploadOk: function(inSender, inResponse) {
        QOWT.utils.log("RemoteFileUploadService _modernUploadOk " + JSON.stringify(inResponse));
        var res = this._muRes || { success: true, operation: this.currentOp };
        if (this.currentOp === QOWT.MX.replaceOp) {
            if (this.localInfo && inResponse) { this.localInfo.size = inResponse.size; }
            if (this.localInfo) { QOWT.mxe.remoteFileInfoCache.updateInfo(this.localInfo); }
        } else if (inResponse) { // add: register the new remote file in the cache
            var newInfo = { name: inResponse.name, uri: (inResponse.path || inResponse.id),
                size: inResponse.size, parent: this.parentUri,
                type: (this.localInfo && this.localInfo.type) };
            QOWT.mxe.remoteFileInfoCache.addInfo(newInfo, this.cacheName);
        }
        // AUTO-REFRESH: cloud services have no push watch, so tell any open file browser that a
        // remote file changed. FileStore listens for this and fires its watch callback, which
        // clears the folder cache and re-lists - so a newly-saved file shows without a manual
        // refresh. (No-op if no browser is mounted.)
        if (QOWT.EVT && QOWT.EVT.dispatchEvent) {
            QOWT.EVT.dispatchEvent(window.document, "qowt:remoteFileChanged",
                { operation: this.currentOp });
        }
        this.successCb(res);
    },

    _modernUploadFail: function(inSender, inError) {
        QOWT.utils.log("RemoteFileUploadService _modernUploadFail " + JSON.stringify(inError));
        this.failureCb({ error: (inError && (inError.errorText || inError.errorCode)) || "upload failed" });
    },

    /**
     *
     * @param {Object} inFile
     *
     * @protected
     */
    _getRemoteInfo: function(inFile) {
        this.localInfo = QOWT.mxe.remoteFileInfoCache.getInfo(inFile);

        if (!this.localInfo) {
            QOWT.MX.handleError("-1");
            this.failureCb();
            return;
        }

        QOWT.mxe.GetRemoteItemInfo(this, this.accountInfo, this.localInfo.uri);

        QOWT.EVT.addListener(window.document, 'qowt:mxgetremotefileinfo', this.gotRemoteFileInfoHandler);
        QOWT.EVT.addListener(window.document, 'qowt:error',               this.mxError);
    },

    /**
     *
     * @param {Object} inEvent
     *
     * @protected
     */
    _gotRemoteFileInfo: function(inEvent) {
        QOWT.utils.log("RemoteFileUploadService _gotRemoteFileInfo " + inEvent.detail.status);

        var res = {};

        switch (inEvent.detail.status) {
            case 'started':
                return;

            case 'completed':
                this.freshRemoteInfo = inEvent.detail.info;

                if (this.currentOp === QOWT.MX.replaceOp && !QOWT.mxe.remoteFileInfoCache.InfosMatch(this.freshRemoteInfo, this.localInfo)) {
                    QOWT.utils.log("RemoteFileUploadService _gotRemoteFileInfo file has changed in the server");

                    QOWT.EVT.removeListener(window.document, 'qowt:error', this.mxError);

                    var rsp = QOWT.ERROR.MXRemoteFileChanged;
                    QOWT.MX.handleError("out of sync");
                    this.failureCb("out of sync"); // File has changed in the server
                    break;
                }

                var uri;
                var filepath = QOWT.MXConfig.downloadFolder + this.localInfo.uniqueTargetFilename;
                var type = this.freshRemoteInfo.type;

                uri = QOWT.mxe.getReplaceFileUrl(this.freshRemoteInfo.uri, this.accountInfo);
                QOWT.utils.log("RemoteFileUploadService _gotRemoteFileInfo about to replace ");

                this._startUpload(filepath, this.freshRemoteInfo.name, uri, type);
                break;

            case 'failed':
                QOWT.utils.log("RemoteFileUploadService _gotRemoteFileInfo getting info failed");

                QOWT.EVT.removeListener(window.document, 'qowt:error', this.mxFailureHandler);
                QOWT.MX.handleError(inEvent.detail.error, inEvent.detail.msg);
                this.failureCb();
                break;

            default:
                break;
        }

        QOWT.EVT.removeListener(window.document, 'qowt:mxgetremotefileinfo', this.gotRemoteFileInfoHandler);
        QOWT.EVT.removeListener(window.document, 'qowt:error',               this.mxError);
    },

    /*
     * Start the upload itself
     */
    _startUpload: function(filepath, name, uri, type) {
        QOWT.utils.log("RemoteFileUploadService _startUpload");
        QOWT.utils.log("RemoteFileUploadService _startUpload sending file " + filepath);
        QOWT.utils.log("RemoteFileUploadService _startUpload to uri " + uri);
        QOWT.utils.log("RemoteFileUploadService _startUpload as " + name);
        QOWT.utils.log("RemoteFileUploadService _startUpload type " + type);
        var post_params = [{
            key:         'contentType',
            data:        type,
            contentType: 'text/plain'
        }];
        this.$.dlManager.call({
            'fileName':       filepath,
            'fileLabel':      name,
            'url':            uri,
            'contentType':    type,
            'subscribe':      true,
            'postParameters': post_params
        }, {
            onSuccess: this.currentOp === QOWT.MX.replaceOp ? '_handleReplace' : '_handleAdd',
            onFailure: this.currentOp === QOWT.MX.replaceOp ? '_handleReplace' : '_handleAddFailure',
            method: 'upload'
        });
    },
        
   /**
     *
     * @param {Object} inSender The object that generated this event.
     * @param {Object} inResult
     *
     * @protected
     */
    _handleReplace: function(inSender, inResult) {
        QOWT.utils.log("RemoteFileUploadService _handleReplace");

        if (this.currentOp !== QOWT.MX.replaceOp) {
            return; // wrong operation
        }

        this._handleUpload(inSender, inResult);
    },

    /**
     *
     * @param {Object} inSender The object that generated this event.
     * @param {Object} inResult
     *
     * @protected
     */
    _handleAdd: function(inSender, inResult) {
        QOWT.utils.log("RemoteFileUploadService _handleAdd");

        if (this.currentOp !== QOWT.MX.addOp) {
            return; // wrong operation
        }

        this._handleUpload(inSender, inResult);
    },

    _handleAddFailure: function(inSender, inResult) {
        QOWT.utils.log("RemoteFileUploadService _handleAddFailure");
        _handleAdd(inSender, inResult);
    },

    /**
     *
     * @param {Object} inSender The object that generated this event.
     * @param {Object} inResult
     *
     * @protected
     */
    _handleUpload: function(inSender, inResult) {
        QOWT.utils.log("RemoteFileUploadService _handleUpload inResults: " + JSON.stringify(inResult));

        if (!inResult.httpCode && !inResult.errorCode && !inResult.completionCode) {
            return; // It's just an update.. ToDo: maybe UI would like to know about the progress
        }

        QOWT.utils.log("RemoteFileUploadService _handleUpload httpCode: " + inResult.httpCode);
        QOWT.utils.log("RemoteFileUploadService _handleUpload errorCode: " + inResult.errorCode);
        QOWT.utils.log("RemoteFileUploadService _handleUpload completionCode: " + inResult.completionCode);
        QOWT.utils.log("RemoteFileUploadService _handleUpload responseString: " + inResult.responseString);

        var res = {};
        var remote;

        if (inResult.httpCode) {

            if (inResult.httpCode === 200 && inResult.responseString) {
                res.success   = true;
                res.operation = this.currentOp;
                remote = eval('(' + inResult.responseString + ')');

                if (this.currentOp !== QOWT.MX.addOp) { // replace
                    this.localInfo.lastmodified = remote.lastmodified;
                    this.localInfo.size         = remote.size;
                    this.localInfo.created      = remote.created;
                    QOWT.mxe.remoteFileInfoCache.updateInfo(this.localInfo);
                } else { // add
                    var newInfo = remote.items[0];
                    res.newName = newInfo.name;
                    newInfo.parent = this.parentUri; // Upload does not return the parent uri in the response info
                    if(this.localInfo) { // We probably copied a remote file which already exists in the cache 
                        QOWT.mxe.remoteFileInfoCache.removeInfo(this.localInfo.uri);
                        newInfo.downloadTicket = this.localInfo.downloadTicket;
                        QOWT.mxe.remoteFileInfoCache.addInfo(newInfo, this.localInfo.uniqueTargetFilename);                        
                    } else { // We probably copied a local file into a remote server
                        QOWT.mxe.remoteFileInfoCache.addInfo(newInfo, this.cacheName);
                    }
                }
                this.successCb(res);
                return;
            }
        }
        
        // There's a code but httpCode is not 200 so it is a failure
        if(inResult.responseString) {
            try {
                remote = eval('(' + inResult.responseString + ')');
            } catch (e) {
                remote = undefined;
            }
        }

        // Do not pass the localized error text as we know that for now it's not localized (as long as DownloadManager does not let us pass the locale info into the server)
        if (remote && !QOWT.MX.handleError(remote.ccode/*, remote.ctext*/)) {
            res.error = remote.ccode;
        } else if(inResult.errorCode) {
            res.error = inResult.errorCode;
        } else if(inResult.completionCode) {
            res.error = inResult.completionCode;                
        }

        QOWT.utils.log("RemoteFileUploadService _handleUpload failed: " + res.error);
        res.outOfSync = true;
        this.failureCb(res);
    },

    /**
     *
     * @param {Object} inEvent
     *
     * @protected
     */
    _handleMxError: function(inEvent) {
        QOWT.utils.log("RemoteFileUploadService _handleMxError event " + inEvent.eventName);

        var res = {};

        if (inEvent) {
            res = inEvent.detail;
        }

        QOWT.EVT.removeListener(window.document, 'qowt:mxgetremotefileinfo', this.gotRemoteFileInfoHandler);
        QOWT.EVT.removeListener(window.document, 'qowt:error',               this.mxError);

        this.failureCb(res);
    }
});

/**
 * This component handles downloading remote files and updates the remotefileinfocache accordingly.
 * It also takes care of deleting cached files when the cache limit is exceeded.
 * It uses HP's DownloadManager to download files.
 *
 * @class
 */
enyo.kind({
    name: "RemoteFileCacheService",
    kind: "Component",

    events: {
        onProgress: ""
    },

    components: [{
        name:      "dlManager",
        kind:      "PalmService",
        service:   "palm://com.palm.downloadmanager/",
        subscribe: true
    }, {
        // MODERN REROUTE: statically-declared cloud service, repointed per account by _modernSvc.
        // Static (not lazily createComponent'd) so it's fully wired at initial render - see _modernSvc.
        name:      "modernSvc",
        kind:      "PalmService"
    }],

    // MODERN REROUTE (webos-synergy-revival): return the account's revival cloud PalmService,
    // account-derived via QOWT.MX.modernServiceUriForAccount (null for a legacy MX account) - no
    // per-provider list here, so a new provider needs no change. The service is the STATIC
    // this.$.modernSvc repointed per account, NOT a lazily createComponent'd one: an Enyo
    // dynamically-created PalmService is not fully wired until its owner's next render() pass -
    // which only happened when navigating between providers - so the FIRST list/upload right after
    // opening a provider silently dropped its reply ("open kDrive first fails, but works after
    // visiting Box and back"). A statically-declared service is wired at initial render, so the
    // first call is reliable.
    _modernSvc: function(account) {
        var uri = QOWT.MX.modernServiceUriForAccount(account);
        if (!uri) { return null; }
        this.$.modernSvc.setService(uri);
        return this.$.modernSvc;
    },

    /**
     * Called when the object is first made.
     */
    create: function() {
        QOWT.utils.log("RemoteFileCacheService create");

        this.inherited(arguments);

        this.accountInfo = {};
        this.cancelTicket = undefined;
        this.gotRemoteFileInfoHandler = this._gotRemoteFileInfo.bindAsEventListener(this);
        this.deleteRemoteFileHandler  = this._remoteFileDeleted.bindAsEventListener(this);
        this.downloadSuccessHandler   = this._downloadSuccess.bind(this);
        this.downloadFailureHandler   = this._downloadFailure.bind(this);
        this.mxFailureHandler         = this._mxFailure.bind(this);

        //QOWT.utils.log("RemoteFileCacheService create OUT");
    },

    /**
     *
     */
    cancel: function() {
        QOWT.utils.log("RemoteFileCacheService cancel");

        this.cancelling = true;
        QOWT.mxe.CancelRequestFromGroup(this);

        if (this.cancelTicket) {
            QOWT.utils.log("RemoteFileCacheService cancelling " + this.cancelTicket);
            this.$.dlManager.call({
                ticket: this.cancelTicket
            }, {
                onSuccess: "",
                onFailure: "",
                method:    "cancelDownload"
            });
        }

        this.cancelTicket = undefined;

        QOWT.EVT.removeListener(window.document, 'qowt:mxgetremotefileinfo', this.gotRemoteFileInfoHandler);
        QOWT.EVT.removeListener(window.document, 'qowt:mxdeleteremotefile',  this.deleteRemoteFileHandler);
        QOWT.EVT.removeListener(window.document, 'qowt:error',               this.mxFailureHandler);

        QOWT.utils.log("RemoteFileCacheService cancel OUT");
    },

    /**
     *
     * @param {Object} inUri
     * @param {Object} inAccountInfo
     * @param {Object} inSuccess
     * @param {Object} inFailure
     * @param {Object} inFileIndex
     */
    deleteRemoteFile: function(inUri, inAccountInfo, inSuccess, inFailure, inFileIndex) {
        QOWT.utils.log("RemoteFileCacheService deleteFile");

        this.cancel();
        this.cancelling  = false;
        this.successCb   = inSuccess;
        this.failureCb   = inFailure;
        this.uri         = inUri;
        this.accountInfo = inAccountInfo;
        this.fileIndex   = inFileIndex;

        QOWT.EVT.addListener(window.document, 'qowt:mxdeleteremotefile', this.deleteRemoteFileHandler);
        QOWT.EVT.addListener(window.document, 'qowt:error',              this.mxFailureHandler);

        QOWT.mxe.DeleteItem(this, this.accountInfo, this.uri);
    },

    /**
     *
     * @param {Object} inEvent
     *
     * @protected
     */
    _remoteFileDeleted: function(inEvent) {
        QOWT.utils.log("RemoteFileCacheService _remoteFileDeleted " + JSON.stringify(inEvent.detail));

        if (this.cancelling) {
            QOWT.utils.log("RemoteFileCacheService _remoteFileDeleted cancelling");
            return;
        }

        var res = {};

        switch (inEvent.detail.status) {
            case 'started':
                return;

            case 'completed':
                res.success   = true;
                res.fileIndex = this.fileIndex;
                this.successCb(res);
                var ticket = QOWT.mxe.remoteFileInfoCache.removeInfo(this.uri);

                if (ticket) {
                    this.$.dlManager.call({
                        ticket: ticket
                    }, {
                        onSuccess: "",
                        onFailure: "",
                        method:    "deleteDownloadedFile"
                    });
                }
                break;

            case 'failed':
                if (inEvent.detail.error === "19") { // It's already deleted from the server so just call success
                    res.success   = true;
                    res.fileIndex = this.fileIndex;
                    this.successCb(res);
                } else {
                    this.failureCb(res);
                    QOWT.MX.handleError(inEvent.detail.error, inEvent.detail.msg);
                }
                break;

            default:
                break;
        }

        QOWT.EVT.removeListener(window.document, 'qowt:mxdeleteremotefile', this.deleteRemoteFileHandler);
        QOWT.EVT.removeListener(window.document, 'qowt:error', this.mxFailureHandler);
    },

    /**
     *
     * @param {Object} inUri
     * @param {Object} inAccountInfo
     * @param {Object} inSuccess
     * @param {Object} inFailure
     */
    getFilePathToRemoteFile: function(inUri, inAccountInfo, inSuccess, inFailure) {
        QOWT.utils.log("RemoteFileCacheService getFilePathToRemoteFile");

        this.cancel();
        this.cancelling  = false;
        this.successCb   = inSuccess;
        this.failureCb   = inFailure;
        this.uri         = inUri;
        this.accountInfo = inAccountInfo;

        // MODERN REROUTE: revived-cloud downloads go through the account's service downloadFile
        // (modern TLS via bundled curl) instead of getDownloadUrl + the dead downloadmanager path.
        if (inAccountInfo && inAccountInfo._id && this._modernSvc(inAccountInfo)) {
            this._modernDownload(inUri, inAccountInfo, inSuccess, inFailure);
            return;
        }

        QOWT.EVT.addListener(window.document, 'qowt:mxgetremotefileinfo', this.gotRemoteFileInfoHandler);
        QOWT.EVT.addListener(window.document, 'qowt:error',               this.mxFailureHandler);

        QOWT.mxe.GetRemoteItemInfo(this, this.accountInfo, this.uri);
    },

    // MODERN REROUTE: download one cloud file to the SAME local cache path QuickOffice's native
    // viewer reads from, then fire the existing successCb(unique, name, account, mime). Box/
    // OneDrive/Drive locators are opaque ids, so recover the real filename (with its extension -
    // the viewer picks its renderer from it) via the uri->name map filled during listing.
    _modernDownload: function(inUri, inAccountInfo, inSuccess, inFailure) {
        var name = (QOWT.mxRevivalNames && QOWT.mxRevivalNames[inUri]) || inUri;
        var slash = name.lastIndexOf("/");
        if (slash >= 0) { name = name.substring(slash + 1); }
        var unique = QOWT.MX.createUniqueTargetFilename(name);
        var dot = name.lastIndexOf("."), ext = (dot >= 0) ? name.substring(dot + 1) : "";
        this._mdName    = name;
        this._mdUnique  = unique;
        this._mdMime    = QOWT.MX.getMimeType(ext) || "application/octet-stream";
        this._mdAccount = inAccountInfo;
        this._mdSuccess = inSuccess;
        this._mdFailure = inFailure;
        this._modernSvc(inAccountInfo).call(
            { accountId: inAccountInfo._id, dropboxPath: inUri,
              localPath: QOWT.MXConfig.downloadFolder + unique },
            { method: "downloadFile", onSuccess: "_modernDownloadOk", onFailure: "_modernDownloadFail" });
    },

    _modernDownloadOk: function(inSender, inResponse) {
        QOWT.utils.log("RemoteFileCacheService _modernDownloadOk " + this._mdUnique);
        this.doProgress(1, this.uri);
        this._mdSuccess(this._mdUnique, this._mdName, this._mdAccount, this._mdMime);
    },

    _modernDownloadFail: function(inSender, inError) {
        QOWT.utils.log("RemoteFileCacheService _modernDownloadFail " + JSON.stringify(inError));
        if (this._mdFailure) { this._mdFailure(); }
    },

    /**
     *
     * @param {Object} inEvent
     *
     * @protected
     */
    _gotRemoteFileInfo: function(inEvent) {
        QOWT.utils.log("RemoteFileCacheService _gotRemoteFileInfo " + JSON.stringify(inEvent.detail));

        if (this.cancelling) {
            QOWT.utils.log("RemoteFileCacheService _gotRemoteFileInfo cancelling");
            return;
        }

        switch (inEvent.detail.status) {
        case 'started':
            return;

        case 'completed':
            this.freshRemoteInfo = inEvent.detail.info;
            var localInfo = QOWT.mxe.remoteFileInfoCache.getInfo(this.uri);

            if (QOWT.mxe.remoteFileInfoCache.InfosMatch(this.freshRemoteInfo, localInfo)) { // Use cached file
                QOWT.utils.log("RemoteFileCacheService _gotRemoteFileInfo use cached file: " + localInfo.uniqueTargetFilename);

                this.doProgress(1, this.uri);
                this.successCb(localInfo.uniqueTargetFilename, localInfo.name, this.accountInfo, this.freshRemoteInfo.type);
                QOWT.mxe.remoteFileInfoCache.updateInfo(localInfo); // Update it so that it will move up in the cache list
            } else {
                if (!localInfo) {
                    this.freshRemoteInfo.uniqueTargetFilename = QOWT.MX.createUniqueTargetFilename(this.freshRemoteInfo.name);
                } else {
                    this.freshRemoteInfo.uniqueTargetFilename = localInfo.uniqueTargetFilename;
                }

                var url = QOWT.mxe.getDownloadUrl(this.freshRemoteInfo.uri, this.accountInfo);

                QOWT.utils.log("RemoteFileCacheService _gotRemoteFileInfo start loading file into " + this.freshRemoteInfo.uniqueTargetFilename);
                QOWT.utils.log("RemoteFileCacheService _gotRemoteFileInfo start loading frmo " + url);

                this.$.dlManager.call({
                    target:         url,
                    targetDir:      QOWT.MXConfig.downloadFolder,
                    targetFilename: this.freshRemoteInfo.uniqueTargetFilename,
                    subscribe:      true
                }, {
                    onSuccess: "_downloadSuccess",
                    onFailure: "_downloadFailure",
                    method:    "download"
                });
            }
            break;

        case 'failed':
            QOWT.utils.log("RemoteFileCacheService _gotRemoteFileInfo failed");

            QOWT.EVT.removeListener(window.document, 'qowt:error', this.mxFailureHandler);
            QOWT.MX.handleError(inEvent.detail.error, inEvent.detail.msg);
            this.failureCb();
            break;

        default:
            break;
        }

        QOWT.EVT.removeListener(window.document, 'qowt:mxgetremotefileinfo', this.gotRemoteFileInfoHandler);
        QOWT.EVT.removeListener(window.document, 'qowt:error', this.mxFailureHandler);
    },

    /**
     *
     * @param {Object} inSender The object that generated this event.
     * @param {Object} inResult
     *
     * @protected
     */
    _downloadSuccess: function(inSender, inResult) {
        QOWT.utils.log("RemoteFileCacheService _downloadSuccess " + JSON.stringify(inResult));

        this.cancelTicket = undefined;

        if (inResult.completionStatusCode) {
            switch (inResult.completionStatusCode) {
                case 200:
                    // OK
                    QOWT.utils.log("RemoteFileCacheService _downloadSuccess completed");

                    this.doProgress(1, this.uri);
                    this.freshRemoteInfo.downloadTicket = inResult.ticket;
                    var deletedTicket = QOWT.mxe.remoteFileInfoCache.addInfo(this.freshRemoteInfo, this.freshRemoteInfo.uniqueTargetFilename);

                    QOWT.utils.log("RemoteFileCacheService _downloadSuccess completed should delete: " + deletedTicket);

                    if (deletedTicket) {
                        this.$.dlManager.call({
                            ticket: deletedTicket
                        }, {
                            onSuccess: "",
                            onFailure: "",
                            method:    "deleteDownloadedFile"
                        });
                    }

                    this.successCb(this.freshRemoteInfo.uniqueTargetFilename, this.freshRemoteInfo.name, this.accountInfo, this.freshRemoteInfo.type);
                    break;

                case 12:
                    // Cancel in progress
                    QOWT.utils.log("RemoteFileCacheService _downloadSuccess canceled");

                    QOWT.mxe.remoteFileInfoCache.removeInfo(this.freshRemoteInfo.uri);
                    break;

                default:
                    QOWT.utils.log("RemoteFileCacheService _downloadSuccess error: " + inResult.completionStatusCode);

                    this.failureCb();
                    QOWT.mxe.remoteFileInfoCache.removeInfo(this.freshRemoteInfo.uri);
                    break;
            }

            this.cancelTicket = null;
            return;
        }

        QOWT.utils.log("RemoteFileCacheService _downloadSuccess received: " + inResult.amountReceived + " / " + inResult.amountTotal);

        if (inResult.amountReceived && inResult.amountTotal) {
            this.doProgress(inResult.amountReceived / inResult.amountTotal, this.uri);
        }

        if (!this.cancelTicket) {
            // Return the download ticket, which is needed if the user asks to cancel the download
            this.cancelTicket = inResult.ticket;
        }
    },

    /**
     *
     * @param {Object} inSender The object that generated this event.
     * @param {Object} inResult
     *
     * @protected
     */
    _downloadFailure: function(inSender, inResult) {
        QOWT.utils.log("RemoteFileCacheService _downloadFailure");

        this.failureCb();
    },

    /**
     *
     * @param {Object} inSender The object that generated this event.
     * @param {Object} inResult
     *
     * @protected
     */
    _mxFailure: function(inResult) {
        QOWT.utils.log("RemoteFileCacheService _mxFailure");

        QOWT.EVT.removeListener(window.document, 'qowt:mxgetremotefileinfo', this.gotRemoteFileInfoHandler);
        QOWT.EVT.removeListener(window.document, 'qowt:error',               this.mxFailureHandler);

        if(inResult) {
            this.failureCb(inResult.detail);
        } else {
            this.failureCb();            
        }
    }
});

/**
 * This component handles listing remote files (ie. file lists of remote folders).
 *
 * @class
 */
enyo.kind({
    name: "RemoteFileService",
    kind: "Component",

    events: {
        onRootListError:  "",
        onOtherListError: ""
    },

    components: [{
        // MODERN REROUTE: statically-declared cloud service, repointed per account by _modernSvc.
        // Static (not lazily createComponent'd) so it's fully wired at initial render - see _modernSvc.
        name:      "modernSvc",
        kind:      "PalmService"
    }],

    // MODERN REROUTE (webos-synergy-revival): return the account's revival cloud PalmService,
    // account-derived via QOWT.MX.modernServiceUriForAccount (null for a legacy MX account) - no
    // per-provider list here, so a new provider needs no change. The service is the STATIC
    // this.$.modernSvc repointed per account, NOT a lazily createComponent'd one: an Enyo
    // dynamically-created PalmService is not fully wired until its owner's next render() pass -
    // which only happened when navigating between providers - so the FIRST list/upload right after
    // opening a provider silently dropped its reply ("open kDrive first fails, but works after
    // visiting Box and back"). A statically-declared service is wired at initial render, so the
    // first call is reliable.
    _modernSvc: function(account) {
        var uri = QOWT.MX.modernServiceUriForAccount(account);
        if (!uri) { return null; }
        this.$.modernSvc.setService(uri);
        return this.$.modernSvc;
    },

    /**
     * Called when the component is first made.
     */
    create: function() {
        QOWT.utils.log("RemoteFileService create");

        this.inherited(arguments);

        this.accountInfo = {};
        this.gotServicesHandler     = this._handleGotServices.bindAsEventListener(this);
        this.serviceLoginHandler    = this._handleServiceLogin.bindAsEventListener(this);
        this.filesRootHandler       = this._handleFilesRoot.bindAsEventListener(this);
        this.filesAtLocationHandler = this._handleFilesAtLocation.bindAsEventListener(this);
        this.errorHandler           = this._handleError.bindAsEventListener(this);

        var locale = enyo.g11n.currentLocale().getLocale();
        QOWT.utils.log("RemoteFileService get locale: " + locale);
        QOWT.MXConfig.locale = locale;
        
        //QOWT.utils.log("RemoteFileService create OUT");
    },

    /**
     * Called by the framework when this component is being destroyed.
     */
    destroy: function() {
        this.inherited(arguments);
    },

    /**
     *
     */
    cancelAll: function() {
        QOWT.mxe.CancelRequestFromGroup(this);
        // MODERN REROUTE: deliberately do NOT touch the in-flight modern listFolder here. The
        // picker pairs cancelAll()+getFiles() per open, but a bare cancelRemoteAction()->cancelAll()
        // also fires mid-load; when this used to bump the view token AND enyo Service.cancel() the
        // request, it ORPHANED the current folder's valid in-flight reply (Service.cancel destroys
        // the Request so its reply never arrives), and only the 15s watchdog recovered -> "kDrive
        // doesn't load on first open, then appears after ~15s". Dedup is handled entirely by
        // _modernList bumping this._mlToken per open (older token's reply is dropped in
        // _modernListOk, and _mlDone blocks a second render), so the double getFiles still can't
        // double-render, and a late reply from a folder we navigated away from is still dropped -
        // WITHOUT killing the reply the user is currently waiting for.
    },

    /**
     * Returns a list of remote files
     *
     * @param {Object} inSource  A JSON object which should include following parameters:
     *     - uri
     *     - folderUri
     *     - login
     *     - pwd
     *     - mxId
     *     - _id
     * @param {Object} inCallback
     * @param {Boolean} inJustFolders - if true, returns only folders
     */
    // MODERN REROUTE: list a folder via the account's revival service listFolder and feed the
    // existing _processFiles(), so the browser UI is unchanged.
    _modernList: function(inSource, inCallback) {
        var path = inSource.folderUri || "";
        this.callback    = inCallback;
        this.locationUri = path;
        if (this.rootUri === undefined) { this.rootUri = ""; }
        // _processFiles() writes this.folderCache[...]; the legacy path seeds it in
        // _startFetching(), which the modern reroute bypasses. Without this, _processFiles threw
        // "Cannot set property 'ROOT' of undefined" on every list (after the callback had already
        // rendered), leaving the error listener dangling and the cache unpopulated.
        if (!this.folderCache) { this.folderCache = []; }
        this._mlParent   = path;
        // COLD-START RESILIENCE: the revival services idle-exit after 30s (activityTimeout), so
        // the first open after idle/LunaSysMgr-restart hits a cold service whose first listFolder
        // reply is slow (boxnet's OAuth+API cold path measured ~7.5s; kDrive ~1.5s). Arm a
        // watchdog that re-issues the list for THIS folder if no reply lands, capped at 3 tries.
        // All attempts for one open share this._mlToken, so whichever reply arrives FIRST renders
        // (see _modernListOk) - a slow-but-valid cold reply is no longer discarded just because
        // the watchdog already re-issued. A new folder open / cancelAll bumps the token, which is
        // what supersedes an in-flight list (not the per-attempt retry).
        this._mlToken    = (this._mlToken || 0) + 1;
        if (this._mlWatch) { window.clearTimeout(this._mlWatch); this._mlWatch = null; }
        this._mlSource = inSource;
        this._mlDone   = false;
        this._mlTries  = 0;
        this._mlIssue();
    },

    // Issue (or re-issue) the current folder's listFolder and arm the watchdog. All attempts for
    // one open carry the same this._mlToken, so the first reply to arrive renders (see
    // _modernListOk). Timeout is generous (15s) because a cold OAuth service's first reply can
    // legitimately take ~7.5s - firing sooner just issues a redundant retry (harmless now, but
    // wasteful); the OLD 7s timeout fired ~0.5s before boxnet's cold reply and the reply was
    // then thrown away as "stale", turning one cold start into a 3-try/16s hang.
    _mlIssue: function() {
        var self = this, src = this._mlSource;
        var svc = src && this._modernSvc(src);
        if (!svc || this._mlDone) { return; }
        this._mlTries++;
        if (this._mlWatch) { window.clearTimeout(this._mlWatch); }
        this._mlWatch = window.setTimeout(function() {
            if (self._mlDone) { return; }
            if (self._mlTries < 3) { self._mlIssue(); }   // no reply yet -> re-issue (same token)
            else { self._mlGiveUp(); }
        }, 15000);
        svc.call(
            { accountId: src._id, path: this._mlParent },
            { method: "listFolder", onSuccess: "_modernListOk", onFailure: "_modernListFail",
              mlToken: this._mlToken });
    },

    _mlGiveUp: function() {
        if (this._mlDone) { return; }
        this._mlDone = true;
        if (this._mlWatch) { window.clearTimeout(this._mlWatch); this._mlWatch = null; }
        QOWT.utils.log("RemoteFileService _modernList: giving up after retries");
        if (this.callback) { this.callback([], this.locationUri); }
    },

    _modernListOk: function(inSender, inResponse, inRequest) {
        // Dedupe keyed on the folder-open TOKEN, not a per-attempt generation. A reply is stale
        // only if its token no longer matches the current view (navigated away, or the picker's
        // double getFiles). Retries of the SAME open share the token, so the FIRST reply to
        // arrive renders and marks _mlDone; later retry replies are then dropped by the _mlDone
        // guard. This is the fix for the intermittent "empty on first open": the old per-attempt
        // generation discarded a valid cold reply that landed just after the watchdog re-issued.
        if (inRequest && inRequest.mlToken && inRequest.mlToken !== this._mlToken) { return; }
        if (this._mlDone) { return; }
        this._mlDone = true;
        if (this._mlWatch) { window.clearTimeout(this._mlWatch); this._mlWatch = null; }
        var entries = (inResponse && inResponse.entries) || [];
        var mapped = [], i, e, isDir, mime, dot, ext;
        for (i = 0; i < entries.length; i++) {
            e = entries[i];
            isDir = (e.type === "folder");
            if (isDir) {
                mime = "application/directory";
            } else {
                dot = e.name.lastIndexOf(".");
                ext = (dot >= 0) ? e.name.substring(dot + 1) : "";
                mime = QOWT.MX.getMimeType(ext) || "application/octet-stream";
            }
            mapped.push({
                type:         mime,
                name:         e.name,
                uri:          e.path,          // locator - reused as dropboxPath/fileId on download
                size:         e.size,
                lastmodified: e.modified,
                parent:       this._mlParent
            });
            // Remember locator -> real filename so the ID-based services (Box/OneDrive/Drive)
            // can name the downloaded cache file with its real extension - the native viewer
            // picks its renderer from that. (Dropbox's locator is already a path ending in it.)
            QOWT.mxRevivalNames = QOWT.mxRevivalNames || {};
            QOWT.mxRevivalNames[e.path] = e.name;
        }
        this._processFiles(mapped);
    },

    _modernListFail: function(inSender, inError, inRequest) {
        // Ignore a failure belonging to a superseded view (navigated away / double getFiles) -
        // it must not drive retries for the folder now on screen.
        if (inRequest && inRequest.mlToken && inRequest.mlToken !== this._mlToken) { return; }
        QOWT.utils.log("RemoteFileService _modernList FAILED: " + JSON.stringify(inError));
        if (this._mlDone) { return; }
        // A cold/transient failure (curl timeout, service still waking) shouldn't surface an
        // empty folder immediately - re-issue via the watchdog; give up only after the cap.
        if (this._mlTries < 3) {
            var self = this;
            if (this._mlWatch) { window.clearTimeout(this._mlWatch); }
            this._mlWatch = window.setTimeout(function() { if (!self._mlDone) { self._mlIssue(); } }, 1200);
            return;
        }
        this._mlGiveUp();
    },

    getFiles: function(inSource, inCallback, inJustFolders) {
        QOWT.utils.log("RemoteFileService getFiles");

        this.inSource = inSource;
        this.callback = inCallback;
        this.justFolders = inJustFolders;

        // MODERN REROUTE: Dropbox ("drop" = Account.kMXID_DROP_BOX) no longer uses the dead
        // MX proxy - list via com.palm.service.dropbox.
        if (inSource && this._modernSvc(inSource)) {
            this._modernList(inSource, inCallback);
            return;
        }

        QOWT.mxe.CancelRequestFromGroup(this);
        QOWT.EVT.addListener(window.document, 'qowt:error', this.errorHandler);

        var uri = QOWT.MX.getMXUriForService(this.inSource.mxId);
        if (!uri) {
            QOWT.EVT.addListener(window.document, 'qowt:mxgetservices', this.gotServicesHandler);
            QOWT.mxe.ServicesList(this);
        } else {
            this.inSource.uri = uri;
            this._startFetching();
        }
    },

    /**
     *
     * @param {Object} inEvent
     *
     * @protected
     */
    _handleGotServices: function(inEvent) {
        QOWT.utils.log("RemoteFileService _handleGotServices " + inEvent.detail.status);

        switch (inEvent.detail.status) {
            case 'started':
                return;

            case 'completed':
                QOWT.utils.storeObject(QOWT.MXConfig.serviceListStorageName, inEvent.detail.services);
                var uri = QOWT.MX.getMXUriForService(this.inSource.mxId);

                if (!uri) {
                    this._handleError(inEvent);
                    break;
                }

                this.inSource.uri = uri;
                this._startFetching();
                break;

            case 'failed':
                QOWT.utils.log("_handleServiceLogin: " + inEvent.detail.info);
                this._handleError(inEvent);
                break;

            default:
                break;
        }

        QOWT.EVT.removeListener(window.document, 'qowt:mxgetservices', this.gotServicesHandler);
    },

    /**
     *
     *
     * @protected
     */
    _startFetching: function() {
        if (this.inSource.folderUri) { // Opening sub folder -> let's get straight to business
            QOWT.utils.log("RemoteFileService _startFetching getting subfolder");

            this.prevUri = this.locationUri;
            this.locationUri = this.inSource.folderUri;

            this.accountInfo.uri      = this.inSource.uri;
            this.accountInfo.username = this.inSource.username;
            this.accountInfo.password = this.inSource.password;
            this.accountInfo._id      = this.inSource._id;
            this.accountInfo.mxId     = this.inSource.mxId;
            
            if (this.folderCache[this.locationUri]) {
                QOWT.utils.log("RemoteFileService _startFetching straight from cache");

                var files = this.folderCache[this.locationUri];
                this.callback(files);
            } else {
                QOWT.utils.log("RemoteFileService _startFetching from server");

                QOWT.EVT.addListener(window.document, 'qowt:mxgetfilesatlocation', this.filesAtLocationHandler);
                QOWT.mxe.GetFilesForAccountAtLocation(QOWT.uid, this.accountInfo, this.locationUri);
            }
        } else { // Opening root folder -> need to login and get the root entry first
            QOWT.utils.log("RemoteFileService _startFetching getting rootfolder");

            this.prevUri = undefined;
            this.accountInfo.uri      = this.inSource.uri;
            this.accountInfo.username = this.inSource.username;
            this.accountInfo.password = this.inSource.password;
            this.accountInfo._id      = this.inSource._id;
            this.accountInfo.mxId     = this.inSource.mxId;
            this.folderCache = [];

            QOWT.EVT.addListener(window.document, 'qowt:mxservicelogin', this.serviceLoginHandler);
            QOWT.EVT.addListener(window.document, 'qowt:error',          this.errorHandler);

            QOWT.mxe.serviceLogin(this, this.accountInfo);
        }
    },

    /**
     *
     * @param {Object} inEvent
     *
     * @protected
     */
    _handleServiceLogin: function(inEvent) {
        QOWT.utils.log("RemoteFileService _handleServiceLogin " + inEvent.detail.status);

        switch (inEvent.detail.status) {
            case 'started':
                return;

            case 'completed':
                QOWT.utils.log("services: " + JSON.stringify(inEvent.detail.services));

                QOWT.EVT.addListener(window.document, 'qowt:mxgetfilesroot', this.filesRootHandler);
                QOWT.mxe.GetRootLocationForAccount(QOWT.uid, this.accountInfo);
                break;

            case 'failed':
                QOWT.utils.log("_handleServiceLogin: " + inEvent.detail.info);

                this._handleError(inEvent);
                break;

            default:
                break;
        }

        QOWT.EVT.removeListener(window.document, 'qowt:mxservicelogin', this.serviceLoginHandler);
    },

    /**
     *
     * @param {Object} inEvent
     *
     * @protected
     */
    _handleFilesRoot: function(inEvent) {
        QOWT.utils.log("RemoteFileService _handleFilesRoot " + inEvent.detail.status);

        switch (inEvent.detail.status) {
            case 'started':
                return;

            case 'completed':
                this.locationUri = inEvent.detail.root;
                this.rootUri = inEvent.detail.root;
                QOWT.EVT.addListener(window.document, 'qowt:mxgetfilesatlocation', this.filesAtLocationHandler);
                QOWT.mxe.GetFilesForAccountAtLocation(QOWT.uid, this.accountInfo, this.locationUri);
                break;

            case 'failed':
                QOWT.utils.log("_handleFilesRoot can't get root");
                this._handleError(inEvent);
                break;

            default:
                break;
        }

        QOWT.EVT.removeListener(window.document, 'qowt:mxgetfilesroot', this.filesRootHandler);
    },

    /**
     *
     * @param {Object} inEvent
     *
     * @protected
     */
    _handleFilesAtLocation: function(inEvent) {
        QOWT.utils.log("RemoteFileService _handleFilesAtLocation " + inEvent.detail.status);

        switch (inEvent.detail.status) {
            case 'started':
                return;

            case 'completed':
                this._processFiles(inEvent.detail.filelist);
                break;

            case 'failed':
                QOWT.utils.log("_handleFilesAtLocation FAILED!!");
                this._handleError(inEvent);
                break;

            default:
                break;
        }

        QOWT.EVT.removeListener(window.document, 'qowt:mxgetfilesatlocation', this.filesAtLocationHandler);
    },

    /**
     *
     * @param {Object} inFilelist
     *
     * @protected
     */
    _processFiles: function(inFilelist) {
        QOWT.utils.log("RemoteFileService _processFiles IN");

        var files = [];
        var i, item;

        for (i = 0; i < inFilelist.length; i++) {
            var name, ext;
            item = {};
            item.mimeType     = inFilelist[i].type;
            if (item.mimeType && item.mimeType.toLowerCase() === "application/directory") {
                item.name      = inFilelist[i].name;
            } else {
                if(this.justFolders) {
                    continue; // don't include non-folders
                }
                var extraction = QOWT.utils.extractFilenameAndExtension(inFilelist[i].name);
                item.name      = extraction.name;
                item.extension = extraction.extension;
            }
            item.uri          = inFilelist[i].uri;
            item.size         = inFilelist[i].size;
            item.modifiedTime = inFilelist[i].lastmodified;
            item.parent       = inFilelist[i].parent;
            
            files.push(item);

            QOWT.utils.log("RemoteFileService add: " + item.name + " . " + item.extension + " type: " + item.type + " modified: " + item.modifiedTime);
        }

        this.callback(files, this.locationUri);

        if (this.locationUri !== this.rootUri) { // Do not cache root
            this.folderCache[this.locationUri] = files;
        } else {
            this.folderCache["ROOT"] = files;
        }

        QOWT.EVT.removeListener(window.document, 'qowt:error', this.errorHandler);

        QOWT.utils.log("RemoteFileService _processFiles OUT");
    },

    /**
     *
     * @param {Event} inEvent
     *
     * @protected
     */
    _handleError: function(inEvent) {
        QOWT.utils.log("RemoteFileService: error happening while getting files");

        QOWT.EVT.removeListener(window.document, 'qowt:error', this.errorHandler);

        if (!this.prevUri) {
            this.doRootListError(inEvent);
        } else {
            this.doOtherListError(inEvent);
        }
    }
});

/**
 * This has not been tested yet. This can be used once we start supporting real remote search.
 *
 * @class
 */
enyo.kind({
    name: "SearchFileService",
    kind: "Component",

    /**
     * Called when the component is first made
     */
    create: function() {
        QOWT.utils.log("SearchFileService create");

        this.inherited(arguments);

        this.accountInfo          = {};
        this.gotServicesHandler   = this._handleGotServices.bindAsEventListener(this);
        this.filesRootHandler     = this._handleFilesRoot.bindAsEventListener(this);
        this.searchResultsHandler = this._handleSearchResults.bindAsEventListener(this);
        this.errorHandler         = this._handleError.bindAsEventListener(this);

        QOWT.utils.log("SearchFileService create OUT");
    },

    /**
     * Called by the framework when this component is being destroyed.
     */
    destroy: function() {
        this.inherited(arguments);
    },

    /**
     *
     * @param {Object}   inAccounts
     * @param {Object}   inName
     * @param {Object}   inContent
     * @param {Function} inAddFilesCb
     * @param {Function} inCompleteCb
     */
    getFiles: function(inAccounts, inName, inContent, inAddFilesCb, inCompleteCb) {
        QOWT.utils.log("SearchFileService getFiles");

        this.name       = inName;
        this.content    = inContent;
        this.addFilesCb = inAddFilesCb;
        this.completeCb = inCompleteCb;
        QOWT.mxe.CancelRequestFromGroup(this);

        this.accounts    = inAccounts;
        this.accountInfo = inAccounts.pop();

        QOWT.EVT.addListener(window.document, 'qowt:error', this.errorHandler);

        this._startNextRound();
    },

    /**
     *
     * @param {Object} inNext
     */
    _startNextRound: function(inNext) {
        if (!this.accountInfo) {
            QOWT.utils.log("SearchFileService COMPLETE");
            if (this.completeCb) {
                this.completeCb();
            }
            return;
        }

        if (!this.accountInfo.uri) {
            var uri = QOWT.MX.getMXUriForService(this.accountInfo.mxId);
            if (!uri) {
                QOWT.EVT.addListener(window.document, 'qowt:mxgetservices', this.gotServicesHandler);
                QOWT.mxe.ServicesList(this);
                return;
            } else {
                this.accountInfo.uri = uri;
            }
        }

        if (!this.accountInfo.rootUri) {
            QOWT.EVT.addListener(window.document, 'qowt:mxgetfilesroot', this.filesRootHandler);
            QOWT.mxe.GetRootLocationForAccount(QOWT.uid, this.accountInfo);
        } else {
            QOWT.EVT.addListener(window.document, 'qowt:mxsearchremotefiles', this.searchResultsHandler);
            QOWT.mxe.SearchRemoteItems(this, this.accountInfo, this.accountInfo.rootUri, this.name, this.content, inNext);
        }
    },

    /**
     *
     * @param {Object} inEvent
     */
    _handleGotServices: function(inEvent) {
        QOWT.utils.log("SearchFileService _handleGotServices " + inEvent.detail.status);

        switch (inEvent.detail.status) {
            case 'started':
                return;

            case 'completed':
                QOWT.utils.storeObject(QOWT.MXConfig.serviceListStorageName, inEvent.detail.services);
                var uri = QOWT.MX.getMXUriForService(this.accountInfo.mxId);
                if (!uri) { // Skip to next one
                    this.accountInfo = this.accounts.pop();
                } else {
                    this.accountInfo.uri = uri;
                }
                this._startNextRound();
                break;

            case 'failed':
                QOWT.utils.log("_handleServiceLogin: " + inEvent.detail.info);
                this._handleError(inEvent);
                break;

            default:
                break;
        }

        QOWT.EVT.removeListener(window.document, 'qowt:mxgetservices', this.gotServicesHandler);
    },

    /**
     *
     * @param {Object} inEvent
     */
    _handleFilesRoot: function(inEvent) {
        QOWT.utils.log("SearchFileService _handleFilesRoot " + inEvent.detail.status);

        switch (inEvent.detail.status) {
            case 'started':
                return;

            case 'completed':
                this.accountInfo.rootUri = inEvent.detail.root;
                this._startNextRound();
                break;

            case 'failed':
                QOWT.utils.log("_handleFilesRoot can't get root");
                this.accountInfo = this.accounts.pop();
                this._startNextRound();
                break;

            default:
                break;
        }

        QOWT.EVT.removeListener(window.document, 'qowt:mxgetfilesroot', this.filesRootHandler);
    },

    /**
     *
     * @param {Object} inEvent
     *
     * @protected
     */
    _handleSearchResults: function(inEvent) {
        QOWT.utils.log("SearchFileService _handleSearchResults " + inEvent.detail.status);

        switch (inEvent.detail.status) {
            case 'started':
                return;

            case 'completed':
                this._processFiles(inEvent.detail.filelist);
                if (inEvent.detail.filelist.length && inEvent.detail.next) {
                    this._startNextRound(inEvent.detail.next);
                } else {
                    this.accountInfo = this.accounts.pop();
                    this._startNextRound();
                }
                break;

            case 'failed':
                this.accountInfo = this.accounts.pop();
                this._startNextRound();
                break;

            default:
                break;
        }
    },

    /**
     *
     * @param {Object} inFilelist
     *
     * @protected
     */
    _processFiles: function(inFilelist) {
        QOWT.utils.log("SearchFileService _processFiles IN");

        var files = [];
        var i, item, extraction;

        for (i = 0; i < inFilelist.length; i++) {
            extraction = QOWT.utils.extractFilenameAndExtension(inFilelist[i].name);

            item = {};
            item.uri          = inFilelist[i].uri;
            item.name         = extraction.name;
            item.extension    = extraction.extension;
            item.size         = inFilelist[i].size;
            item.modifiedTime = inFilelist[i].lastmodified;
            item.mimeType     = inFilelist[i].type;
            item.parent       = inFilelist[i].parent;

            files.push(item);

            QOWT.utils.log("RemoteFileService add: " + item.name + " . " + item.extension + " type: " + item.type + " modified: " + item.modifiedTime);
        }

        if (this.addFilesCb) {
            this.addFilesCb(files);
        }

        QOWT.utils.log("SearchFileService _processFiles OUT");
    },

    /**
     *
     * @param {Object} inEvent
     *
     * @protected
     */
    _handleError: function(inEvent) {
        QOWT.utils.log("SearchFileService: error happening while getting files for account " + this.accountInfo.username);

        if (this.addFilesCb) {
            this.addFilesCb();
        }
    }
});
