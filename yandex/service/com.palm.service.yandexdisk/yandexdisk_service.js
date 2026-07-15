/*global console */
/* yandexdisk_service.js - main service assistant. Modern OAuth2/REST replacement for
 * the stock password validator. File I/O lives here (decoupled from the dead QuickOffice
 * engine) so the file-picker app (and a QuickOffice reroute) can consume it directly.
 * Yandex Disk is DOCUMENTS-only - no photo/album provider methods.
 */
function YandexdiskService() {}
YandexdiskService.prototype = {
	setup: function () { console.log("YandexdiskService (OAuth2/REST) setup"); return; }
};
