/*global console */
/* boxnet_service.js - main service assistant. Modern OAuth2/REST-v2 replacement for
 * the stock password/Box-v1 validator, mirroring com.palm.service.dropbox. File I/O
 * lives here (decoupled from the dead QuickOffice MX proxy) so the file-picker app,
 * the Photos aggregator, and QuickOffice can all consume it directly.
 */
function BoxnetService() {}
BoxnetService.prototype = {
	setup: function () { console.log("BoxnetService (OAuth2/v2) setup"); return; }
};
