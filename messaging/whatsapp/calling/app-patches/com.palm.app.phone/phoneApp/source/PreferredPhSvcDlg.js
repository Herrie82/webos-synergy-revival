enyo.kind({
	name: "PreferredPhSvcDlg",
	kind: "ModalDialog",
	scrim: true,
	lazy: false,
	events: {
		onServiceProviderSelected: "",
		onSkypeMobileSelected: "",
		onCancelSelected: ""
	},
	//* @protected
	components: [       
		{name: "title", className: "enyo-dialog-prompt-title", style: "border-bottom: 0; text-align:center;", content: $L("International Call")},
		{name: "message", className: "enyo-dialog-prompt-message", content: $L("Which service would you like to use?\n This preference can be set in Preferences & Accounts.")},
		{name: "serviceProviderBtn", kind: "Button", caption: $L("Service Provider"), onclick: "serviceProviderClick"},
		{kind: "Button", caption: $L("Skype"), onclick: "skypeMobileClick"},
		{kind: "Button", caption: $L("Cancel"), className: "enyo-button-negative", onclick: "cancelClick"},
		{name: "networkStatusQuery", kind: enyo.PalmService, service: enyo.palmServices.telephony, subscribe: true, 
			method: "networkStatusQuery", onSuccess: "updateNetworkname"},
	],
	create: function() {
		this.inherited(arguments);
		if (enyo.application.isTablet) {
	                this.$.serviceProviderBtn.setContent($L("Bluetooth"));
  
		} else {
			this.$.networkStatusQuery.call({});
		}
	},
	setCallDataAndOpen: function(callData) {
		this.callData = callData;

                //enyo.log("PREF DIALOG SET CALL DATA AND OPEN : " + enyo.application.Cache.btDeviceName);
                // add a suitable title
		if (enyo.application.isTablet && enyo.application.Cache.platformType === "none") {
			this.$.title.setContent($L("Call"));
		}
		else {
			this.$.title.setContent(this.callData.isIntl === true ? $L("International Call") : $L("Domestic Call"));
		}

                // populate the device name as the service name
                if (!enyo.application.Cache.isBtDeviceNameAvailable) {
                    this.$.serviceProviderBtn.setContent($L("Bluetooth"));
                } else {
                    // dynamic string not localized
	            this.$.serviceProviderBtn.setContent(enyo.application.Cache.btDeviceName);
                }

		this.openAtCenter();
	},
	serviceProviderClick: function() {
		this.close();
		this.callData.transport = enyo.application.CallSynergizer.TRANSPORTS.TIL;
		this.doServiceProviderSelected(this.callData);
	},
	skypeMobileClick: function() {
		this.close();
		this.callData.transport = enyo.application.CallSynergizer.TRANSPORTS.VOIP;
		this.doSkypeMobileSelected(this.callData);
	},
	cancelClick: function() {
		this.close();
		this.doCancelSelected(undefined);
	},
	updateNetworkname: function(inSender, payload) {
		var serviceName = undefined;
		if (payload) {
			if (payload.extended) {
				if (payload.extended.state == 'service') {
					serviceName = payload.extended.networkName;
				}
			}
			else if (payload.eventNetwork) {
				if (payload.eventNetwork.state === 'service') {
					serviceName = payload.eventNetwork.networkName;
				}
			}
		}

		this.$.serviceProviderBtn.setContent(serviceName ? serviceName: $L("Service Provider"));
	},
});
