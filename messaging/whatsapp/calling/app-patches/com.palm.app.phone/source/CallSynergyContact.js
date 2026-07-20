// Represents a call synergy 'contact' that is associated with each line. This is not be confused with a 
// 'person' object stored by the contacts service. A call synergy contact may or may not be also associated with 
// a 'person' object. Call synergy contacts are created when added to a line (by answering or dialing out) and 
// ultimately added to the call log when removed from the line.
// Example:
// 	var c = new CallSynergyContact({address:"555134",transport:"com.palm.telephony"})
//	c.decorated(function() {
//		enyo.log("callsynergycontact fully populated. name is " + c.getName())
//	})
// 	c.setDisplayName("late cnap name") // set the displayname late
enyo.kind({
	name:"CallSynergyContact",
	kind: "OrphanedComponent",
	components: [
		{name:"personLookupQuery", kind:"Utils.PersonFind", onSuccess: "_personLookupComplete", onFailure: "_personLookupComplete"},
		{name:"personLookupByIdQuery", kind:"DbService", method:"get", onSuccess: "_personLookupByIdComplete", onFailure: "genericFailure"},
		{name:"carrierLookupQuery", kind:"DbService", method: "find", dbKind: "com.palm.carrierbook:1", onSuccess: "_carrierDbLookupComplete", onFailure: "genericFailure"},
		{name:"launchContactsService", kind:"PalmService", service: enyo.palmServices.application, method: "launch"},
		{name:"contactUpdateListeners", kind:"Utils.Dispatcher"},
		{name:"checkContactReminder", kind:"PalmService", service: enyo.palmServices.application, method: "launch"},
	],
	published: {
		displayName: "",
		cnap: ""
	},
	// address: REQUIRED phone number, skype username, etc
	// transport: REQUIRED name of transport
	// displayName: OPTIONAL Uses this as the display name if not resolved to a person. Can be updated late using setDisplayName
	// person: OPTIONAL Suggests a com.palm.person:1 object to associated OR a string id to associate this contact to
	//		this is faster because it prevents a reverse lookup
	create: function(inProps) {
		enyo.require(inProps.address != undefined, "CallSynergyContact requires an address.");
		enyo.require(inProps.transport != undefined, "CallSynergyContact requires a transport.");
		this.inherited(arguments);
		
		this.decoratedCallbacks = []; // array of callbacks to call when this object is decorated
		this.isDecorated = false; // flag to let us know that the object has been decorated
		
		this.address = inProps.address;
		this.transport = inProps.transport;
		this.displayName = inProps.displayName;
		this.person = inProps.person;
		
		// populated later
		this.personId = undefined; // known person only. The person id
		this.name = undefined; // known person's name OR carrierbook OR cnapName
		this.label = undefined; // known person only
		this.labelFormatted = undefined; // known person only, eg "Mobile" or "Skype"
		this.addressFormatted = undefined; // guaranteed to have something, eg "(703) 555-1212" or "Unknown number" or "skypeuser@skype.com". Will also have quickdial digits prefixed if 
		this.normalizedAddress = undefined; // guaranteed to have something, normalized value of address, used for call log only currently
		this.locationFormatted = undefined; // for unknown phone numbers only, eg "N. California"
		this.personGivenName = undefined; // known person only, for call log
		this.personFamilyName = undefined; // known person only, for call log
		this.ringtoneLoc = undefined; // known person only
		this.picture = {}; // known person only
		
		this.isIntlNumber = (enyo.application.Utils.isValidNumber(this.address) && enyo.application.Utils.isInternationalNumber(this.address));
		this._formatAddress();
		this._reverseLookup();
	},
	// called when this contact has been decorated
	decorated: function(callback) {
		enyo.require(enyo.isFunction(callback), "CallSynergyContact#decorated must be passed a function");
		if ( this.isDecorated ) {
			callback();
		} else {
			this.decoratedCallbacks.push(callback);
		}
	},
	dispatchCallbacks: function() {
		if ( ! this.isDecorated ) {
			this.isDecorated = true;
			this.decoratedCallbacks.forEach(function(c) { c() });
		}
	},
	// called when this contact has been updated late from network
	dispatchContactState: function(state) {
		//enyo.log("CNAP: dispatchContactState");
		this.$.contactUpdateListeners.dispatch(state);
	},

	addContactUpdateListener: function(listener) {
		//enyo.log("CNAP: addContactUpdateListener");
		this.$.contactUpdateListeners.add(listener);
	},

	removeContactUpdateListener: function(listener) {
		//enyo.log("CNAP: removeContactUpdateListener");
		this.$.contactUpdateListeners.remove(listener);
	},
	cnapChanged: function() {
		//enyo.log("CNAP: CallSynergyContact cnapChanged " + this.cnap);
		this.displayName = this.cnap;
	
		// currently a late update can only affect an unknown contact
		if ( ! this.personId ) {
			this.name = this.displayName;
		}

		if(this.isDecorated == true) { //if already decorated other don't bother
			this.dispatchContactState("");
		}
	},
	_formatAddress: function() {
		if ( this.transport == enyo.application.CallSynergizer.TRANSPORTS.TIL || this.isIntlNumber === true) {
			this.addressFormatted = enyo.application.Utils.FormatPhoneNumber(this.address) || enyo.application.Messages.unknownNumber;
			this.normalizedAddress = Utils.PersonFind.normalizePhoneNumber(this.address);
		} else {
			this.addressFormatted = this.address;
			this.normalizedAddress = Utils.PersonFind.normalizeIm(this.address);
		}
	},
	_reverseLookup: function() {
		// CASE: blocked caller
		if (this._isBlockedCaller(this.address)) {
			this.name = enyo.application.Messages.blockedNumber;
			this.dispatchCallbacks();
		} 
		// CASE: we have a person id
		else if ( enyo.isString(this.person) ) {
			this.$.personLookupByIdQuery.call({
				ids: [this.person]
			});
			
		// CASE: we have a person object
		} else if ( this.person && this.person._id ) {
			this._personLookupComplete(this,{person:this.person});
			
		// CASE: we are a phone number
		} else if ( this.transport == enyo.application.CallSynergizer.TRANSPORTS.TIL || this.isIntlNumber === true) {
			if (enyo.application.Utils.isEmergencyNumber(this.address)){
				this.name = $L("Emergency Number");
				this.dispatchCallbacks();
			} else if (enyo.application.Utils.isVoicemailNumber(this.address)) {
				this.name = enyo.application.Messages.voicemailContact;
				this.dispatchCallbacks();				
			} else {
				this.$.personLookupQuery.findByPhone(this.address);
			}
		// CASE: we are skype IM
		} else if ( this.transport == enyo.application.CallSynergizer.TRANSPORTS.VOIP ) {
			this.$.personLookupQuery.findByIm(this.address);
		
		// DEFAULT: we're something else
		// todo how do we reverse lookup 3rd party addresses?
		} else {
			//todo: we're labeling all skype calls as skype, and not by type (eg Home, Work)??
			this.label = "service_skype";
			this.labelFormatted = $L("Skype");
			
			// temp: need findPersonByIM
			this.name = this.address;
			this.dispatchCallbacks();
		}
	},
	_isBlockedCaller: function (number) {
		if(number == "blocked" || number == "blocked caller") {
			return true;
		}
		
		return false;
	},
	_personLookupByIdComplete: function(inSender, payload) {
		var contactPointType, normalizedAddress, matchingContactPoint;
		if (payload.results.length > 0) {
			this._formatWithPerson(payload.results[0]);
			
			// to get the label we must search the object for the matching contact point
			if ( this.transport == enyo.application.CallSynergizer.TRANSPORTS.TIL ) {
				contactPointType = "phoneNumbers";
			} else {
				contactPointType = (this.isIntlNumber === true) ? "phoneNumbers" : "ims";
			}
			
			matchingContactPoint = enyo.application.Utils.PersonFind.getContactPointFromPerson(this.normalizedAddress, contactPointType, payload.results[0]);
			if ( matchingContactPoint ) {
				this.label = matchingContactPoint.type;
				if ( enyo.application.Utils.contactPointLabels[matchingContactPoint.type] ) {
					this.labelFormatted = enyo.application.Utils.contactPointLabels[matchingContactPoint.type][0];
				} else {
					enyo.error("No label for type" + matchingContactPoint.type)
				}
			}
		} else {
			this._formatWithoutPerson();
		}
	},
	_personLookupComplete: function(inSender, response) {
		if (response.person) {
			this._formatWithPerson(response.person);
			if ( response.item && response.item.type) {
				this.label = response.item.type;
				if(enyo.application.Utils.contactPointLabels[response.item.type]) {
					this.labelFormatted = enyo.application.Utils.contactPointLabels[response.item.type][0];
				} else {
					enyo.error("No labelFormatted for type " + response.item.type)
				}
			}
		} else {
			this._formatWithoutPerson();
		}
	},
	_formatWithPerson: function(person) {
		this.person = person;
		this.personId = person._id;
		this.name = enyo.application.Utils.PersonDisplayName(person);
		this.personGivenName = person.name.givenName;
		this.personFamilyName = person.name.familyName;
		this.ringtoneLoc = person.ringtone && person.ringtone.location;
		
		this._populatePersonPic(person.photos); 
	},
	
	_populatePersonPic: function(photos) {
		var paths, selectedPhotoPath, imageObj, i;
		
		paths = [photos.bigPhotoPath, photos.squarePhotoPath, photos.listPhotoPath];		
		for (i = 0; i < paths.length; i++){
			if (paths[i] && (!window.PalmSystem || palmGetResource(paths[i]))){
				selectedPhotoPath = paths[i]; 
				break; 
			}
		}
		selectedPhotoPath = selectedPhotoPath || "images/contacts-unknown-icon-large.png";
		
		if ( selectedPhotoPath ) {
			imageObj = new Image();
			imageObj.src = selectedPhotoPath;
			imageObj.onload = enyo.bind(this, function() {
				this.picture.src = selectedPhotoPath;
				this.picture.obj = imageObj;
				this.dispatchCallbacks();
			});
			imageObj.onerror = imageObj.onabort = enyo.bind(this, function(){
				enyo.error("Unable to load picture at " + selectedPhotoPath);
				this.dispatchCallbacks();
			});
		} else {
			this.dispatchCallbacks();
		}
	},
	
	_carrierDbLookupComplete: function(inSender, payload) {
		if (payload.returnValue) {
        		this.name = payload.name;
		        if(payload.results.length > 0) {			        
			        this.fromCarrierBook = true;
			}
		}
		
		this.dispatchCallbacks();
	},
		
	_formatWithoutPerson: function() {
		// for unknown phone numbers only, eg "N. California"
		this.locationFormatted = enyo.application.Utils.locationForAddress(this.address, this.transport) || "";
		
		// first use display name
		if ( this.displayName && this.displayName.match(/[^\s]/) && this.displayName != "unknown"){
			this.name = this.displayName;
			this.dispatchCallbacks();
			
		} else if ( this.transport == enyo.application.CallSynergizer.TRANSPORTS.TIL ) {
			this.$.carrierLookupQuery.call({
				query: {
					where: [{"prop":"number","op":"=","val":this.address}]
				}
			});
		} else {
			// todo handle skype
			this.dispatchCallbacks();
		}								
	},
	
	displayNameChanged: function() {
		enyo.log("CallSynergyContact displayNameChanged " + this.displayName);
	},
	
	genericFailure: function(inSender, response) {
		enyo.error(inSender.service + inSender.method + " failed with " + enyo.json.stringify(response));
		this.dispatchCallbacks();
	},		
	/*_getPhoneLabel: function (phoneNumbers) {
		if (!phoneNumbers){
			return; 
		}
		if (phoneNumbers.length > 0) {
			for (i = 0; i < phoneNumbers.length; i++){
				//todo: we should use normalized value for address comparison here
				//if (phoneNumbers[i].normalizedValue === this.normalizedAddress)
				if (phoneNumbers[i].value == this.normalizedAddress) {					
					this.label = phoneNumbers[i].type; 
					//todo: this needs to be replaced once the contact library is ported
					this.labelFormatted = "";//Contacts.PhoneNumber.Labels.getLabel();
					enyo.log("this.labelFormatted "+this.labelFormatted);				
				}
			}
		} else {
			enyo.log("No label found for phone number %j of contact %j. Was there a reverse lookup problem?",this.address,this.name);
		}
	},*/
	
	// Returns true if this number can be called.
	// Can only be called when this object is decorated
	canBeCalled: function() {
		return enyo.application.Utils.canBeCalled(this.transport, this.address);
	},
	
	// Returns true if this number can be added to contacts
	// Can only be called when this object is decorated
	canBeAddedToContacts: function() {
		return  ! this.person && this.canBeCalled() && ! this.fromCarrierBook;
	},
	
	// Launches this contact in the contacts app, or to a pseudo card if not associated with person
	// Can only be called when this object is decorated
	launchInContactsApp: function() {
	    if (this.person) {
	        //contactsLaunchWithId
	        this.$.launchContactsService.call({
	            id: "com.palm.app.contacts",
	            params: {
	                'id': this.personId
	            }
	        });

	    } else if (this.canBeAddedToContacts()) {
	        //contactsLaunchWithPseudocard
	        var newContact = {};
	        var PseudoDetail = {};

	        if (this.transport == enyo.application.CallSynergizer.TRANSPORTS.TIL || this.transport === enyo.application.CallSynergizer.TRANSPORTS.VOIP) {
	            newContact.phoneNumbers = [{
	                value: this.address
	            }];
	        } else if (this.transport === enyo.application.CallSynergizer.TRANSPORTS.VOIP) {
	            newContact.ims = [{
	                value: this.address
	            }];
	        }	        
	        PseudoDetail.launchType = "pseudo-card";
	        PseudoDetail.contact = newContact;

	        this.$.launchContactsService.call({
	            id: "com.palm.app.contacts",
	            params: PseudoDetail
	        });
	    }
	},
	checkContactReminder: function() {
		if ( this.personId ) {
			// workaround DFISH-5686. Contact reminders won't be in dartfish.
			if ( ! enyo.application.isTablet ) {
				this.$.checkContactReminder.call({
					id: "com.palm.app.contacts",
					params: {
						launchType: "showReminder",
						personId: this.personId
					}
				});
			}
		}
	},
	// calling JSON.stringify (or enyo.json.stringify) on a CallSynergyContact instance
	// will return this value instead of creating a circular structure
	toJSON: function() {
		return this.name || this.addressFormatted;
	}
});

