/*global console */
/* onedrive_service.js - main service assistant. Modern OAuth2/Graph replacement for
 * the stock password/SkyDrive-v1 validator, mirroring com.palm.service.dropbox. File I/O
 * lives here (decoupled from the dead QuickOffice MX proxy) so the file-picker app,
 * the Photos aggregator, and QuickOffice can all consume it directly.
 */
function OnedriveService() {}
OnedriveService.prototype = {
	setup: function () { console.log("OnedriveService (OAuth2/Graph) setup"); return; }
};
