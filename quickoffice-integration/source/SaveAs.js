enyo.kind({
    name: "enyo.SaveAsRichText",
    kind: enyo.RichText,

    resizeHandler: function () {
      // do nothing
    }
});

/**
 * @fileoverview This files contains the "SaveAs" popup component.
 * 
 * @author alevi
 * 
 * @version 1.0
 * 
 */

/*
 * @class
 * 
 * Publicly available methods:
 *   refresh() - Informs the file list sub-widget to re-request the viewable file items.
 */
enyo.kind(
{
    name: "SaveAs",
    kind: "ModalDialog",
    modal: true,
    
    published: {
	/*
	 * Changing this will update the file-name field.  This is useful when clicking on a file item.
	 */
	fileName: "",
	manualModeCache: undefined,

        saveLocation: "",
        fileExtension: ""
    },
    
    statics: {
        /*
         * We store all the filelist array in a list called 'files'. The accounts will be in cell 'accounts' and there will be an empty array in 'locals'
         */
        kACCOUNTLIST: "accounts",
        kLOCALFILES: "locals",
        kALLACCOUNTSSTRING: $L("All Accounts")
     },

    events: {
	/*
	 * Event that fires whenever the scroller requests a new row.
	 * Input parameters:
	 *    a - unknown parameter,
	 *    b - unknown parameter,
	 *    index - Index in list of item (first item in list is index 0).
	 * Return: A file object.  Future: an account object will also be allowed.
	 *    A file object must have the following methods/elements.  Methods return a string.  Elements are strings.  Elements are NOT modified by this widget (R-only). 
	 *      getTimestampFormatted()
	 *      getSizeFormatted()
	 *      getIconPath()
	 *      getFileStem()
	 *      getExtension()
	 *      fileStemHtml
	 *      extensionHtml
	 */
	onSetupRow: "",
	
	/*
	 * Event that fires when the "Save" button is pressed.
	 * Input parameters:
	 *    inElem - unknown parameter
	 *    fileName - Name of file to save as.  Does not include save-as path.  The enclosing type must keep track of current directory.
	 */
	onSave: "",
	
	/*
	 * Event that fires when the "Cancel" button is pressed.
	 * Input parameters:
	 *    inElem - unknown parameter
	 */
	onCancel: "",
	
	/*
	 * Event that fires when a file or directory is tapped.
	 * Input parameters:
	 *     index - Index of element that was clicked.  Index 0 is first item.  Second item is index 1.  Etc.
	 */
	onItemClick: ""
        
    },

    components: [{
      name: "serviceFileExists",
      kind: enyo.PalmService,
		  service: (enyo.fetchAppInfo().id === "com.quickoffice.ar") ? "palm://com.quickoffice.ar.service/" : "palm://com.quickoffice.webos.service/",
      method: "fileExists",
      onSuccess: "fileExistsSuccess",
      onFailure: "fileExistsFailure"
	}, {
	    kind: enyo.HFlexBox,
            flex: 1,
	    components: [
		{    
                    kind: enyo.VFlexBox,
                    flex: 1,
                    components: [
                        {
                            name: "location",
                            style: "text-align: center; font-size: 15pt;"
                        },{
                            name: "title",
	                    content: $L("Choose a location to save:"),
                            style: "text-align: center; font-size: 15pt;"
			    //className: "enyo-text-subheader"
                        }]
                }, {
                    kind:      "Spinner",
                    className: "header-spinner-account"
                }]
	}, {
	    name: "fileStore",
            kind: "FileStore"
        }, {
            name:   "errorMsg",
            kind:   "enyo.Control",
            style:   "font-size: 12px; color : red;",
            content: " ",
            showing: true
	}, {
	    name: "fileNameInput",
	    kind: enyo.SaveAsRichText,
        style: "white-space: pre-wrap;",
	    spellcheck: false,
	    autocorrect: false,
	    onkeydown: "filterEnter",
	    alwaysLooksFocused: true,
	    hint: $L("Type Filename Here")
	}, {
            // Vertical list of files
            name: "localVirtualList",
            className: "saveas-location-list",
            kind: enyo.VirtualList,
            pageSize: 5,
            lookAhead: 2,
            width: "400px",
            height: "200px",
            onSetupRow: "setupRow",
            
            components: [
                {
                    name: "fileItemTemplate",
                    kind: "FileItem", 
                    onConfirm: "deleteFile",
                    onclick: "itemClick"
                }
            ]
        }, {
	    kind: enyo.HFlexBox,
            flex: 1,
	    components: [
		{
		    name: "cancelButton",
		    kind: enyo.Button,
		    caption: $L("Cancel"),
		    flex: 1,
		    onclick: "cancel"
		}, {
		    name: "saveButton",
		    kind: enyo.Button,
		    caption: $L("Save"),
		    className: "enyo-button-affirmative",
		    flex: 1,
		    onclick: "startSave"
		}
	    ]		

	}, {
            name: "overwriteConfirm",
            kind: enyo.Popup,
            components: [
                {
                    kind: enyo.VFlexBox,
                    components: [
                        {
                            name: "overwriteConfirmText"
                        }, {
	                    kind: enyo.HFlexBox,
                            components: [
                                {
		                    name: "overwriteConfirmCancelButton",
		                    kind: enyo.Button,
		                    caption: $L("Cancel"),
		                    flex: 1,
		                    onclick: "overwriteConfirmCancel"
		                }, {
		                    name: "overwriteConfirmReplaceButton",
		                    kind: enyo.Button,
		                    caption: $L("Replace"),
		                    flex: 1,
		                    onclick: "overwriteConfirmReplace"
                                }
                            ]
                        }
                    ]
                }
            ]
	}
    ],
    
    /*
     * The account and folder lists are saved in a 2-dimensional table in 'this.files'
     * this.files[SaveAs.kACCOUNTLIST] includes an array of 'Accounts'. The local account is in cell 'AccountsPane.kLOCAL_ACCOUNT_ID'.
     * The remote accounts use their own "_id" (returned by framework) as their 'cell id'.
     * The folder list of every remote folder is stored in it's own folder array that's in cell "this.files[folder's uri]".
     * Here's an example with random values:
     * this.files[SaveAs.kACCOUNTLIST] Includes array list of accounts
     * this.files[SaveAs.kACCOUNTLIST][AccountsPane.kLOCAL_ACCOUNT_ID] "local account'
     * this.files[SaveAs.kACCOUNTLIST][++HY5JgEZZsl7js1] "User's GDocs account"
     * this.files[SaveAs.kACCOUNTLIST][++HY5JgEZZsl7634] "User's dropbox account"
     * this.files[drop://getdropbox.com/26043768] Array of files in the root folder of the user's dropbox account
     * this.files[drop://getdropbox.com/26043768][drop://getdropbox.com/26043768/Public] Entry in the root folder
     * this.files[drop://getdropbox.com/26043768][drop://getdropbox.com/26043768/Photos] Entry in the root folder
     * this.files[drop://getdropbox.com/26043768/Photos] Array of files in the 'Photos' folder
     * this.files[drop://getdropbox.com/26043768/Photos][drop://getdropbox.com/26043768/Photos/abc]
     */
	
    create: function() {
        this.inherited(arguments);
        this.validateComponents();
        // Create the always-present local (device) account
        this.parentDir = []; // stores Uri of of parent in each node
        this.files = [];
        this.files[SaveAs.kLOCALFILES] = [];
        this.files[SaveAs.kLOCALFILES].push( new Account({
                                                             alias:       SaveAs.kALLACCOUNTSSTRING,
                                                             iconPath:    "images/dark-back-arrow.png",
                                                             uri:         SaveAs.kACCOUNTLIST
                                                         }));
        this.files[SaveAs.kACCOUNTLIST] = [];
        this.files[SaveAs.kACCOUNTLIST].push( new Account({
                                                              _id:         AccountsPane.kLOCAL_ACCOUNT_ID,
                                                              accountType: Account.kACCT_TYPE_LOCAL,
                                                              alias:       $L("My TouchPad"),
                                                              iconPath:    "images/accounts-icon-my-touchpad-48x48.png",
                                                              uri:         SaveAs.kLOCALFILES
                                                          }));
        this.$.fileStore.getAccounts(enyo.hitch(this, "_addAccount"), enyo.hitch(this, "_removeAccount"));
        this.currentUri = SaveAs.kACCOUNTLIST;
        this.currentDir = undefined;
        this.currentAccount = undefined;
    },

    rendered: function() {
        QOWT.utils.log("SaveAs rendered");
        this.inherited(arguments);
        this.origFileName = this.fileName;
    },
    
    showOnlyLocalDrive: function(showOnlyLocalDrive) {
        this.showOnlyLocal = showOnlyLocalDrive;
    },

    _addAccount: function(inAccount) {
        var found = false;
        
        // Iterate across the array of cthis.accountCache[inSender.index]ached accounts (i.e., ones we already know about)
        for (var i = 0; i < this.files[SaveAs.kACCOUNTLIST].length; i++) {
            // If this account matches one in the cache...
            if (inAccount._id === this.files[SaveAs.kACCOUNTLIST][i]._id) {
                // ...note that it was already in our cache
                found = true;
                // ...and replace the cached version with the updated information
                this.files[SaveAs.kACCOUNTLIST][i] = inAccount;
            }
        }
        
        // If we _didn't_ already know about this account...
        if (!found) {
            // ...add it to the end of the list
            this.files[SaveAs.kACCOUNTLIST].push(inAccount);
        }
        // Re-render + re-size the list as providers stream in, so it grows to fit them live
        // (only while the account list is the current view - don't yank a folder view around).
        if (this.currentUri === SaveAs.kACCOUNTLIST) { this.refresh(); }
    },

    _removeAccount: function(inAccount) {
        // Iterate across the array of cached accounts (i.e., ones we already know about)
        for (var i = 0; i < this.files[SaveAs.kACCOUNTLIST].length; i++) {
            // If this account matches one in the cache...
            if (inAccount === this.files[SaveAs.kACCOUNTLIST][i]._id) {
                // ...remove it
                this.files[SaveAs.kACCOUNTLIST].splice(i, 1);
                break;
            }
        }
        if (this.currentUri === SaveAs.kACCOUNTLIST) { this.refresh(); }
    },
    
    refresh: function() {
        this.log("refresh" + arguments);
        this.updateTitle();
        this._sizeListToContent();
        this.$.localVirtualList.refresh();
    },

    // Grow the location list to fit the rows in the current view (the account/provider list, or a
    // folder's contents) up to a cap, then let it scroll. The stock list was a fixed 200px that
    // showed only ~4 providers and hid the rest behind a scroll arrow while leaving lots of empty
    // screen around the dialog. Height is clamped so the dialog still fits comfortably on screen.
    _sizeListToContent: function() {
        var MINROWS = 2, MAXROWS = 8;   // grow to fit, then scroll beyond this many rows
        var list = (this.files && this.files[this.currentUri]) || [];
        var rows = Math.max(MINROWS, Math.min(MAXROWS, list.length || 1));
        var vl = this.$.localVirtualList;
        // Fit the list to an exact whole number of rows by MEASURING the rendered FileItem height
        // (the CSS row spacing lives in .saveas-location-list .file-item). Measuring instead of
        // hard-coding is robust to this old WebKit's box-model quirks - a too-small guess clipped
        // the last row, a too-large one left a gap and hid the scroll indicator. Two passes: size
        // with a best-guess so a row renders, then re-fit to the now-measured height. applyStyle
        // (enyo 0.10 has no setHeight) queues until render; resizeHandler() re-measures the
        // scroller + re-renders and no-ops via hasNode() before the dialog is up.
        var rowH = function() {
            var n = this.$.fileItemTemplate && this.$.fileItemTemplate.hasNode();
            return (n && n.offsetHeight) || 60;
        };
        var h1 = rows * rowH.call(this);
        vl.applyStyle("height", h1 + "px");
        vl.resizeHandler();
        var h2 = rows * rowH.call(this);
        if (h2 !== h1) { vl.applyStyle("height", h2 + "px"); vl.resizeHandler(); }
    },
    
    select: function() {
        this.log("select" + arguments);
    },
    
    setOriginalFileName: function(name) {
        this.originalFileName = name;
        this.setFileName(name);
    },
    
    setFilePath: function(filePath) {
        this.$.fileNameInput.setDisabled(false);
        this.filePath = filePath;
    },
    
    fileNameChanged: function() {
        this.$.fileNameInput.setValue(enyo.string.escapeHtml(this.fileName));
    },
    
    /*
     * @return {Boolean} true if row exists.  false otherwise.
     */
    setupRow: function(a, index) {
        this.log("setupRow" + arguments + " " + index + " uri " + this.currentUri);
        if(index<0) {
            return false; // index not in use
        }
        if(index>=this.files[this.currentUri].length) {
            if(index === 1) {
                    if(this.currentUri === SaveAs.kACCOUNTLIST) {
                        // click into the first item.  Assuming it's the on-device account
                        //enyo.log("attempting to tap into my touchpad...");
                        enyo.asyncMethod(this, "clickOnFirstItem");
                        return false;
                    } else {
                        this.$.fileItemTemplate.setDynamicInfo({content: $L("Folder contains no sub-folders.")}); // TODO need styling
                        return true;
                    }
            } else {
                return false; // index not in use
            }
        }
        if(this.showOnlyLocal && index>0) { // this is hack for PDF, show only local drive
            return false;
        }
        if(this.currentUri===SaveAs.kACCOUNTLIST) {
            this.$.fileItemTemplate.setAccountInfo(this.files[this.currentUri][index]);
        } else {
            if(index===0) { // The 'back' is always 'account' type
                this.$.fileItemTemplate.setAccountInfo(this.files[this.currentUri][index]);
            } else {
                var file = this.files[this.currentUri][index];
                this.$.fileItemTemplate.setFileInfo(file);
            }
        }
        this.log("object added");
        return true;		
    },

    cancel: function() {
        this.doCancel();
        this.$.fileStore.cancelRemoteAction(); // if we are currently fetching a filelist..
        this.currentUri = SaveAs.kACCOUNTLIST; // default to account list if the dlg is opened again
        this.currentDir = undefined;
        setTimeout(this.close.bind(this), 0);
        // restore keyboard mode
        enyo.keyboard.setManualMode(this.manualModeCache);        
    },
    
    closeDlg: function() {
        this.doCancel();
        this.$.fileStore.cancelRemoteAction(); // if we are currently fetching a filelist..
        this.currentUri = SaveAs.kACCOUNTLIST; // default to account list if the dlg is opened again
        this.currentDir = undefined;
        setTimeout(this.close.bind(this), 0);
        // restore keyboard mode (when tapped Save to close dialogue)
        enyo.keyboard.setManualMode(this.manualModeCache);        
    },
    
    saveTheFile: function() {
        var uri = this.currentUri;
        if(uri===SaveAs.kLOCALFILES) {
            uri=QOWT.utils.defaultSavePath();
        }
        this.$.fileNameInput.setDisabled(true);
        this.doSave(this.$.fileNameInput.getValue(), uri, this.files[SaveAs.kACCOUNTLIST][this.currentAccount]);
    },
    
    startSave: function() {
        this.setSaveLocation(QOWT.utils.defaultSavePath() + this.$.fileNameInput.getValue() + "." + this.getFileExtension());

        this.$.spinner.show();

        if (this.currentUri === SaveAs.kACCOUNTLIST) {
            this.showSaveError($L("Choose a location first."));
        } else if (!this.$.fileNameInput.value) {
            this.showSaveError($L("Name field is empty."));
        } else if (this.currentUri === SaveAs.kLOCALFILES) {
            if (this.$.fileNameInput.value.length > 255) {
                this.showSaveError($L("Name is too long."));
            } else {
                enyo.warn(this.getSaveLocation());
                this.$.serviceFileExists.call({ name: this.getSaveLocation() });
            }
        } else {
            this.save();
        }
    },

    fileExistsSuccess: function (inSender, inResponse) {
        var fileExists = inResponse.reply;

        if (fileExists) {
            this.showSaveError($L("A file with this name already exists. Rename file to save in this location."));
        } else {
            this.save();
        }
    },

    fileExistsFailure: function (inSender, inResponse) {
        this.showSaveError($L("There was an error saving the file, please try again."));
    },

    showSaveError: function (msg) {
        this.$.errorMsg.setContent(msg);
        this.$.errorMsg.setShowing(true);
        this.$.spinner.hide();
    },

    save: function () {
        var parsed = this.$.fileNameInput.value.replace(/([*?|<>\:\"\?\;\\\/])/g,"");  // remove locally illegal chars
        parsed = parsed.replace(/^\s+|\s+$/g,""); // remove spaces
                
        if (this.currentUri === SaveAs.kLOCALFILES && (parsed !== this.$.fileNameInput.value || parsed.charAt(0)==='.' || parsed.slice(-1)==='.')) {
            this.showSaveError($L("This name has invalid characters."));
        } else {
            this.saveTheFile();
        }
    },
    
    overwriteConfirmReplace: function() {
            this.saveTheFile();
            this.$.overwriteConfirm.close();
        },

    overwriteConfirmCancel: function() {
            this.$.overwriteConfirm.close();
        },

    clickOnFirstItem: function() {
        this.$.localVirtualList.setShowing(false);
        this.itemClick(undefined, undefined, 0);
    },

    itemClick: function(inItem, inEvent, inIndex) {
        this.log(inIndex + " " + this.files[this.currentUri][inIndex].uri);
        if(this.$.saveButton.disabled) {
            this.log("SaveAs: trying to click on item while save is in process");
            return;
        }
        if(this.currentUri===SaveAs.kACCOUNTLIST) {
            this.currentAccount = inIndex; // remember which account we are using
        }
        this.log("from account " + this.currentAccount);
        this.$.fileStore.cancelRemoteAction(); // if we are currently fetching a filelist, cancel it now
        this.$.spinner.hide();
        if(this.files[this.currentUri][inIndex].uri===SaveAs.kACCOUNTLIST || this.files[this.currentUri][inIndex].uri===SaveAs.kLOCALFILES) {
            // It's either account list or local files -> we already have those lists
            this.currentUri = this.files[this.currentUri][inIndex].uri;
            this.refresh();
            return;
        }
        this.log(inIndex);
        this.log("fetch remote files from " + this.files[this.currentUri][inIndex].alias);

        var newUri = this.files[this.currentUri][inIndex].uri;
        var folderUri = {};
        folderUri.uri = newUri;
        
        //enyo.log("newUri="+newUri);
        //enyo.log("currentDir="+this.currentDir);
        if(this.currentUri!==SaveAs.kACCOUNTLIST) {
            if(newUri) {
                if(this.currentDir && this.currentDir.alias) {
                    this.parentDir[newUri] = this.currentDir.alias;
                } else {
                    this.parentDir[newUri] = FileItem.getFileName(this.currentDir);
                }
            }
           
            if(! this.parentDir[newUri]) {
                this.parentDir[newUri] = SaveAs.kALLACCOUNTSSTRING;
            }
       }
        //enyo.log("new parent dir:"+this.parentDir[newUri]);

//        this.directoryStack.push(this.files[this.currentUri][inIndex]);

        this.currentDir = this.files[this.currentUri][inIndex];

        if(this.files[newUri]) { // it's cached already
            this.log("fetching from cache " + newUri);
            this.currentUri = newUri;
            this.refresh();            
        } else {
            this.log("fetching from server " + newUri);
            var remoteAccDetails = new Account({
                _id:         this.files[SaveAs.kACCOUNTLIST][this.currentAccount]._id,
                accountType: this.files[SaveAs.kACCOUNTLIST][this.currentAccount].accountType,
                alias:       this.files[SaveAs.kACCOUNTLIST][this.currentAccount].alias,
                mxId:        this.files[SaveAs.kACCOUNTLIST][this.currentAccount].mxId,
                password:    this.files[SaveAs.kACCOUNTLIST][this.currentAccount].password,
                username:    this.files[SaveAs.kACCOUNTLIST][this.currentAccount].username
            });
            this.newUri = newUri;

            //this.log("!!!!!!!!!!!! Using: " + this.currentAccount + " " + remoteAccDetails.username + " / " + "XXXXXXXXXXXX" );
            
            // Fire a query for (additional) file items
            enyo.asyncMethod(
                this.$.fileStore,
                "getFileItems",
                remoteAccDetails,
                folderUri, // the folder we want to open
                undefined, // limit (ignored for remote sources)
                undefined, // page (ignored for remote sources)
                this.boundSuccessHandler || (this.boundSuccessHandler = enyo.hitch(this, "onQuerySuccessCB")),
                this.boundFailureHandler || (this.boundFailureHandler = enyo.hitch(this, "onQueryFailureCB")),
                true); // get just the folders
            this.$.spinner.show();
        }

        this.doItemClick(inIndex);
    },
    
    onQuerySuccessCB: function(inResult) {
        this.log("got files: " + inResult.files.length);
        
        if(!this.files[SaveAs.kACCOUNTLIST][this.currentAccount].uri && inResult.uri) { // At the start we don't have the root url of the remote accounts so set it now
            QOWT.utils.log("Setting the root folder uri");
            this.files[SaveAs.kACCOUNTLIST][this.currentAccount].uri = inResult.uri;
            this.newUri = inResult.uri;
            this.parentDir[this.newUri] = SaveAs.kALLACCOUNTSSTRING;
        }

        this.files[this.newUri] = []; // Add 'back' entry

        var parentDir;
        if(this.newUri) {
            parentDir = this.parentDir[this.newUri];
        } else {
            parentDir = SaveAs.kALLACCOUNTSSTRING;
        }

        this.files[this.newUri].push( new Account({
            alias:       parentDir,
            iconPath:    "images/leftarrow.png",
            uri:         this.currentUri // this is the previous url now
        }));
        for(var i=0; i<inResult.files.length; i++) {
            this.files[this.newUri].push(inResult.files[i]);
        }
        this.currentUri = this.newUri;
        this.newUri = undefined;
        this.$.localVirtualList.punt();
        this.$.localVirtualList.reset();
        this.refresh();
        this.$.spinner.hide();
    },

    onQueryFailureCB: function(inErrorId) {
        this.$.spinner.hide();
        this.newUri = undefined;
        switch (inErrorId) {
            case QOWT.ERROR.NoInternet.errorId:
                this.log("No internet");
                break;

            default:
                this.log("Other error");
                break;
        }
    },

    showGenericErrorNote: function(/*errorId*/) { // For example DownloadManager returns random errors eg. when network is disconnected while uploading
        this.$.errorMsg.setContent($L("Error saving file."));
        this.$.errorMsg.setShowing(true);
    },
    
    updateTitle: function() {
        this.$.errorMsg.setShowing(false);
        this.$.spinner.hide();
        if(this.showOnlyLocal || this.files[SaveAs.kACCOUNTLIST].length===1) { // Always show just the local drive
            this.currentDir = undefined;
            this.currentUri = SaveAs.kLOCALFILES;
            this.$.location.setContent($L("Save as:"));
            this.$.title.setShowing(false);
            this.$.location.setShowing(true);
            this.$.saveButton.setShowing(true);
            this.$.localVirtualList.setShowing(false);
        } else if(this.currentUri===SaveAs.kACCOUNTLIST) {
            this.$.localVirtualList.setShowing(true);
            this.$.title.setShowing(true);
            this.$.location.setShowing(false);
            this.$.saveButton.setShowing(false);
        } else {
            var txt;
            txt = $L(" ");
            txt+=this.files[SaveAs.kACCOUNTLIST][this.currentAccount].alias;
            if(this.files[this.currentUri][0].uri !== SaveAs.kACCOUNTLIST) {
                txt+=" / " + this.getNameForUri(this.currentUri); // In case we are not at the top level folder, then add the current folder name into title
            }
            this.$.location.setContent(txt);
            this.$.title.setShowing(false);
            this.$.location.setShowing(true);
            this.$.saveButton.setShowing(true);
        }        
    },
    
    getNameForUri: function(uri) {
        for(var x in this.files) {
            for(var y in this.files[x]) {
                if(this.files[x][y] && uri===this.files[x][y].uri) {
                    return this.files[x][y].fileStem;
                }
            }
        }
        // webos-synergy-revival: no cached entry for this folder. This happens in the Create-New
        // flow, which opens straight at the destination subfolder (e.g. "/My documents"), so the
        // PARENT listing - where the folder's own entry (with its fileStem) lives - was never
        // fetched. Fall back to the path's leaf so the title shows the folder name instead of
        // "undefined" (title was "<account> / undefined"). Path locators aren't URL-encoded here
        // (the adapters build them from raw names), so the leaf is already display-ready.
        if (uri && typeof uri === "string") {
            var leaf = uri.replace(/\/+$/, "");
            leaf = leaf.substring(leaf.lastIndexOf("/") + 1);
            if (leaf) { return leaf; }
        }
        return undefined;
    },

    showSpinner: function() {
        this.$.spinner.show();
        this.$.fileNameInput.setDisabled(true);
        this.$.cancelButton.setDisabled(true);
        this.$.saveButton.setDisabled(true);
    },
    
    hideSpinner: function() {
        this.$.spinner.hide();
        this.$.fileNameInput.setDisabled(false);
        this.$.cancelButton.setDisabled(false);
        this.$.saveButton.setDisabled(false);
    },

    filterEnter: function(inSender, inEvent) {
        if(inEvent && inEvent.keyCode === 13) {
            inEvent.handled();
        }
    },

    log: function() {
        var args = [].splice.call(arguments,0);
        console.log("SaveAs"+arguments.callee.name + ": " + args.join(' '));
    }
}
);

