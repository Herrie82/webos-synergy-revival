/*jslint white: false, onevar: false, nomen:false, plusplus: false */
/*globals enyo */

enyo.kind({
	name: "InternationalCallsPref",
	kind: enyo.VFlexBox,
	className: "enyo-bg",
	events: {
		onShowRegion: "",
                onEditAccount: "",
                onAddAccount: "",
	},
	components: [
	
		{name: "serviceHint", className:"accounts-body-title"},
	
		{kind: "RowGroup", name: "domesticPrefCallServiceRow", caption: $L("DOMESTIC CALLS"), showing: false, components: [ 
		{kind: "Item", layoutKind: "HFlexLayout", align: "center", components: [
			{w: "fill", content: $L("Use"), className: "default-row"},      
		   {kind: "ListSelector", value: "none", name: "domesticPrefCallService", onChange: "onDomesticSelectorChanged", items:[
               {caption: $L("Bluetooth"), value: "com.palm.telephony"}, // value must match string in: CallSynergizer.TRANSPORTS.TIL
               {caption: $L("Skype"), value: "com.palm.skype"},  // value must match string in: CallSynergizer.TRANSPORTS.VOIP
               {caption: $L("Always Ask"), value: "none"}
	       ]}
		]}			   
	]},
      
       {kind: "RowGroup", name: "internationalPref", caption: $L("CALLS"), components: [
           {layoutKind: "HFlexLayout", name: "internationalDialingRow", align: "center", tapHighlight: false, showing: false, components: [
                     {content: $L("International Dialing"), flex: 1},
                     {name: "internationalDialingToggle", kind: "ToggleButton", onChange: "internationalDialingTap", state: false}
			]},
			{kind: "Item", layoutKind: "HFlexLayout", align: "center", name: "preferredIntlCallServiceItem", components: [
				{w: "fill", content: $L("Use"), className: "default-row"},
				{kind: "ListSelector", value: "none", name: "preferredIntlCallServiceRow", onChange: "selectorChanged", items: [
					{caption: $L("Bluetooth"), value: "com.palm.telephony"}, // value must match string in: CallSynergizer.TRANSPORTS.TIL
					{caption: $L("Skype"), value: "com.palm.skype"},  // value must match string in: CallSynergizer.TRANSPORTS.VOIP
					{caption: $L("Always Ask"), value: "none"} 
				]}
			]}
		]},
		
        //<!-- generic accounts from accounts library -- only enabled if PHONE template(s) exists -->
        {name: "accountgroup", kind: "RowGroup", caption: $L("Accounts"), components: [
            {name: "accountsList", kind: "Accounts.accountsList", onAccountsList_AccountSelected: "editAccount"}
        ]},

		// This control uses the enyo version of com.palm.app.skype and accounts library.
		{name: "addAccountButton", kind: "Button", content: $L("Add account"), onclick: "addAccountHandler"},
		{name: "addVvmAccountButton", kind: "Button", content: $L("Add Visual Voicemail"), onclick: "addVvmAccountHandler", showing: false},

		//Service calls
		{name: "prefService", kind: enyo.PalmService, service: enyo.palmServices.system},
        {kind: "Accounts.getAccounts", name: "listAccounts", onGetAccounts_AccountsAvailable: "onGotAccounts"},
		{name: "vvmFirstLaunchPref", kind:"PalmService", service: enyo.palmServices.system, params:{keys:["phoneAppShouldShowVoicemailFirstLaunch"]}, method:"getPreferences", onSuccess:"vvmFirstLaunchPrefResponse", onFailure:"genericFailure"},
		{name: "mailboxQuery", kind: "DbService", method: "find", onSuccess: "mailboxQueryCallback", subscribe: true, reCallWatches: true},
		{name: "simStatus", kind: enyo.PalmService, service: enyo.palmServices.telephony, subscribe: true, method: "simStatusQuery", onSuccess: "simStatusResponse", onFailure: "simStatusResponse"},		
	],
	
	create: function() {
		this.inherited(arguments);

		this.accList = [];
        this._accountTemplates = undefined;
		
		this.showPreferredService();
		this.$.serviceHint.setContent($L("Choose a default service for placing calls when there is a Skype account and a phone connected to this device.")); 

		this.$.prefService.call({
			"keys": ["phonePreferredIntlPhoneService", "phoneInternationalDialingActive", "phoneInternationalDialingRegionId", "phonePreferredDomesticPhoneService"]
		},{
			method: "getPreferences",
			onSuccess: "updateInternationalDialingSettings", 
			onFailure: "updateInternationalDialingSettings"
		});
		
        this.$.accountsList.getAccountsList("PHONE", "com.palm.palmprofile");
        this.getAccounts();

		this.$.vvmFirstLaunchPref.call();

		this.$.mailboxQuery.call(DBModels.Voicemail.getMailBoxWatchQuery());
		this.$.simStatus.call();		
	},
	
	updateCallService: function() {
		this.showPreferredService(); 
	},
	
	showPreferredService: function() {
		//3G with SIM, show different for domestic and international
		if (enyo.application.Cache.platformType !== "none" && enyo.application.Cache.simState === "simready") {
			this.$.domesticPrefCallServiceRow.show();                       
			this.$.internationalPref.setCaption($L("INTERNATIONAL CALLS"));
			this.$.internationalDialingRow.show();
		} else { //wifi or 3G with no SIM
			this.$.domesticPrefCallServiceRow.hide();                       
			this.$.internationalPref.setCaption($L("CALLS"));
			this.$.internationalDialingRow.hide();
		}			
	},	
	
	simStatusResponse: function(inSender, response) {
		enyo.log("simStatusResponse  " + enyo.json.stringify(response));	
		if (response && response.extended) {
			var state = response.extended.state;
			enyo.application.Cache.simState = state; 
			if (this.simState !== enyo.application.Cache.simState){
				this.showPreferredService();
				this.simState = enyo.application.Cache.simState; 
			}
		}
	},	
	
	mailboxQueryCallback: function(inSender, payload) {
		this.$.vvmFirstLaunchPref.call();
	},

	// Shows "Add Visual Voicemail" button only when the service is verizon and vvm mailbox is not created.
	vvmFirstLaunchPrefResponse: function(inSender, response) {
		var showVerizonFirstLaunch = response.phoneAppShouldShowVoicemailFirstLaunch;
		var carrierName = enyo.application.VoicemailService.getCarrierName();
		if ( showVerizonFirstLaunch && carrierName != "verizon") {
			this.$.addVvmAccountButton.setShowing(true);
		}
		else {
			this.$.addVvmAccountButton.setShowing(false);
		}
		this.$.addVvmAccountButton.render();
	},

	getListItem: function(inSender, inIndex) {
		if(inIndex < this.accList.length) {
			var account = this.accList[inIndex];
			var capabilityProvider = this.$.accounts.getPhoneCapabilityProvider(account);
			this.$.itemTitle.setContent(account.loc_name);
			this.$.itemUsername.setContent(account.username);
			this.$.itemImg.setSrc(account.icon ? account.icon.loc_32x32 : "");
			return true;
		}
	},
	
        // User tapped on add account
	addAccountHandler: function () {
         this.doAddAccount(this._accountTemplates);
	},

        // User tapped on account to edit
        editAccount: function(inSender, inResults) {
                this.doEditAccount(inSender, inResults);
        },

	addVvmAccountHandler: function() {
		var accountSetupApp = enyo.application.VoicemailService.getAccountSetupApp();
		if (accountSetupApp === undefined || accountSetupApp == null || accountSetupApp == "") {
			accountSetupApp = "com.palm.app.vzwvvm";
		}
		enyo.log("phoneapp>> launch account setup app = " + accountSetupApp);
		this.$.launchApplication.call({
			id: accountSetupApp,
		});
	},

	//update user's preference on what to use to call
	updateInternationalDialingSettings: function(inSender, payload) {
		if (payload.returnValue) {
 
			if (payload.phonePreferredDomesticPhoneService !== undefined) {
				if (this.$.domesticPrefCallServiceRow) {
				   	this.$.domesticPrefCallService.setValue(payload.phonePreferredDomesticPhoneService);
				}
			} else {
		       if (this.$.domesticPrefCallServiceRow) {
					this.$.domesticPrefCallService.setValue("none"); // Default value must match what is used in preferredPhoneServiceResponse of TelephoneyStatusInterface
		       }
			}    

			if ( payload.phonePreferredIntlPhoneService !== undefined ) {
				if (this.$.preferredIntlCallServiceItem) {
					this.$.preferredIntlCallServiceRow.setValue(payload.phonePreferredIntlPhoneService);
				}
			} else {
				if (this.$.preferredIntlCallServiceItem) {
					this.$.preferredIntlCallServiceRow.setValue("none"); // Default value must match what is used in preferredPhoneServiceResponse of TelephoneyStatusInterface
				}
			}
			
			this.$.internationalDialingToggle.setState(payload.phoneInternationalDialingActive);  
		}
	},
	
	selectorChanged: function(event) {
		this.$.prefService.call({
			"phonePreferredIntlPhoneService": event.value
		}, {
			method: "setPreferences",
			onSuccess: "",
			onFailure: ""
		});
	},	
	
	onDomesticSelectorChanged: function(event) {
		this.$.prefService.call({
			"phonePreferredDomesticPhoneService": event.value
		}, {
			method: "setPreferences",
			onSuccess: "",
			onFailure: ""
		});
	},      	

    getAccounts: function(){
            enyo.log("phoneAccountService::getAccounts");
            this.$.listAccounts.getAccounts({capability: "PHONE"});
    },

	onGotAccounts: function(inSender, inResponse) {
        enyo.log("phoneAccountService::gotAccounts inResponse.accounts.length:"+JSON.stringify(inResponse.accounts.length));
        if (inResponse.templates) {
			this._accountTemplates = inResponse.templates;			
		}
		this.showPreferredService(); 	
	}, 
	
	internationalDialingTap: function() {
		var value = this.$.internationalDialingToggle.getState();
		this.$.prefService.call({"phoneInternationalDialingActive" : value}, {
		       method: "setPreferences",
		       onSuccess: "prefSetCallback",
		       onFailure: "prefSetCallback"
		});
     },      	

});


