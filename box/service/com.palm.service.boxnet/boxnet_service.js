/*global console */
/* boxnet_service.js - main service assistant. Modern OAuth2/REST-v2 replacement for
 * the stock password/Box-v1 validator. File I/O now lives here (decoupled from the
 * dead QuickOffice engine) so a new file-picker app can consume it directly.
 */
function BoxNetService() {}
BoxNetService.prototype = {
	setup: function () { console.log("BoxNetService (OAuth2/v2) setup"); return; }
};
