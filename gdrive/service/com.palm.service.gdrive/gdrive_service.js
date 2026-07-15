/*global console */
/* gdrive_service.js - main service assistant. Modern OAuth2/Drive-v3 replacement for
 * the stock password/Google-Docs validator, mirroring com.palm.service.dropbox. File I/O
 * lives here (decoupled from the dead QuickOffice MX proxy) so the file-picker app,
 * the Photos aggregator, and QuickOffice can all consume it directly.
 */
function GdriveService() {}
GdriveService.prototype = {
	setup: function () { console.log("GdriveService (OAuth2/Drive-v3) setup"); return; }
};
