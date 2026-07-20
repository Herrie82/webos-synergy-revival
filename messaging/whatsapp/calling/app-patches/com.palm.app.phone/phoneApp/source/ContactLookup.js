enyo.kind({
	name: "ContactLookup",
	kind: enyo.VFlexBox,    	
	mediaCaptureInitialized: false,
	IMSTATUS: {
		AVAILABLE: 0,
		OFFLINE: 4
	},	
	events: {
		onShowTabMenu: ""
	}, 
	components: [{
		//video is disabled for DB+
		/*name: "pane", kind: "Pane", flex: 1, transitionKind: enyo.transitions.Simple, components: [
			{name: "main", kind: "VFlexBox", className: "contact-list", pack: "justify", components: [
				{name: "streamTheVideo", kind: "Video", /*showControls: false , style: "width:88%;height:33%;top:10%;left:6%;position:fixed"}, 
				{name: "mediaCapture", kind: "enyo.MediaCapture", onInitialized: "loadMediaCap", onLoaded: "mediaCapLoaded", onVideoCaptureComplete: "videoTaken", /*onDurationChange:"updateTime", onError: "someErrorOccured"}, 
				{name: "group", kind: enyo.VFlexBox, height: "50%", width: "88%", style: "top:45%;left:6%;position:fixed", components: [
					{name: "textVInput", style: "margin-bottom: 5px;", kind: "SearchInput", spellcheck: false, autocorrect: false, changeOnKeypress: true,
							keypressChangeDelay: 200, onchange: "showVideoContacts", onCancel: "showVideoContacts"}, 
					{kind: "VideoAddressingList", flex: 1, addressTypes: ["ims"], imTypes: ["type_skype"], showVideo: true,
							onSelect: "addressVideoSelected", onVideoCall: "videoCallClicked"}
				]}, 
				{name: "controlNoSkype", kind: enyo.VFlexBox, align: "center", style: "position: absolute; top:65%; ", width: "100%", showing: false, components: [
					{name: "skypeCaption", layoutkind: "HFlexBox", style: "color: white", pack: "center", 
						content: $L("Add a Skype account to view video contact list")}, 
					{align: "center", style: "position: absolute;", width: "100%", pack: "center", components: [
						{kind: "Button", name: "skypeAccBtn", caption: $L("Add Account"), onclick: "skypeAcctClick"},
						{name: "spinner", kind: "Spinner", showing: false, pack: "center", shownWhenSpinning: true} 
					]},
					
				]}
			]}, 
			{name: "accountsView", kind: "AccountsUI", capability: "PHONE", onAccountsUI_Done: "accountsDone", lazy: true}, 
		]}*/	
		name: "pane", kind: "Pane", flex: 1, transitionKind: enyo.transitions.Simple, components: [
			{name: "main", kind: "VFlexBox", className: "contact-list", components: [
				{name: "group", kind: enyo.VFlexBox, flex: 1, components: [
					{kind: "SearchInput", name: "textVInput", style: "margin: 15px;", className: "enyo-rounded-input", spellcheck: false, autocorrect: false, hint: $L("Enter Name"), changeOnKeypress: true,
							keypressChangeDelay: 200, onchange: "showVideoContacts", onCancel: "showVideoContacts"}, 
					{kind: "VideoAddressingList", flex: 1, addressTypes: ["ims"], imTypes: ["type_skype"], showVideo: true,
							onSelect: "videoCallClicked", onVideoCall: "videoCallClicked"}
				]}, 
				{name: "controlNoSkype", kind: enyo.VFlexBox, align: "center", showing: false, components: [
					{name: "skypeCaption", layoutkind: "HFlexBox", className:"skype-captions", pack: "center", 
						content: $L("Add a Skype account to view video contact list")}, 
					{align: "center", pack: "center", components: [
						{kind: "Button", name: "skypeAccBtn", className:"enyo-notification-button", width:"150px", caption: $L("Add Account"), onclick: "skypeAcctClick"},
						{name: "spinner", kind: "Spinner", showing: false, pack: "center", shownWhenSpinning: true} 
					]},
					
				]}
			]}, 
			{name: "accountsView", kind: "AccountsUI", capability: "PHONE", onAccountsUI_Done: "accountsDone", lazy: true}, 
		]}			
	],
	create: function() {
		this.inherited(arguments);
		this.buddyStatusDirty = true;//force update listview
		this._updateBuddystatus = enyo.hitch(this, "updateBuddyStatus");
		enyo.application.Cache.skypeBuddyCache.registerBuddyStatus(this._updateBuddystatus);
	},
	
	destroy: function() {
		if(enyo.application.Cache.skypeBuddyCache) {
			enyo.application.Cache.skypeBuddyCache.unregisterBuddyStatus(this._updateBuddystatus);
		}
		this.inherited(arguments);
	},	
	
	handleLaunch: function(params) {
		// tell preference we're launched, this value comes strictly from prefDB
		if (enyo.application.Cache.isFirstTimeLaunched !== true) {
			enyo.log("update isFirstTimeLaunched in contactlookup");
			enyo.application.Cache.isFirstTimeLaunched = true; 
			enyo.application.SystemStatus.setFirstTimeLaunchRecord(true);
		}		

		//video is disabled for DB+
		/*if ('cleanup' in params) {
			//before the state is exited, we call cleanup.  Use this chance to stop Capture
			enyo.log("debug: stop the video capturing");
			this.stopVideo();
			return; 
		} else if ('deactivate' in params){
			enyo.log("debug: unload the media");		
			this.unloadMedia();
			return;
		}
		else {
			this.onLoad(); 
		}*/
		
		this.$.textVInput.setValue(this.prevVal || (params && params.value) || "");
		if (enyo.application.Utils.getKeyBoardType() !== undefined) {
			this.$.textVInput.forceFocus();
		}
		//this.showVideoContacts();	
		
		this.updateContactLookupUI(params); 	
	},
	
	updateContactLookupUI: function(params) {
		if (enyo.application.Cache.hasVoipAcct === true) {		
			//is skype account signed in?
			this.$.controlNoSkype.hide(); 
			enyo.log("debug: skype acct exist, status "+enyo.application.Cache.skypeStatus);
			switch(enyo.application.Cache.skypeStatus){				
				case 'online':
				{
					this.$.spinner.setShowing(false);		
					var bShowContacts = false; 
					var videoOnlineTotal = enyo.application.Cache.skypeBuddyCache.getVideoBuddyTotal();
					if (videoOnlineTotal === 0) {
						this.$.group.hide(); 	
						this.$.controlNoSkype.show(); 	
						this.$.skypeAccBtn.hide();
						enyo.log("debug: onlinetotal is "+videoOnlineTotal);
						this.$.skypeCaption.setContent($L("No video contacts available"));
					
					} else {

						this.$.group.show();
						this.$.controlNoSkype.hide(); 	
						this.$.skypeAccBtn.hide();

						this.$.textVInput.setValue(this.prevVal || (params && params.value) || "");
						if (enyo.application.Utils.getKeyBoardType() !== undefined) {
							this.$.textVInput.forceFocus();
						}
						this.showVideoContacts();
					}
				}
				break; 
				
				case 'offline':
				{				
					this.$.spinner.setShowing(false);		

					this.$.group.hide(); 	
					this.$.controlNoSkype.show(); 	
					this.$.skypeCaption.setContent($L("Sign in to view video contacts"));		
					this.$.skypeAccBtn.setCaption($L("Sign In"));
					this.$.skypeAccBtn.show();
				}
				break; 
				
				case 'logging-on':
				case 'retrieving-buddies':
				default: 
				{				
					this.$.group.hide(); 	
					this.$.controlNoSkype.show(); 	
					this.$.skypeCaption.setContent($L("Retrieving..."));		
					this.$.skypeAccBtn.hide();
				}
				break; 
								
			}
		} else {
			//no skype account
			this.$.group.hide(); 					
			this.$.controlNoSkype.show(); 	
			this.$.spinner.setShowing(false);
			this.$.skypeCaption.setContent($L("Add a Skype account to view video contact list"));		
			this.$.skypeAccBtn.setCaption($L("Add Account"));		
			this.$.skypeAccBtn.show();	
		}
	},
	skypeAcctClick: function() {
		if (this.$.skypeAccBtn.getCaption() === $L("Sign In")){
			this.$.skypeCaption.setContent($L("Signing In"));		
			this.$.skypeAccBtn.hide();
			this.$.spinner.setShowing(true);	
			enyo.application.SystemStatus.saveAvailability(this.IMSTATUS.AVAILABLE, true); 
		} else {
			this.addSkypeAccount();
		}
	}, 
	
	updateBuddyStatus: function () {
		this.buddyStatusDirty = true;
		enyo.log("debug: updateBuddyStatus "+ this.buddyStatusDirty);
		if (enyo.application.UI.getCurrentState() === 'contactlookup') {
			this.updateContactLookupUI(null); 			
			this.showVideoContacts();
		}
	},
	
	showVideoContacts: function() {
		var curVal = this.$.textVInput.getValue();
		
		if((this.prevVal == curVal) && !this.buddyStatusDirty) {
		     enyo.log(this.buddyStatusDirty + " prev search val = curr search val, Skipping Search");
		     return;
		}

		this.prevVal = curVal;
		
		if (curVal.length === 0) {
			this.$.videoAddressingList.cancelSearch(); 
		}
		this.$.videoAddressingList.search(curVal);
		this.buddyStatusDirty = false;
	},
	focusHandler: function() {
		if (enyo.keyboard.isManualMode()){
			enyo.keyboard.setManualMode(false); 
		}		
	},
	addressVideoSelected: function(inSender, inSelected) {
		var transport;
		if (!inSelected)
			return; 
		//video is disabled for DB+			
		//this.unloadMedia(); 
		
		if ( inSelected.address.type == "type_skype" ) {
			transport = enyo.application.CallSynergizer.TRANSPORTS.VOIP;
		} else {
			transport = undefined;
		}
		
		enyo.application.CallSynergizer.dial(inSelected.address.value, undefined, undefined, transport, inSelected.personId, true);
	}, 
	videoCallClicked: function(inSender, inSelected){
		//video is disabled for DB+
		//this.unloadMedia();
		//currently only skype has video so we only take care skype
		if (inSelected.address.type == "type_skype") {
			transport = enyo.application.CallSynergizer.TRANSPORTS.VOIP;
			enyo.application.CallSynergizer.dial(inSelected.address.value, true /*video call*/, undefined, transport, inSelected.personId, true);
		}
	}, 
	addSkypeAccount: function(){		
		if (!enyo.application.Cache.accountTemplate) {
			enyo.log("debug: no account list");
			//enyo.application.SystemStatus.getAccountList();
		}
		else {
			this.doShowTabMenu(false);
			this.$.pane.selectViewByName("accountsView");
			this.$.accountsView.AddAccount(enyo.application.Cache.accountTemplate);			
		}
	}, 	
	accountsDone: function(){
		 this.$.pane.selectViewByName("main");
		 this.doShowTabMenu(true); 
	},	
	
	//video is disabled for DB+
	/*onLoad: function() {
		if(this.mediaCaptureInitialized !== true) {

			enyo.application.Cache.activateCamera = 0;				
			this.$.mediaCapture.initialize(this.$.streamTheVideo);
		} else {
			this.$.mediaCapture.load(enyo.application.Cache.cameras[enyo.application.Cache.activateCamera].uri, enyo.application.Cache.cameras[enyo.application.Cache.activateCamera].fmtC);
		}
	},
	someErrorOccured: function(inSender, response){
		enyo.error("error occured on video capturing "+enyo.json.stringify(response));
	},
	videoTaken: function(inSender, response) {
		enyo.log("debug: videoCaptured ");
	}, 
	showScrim: function(inShowing) {
		this.$.scrim.setShowing(inShowing);
		this.$.spinnerLarge.setShowing(inShowing);
	},	
	mediaCapLoaded: function(){
		enyo.log("debug: mediaCapLoaded");
		//this.showScrim(false); 
		enyo.application.Cache.mediaLoaded = true; 
	},		
	unloadMedia: function() {
		if (enyo.application.Cache.mediaLoaded === true || this.mediaCaptureInitialized === true) {		
			this.stopVideo();
			this.$.mediaCapture.unload();
			enyo.application.Cache.mediaLoaded = false; 
			this.mediaCaptureInitialized = false;
		} 
	}, 
	stopVideo: function() {
		if (this.mediaCaptureInitialized === true) {
			this.$.mediaCapture.stopVideoCapture();
		}
	},
	loadMediaCap: function(inSender, inResponse){
		this.mediaCaptureInitialized = true;
enyo.log(enyo.json.stringify(inResponse));
		enyo.application.Cache.cameras = [];
		var cameraItems =[];
		var x =0;
		//var camerasObj = {};
		for (var format in inResponse){
			if(format.search("video")==0){
				for (i = 0; inResponse[format].supportedVideoFormats.length != i; ++i) {
					fmt2 = inResponse[format].supportedVideoFormats[i];
					
					if (fmt2.mimetype == "video/mp4") {
						break;
					}
				}
				enyo.log(enyo.json.stringify(fmt2));
				
				for (i = 0; inResponse[format].supportedImageFormats.length != i; ++i) {
					
					fmt = inResponse[format].supportedImageFormats[i];
					if (fmt.mimetype == "image/jpeg") {
						break;
					}
				}
				enyo.log(enyo.json.stringify(fmt))
				enyo.application.Cache.cameras.push({
					caption : inResponse[format].description,
					value:x++,
					uri : inResponse[format].deviceUri,
					fmtC : fmt,
					fmtV : fmt2
				})
			}
			
		}
		enyo.log(enyo.json.stringify(enyo.application.Cache.cameras))
		this.$.mediaCapture.load(enyo.application.Cache.cameras[enyo.application.Cache.activateCamera].uri, enyo.application.Cache.cameras[enyo.application.Cache.activateCamera].fmtC);
		//this.$.mediaCapture.load(enyo.application.Cache.cameras[0].uri, enyo.application.Cache.cameras[0].fmtC);

	},*/	

});
