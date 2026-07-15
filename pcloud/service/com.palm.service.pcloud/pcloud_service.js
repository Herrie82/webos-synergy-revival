/*global console */
/* pcloud_service.js - main service assistant. Modern OAuth2/REST replacement for the stock
 * password validators, mirroring com.palm.service.dropbox / onedrive. File I/O lives here
 * (decoupled from the dead QuickOffice MX proxy) so the file-picker app, the Photos
 * aggregator, and QuickOffice can all consume it directly.
 */
function PcloudService() {}
PcloudService.prototype = {
	setup: function () { console.log("PcloudService (OAuth2/pCloud REST) setup"); return; }
};
