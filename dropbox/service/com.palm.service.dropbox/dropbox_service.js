/*global console */
/* dropbox_service.js - main service assistant. Modern OAuth2/API-v2 replacement for
 * the stock password/Dropbox-v1 validator. File I/O now lives here (decoupled from the
 * dead QuickOffice engine) so a new file-picker app can consume it directly.
 */
function DropboxService() {}
DropboxService.prototype = {
	setup: function () { console.log("DropboxService (OAuth2/v2) setup"); return; }
};
