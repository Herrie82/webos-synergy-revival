/*global Adapter, AccountCreds, PhotoLib, Config, console */
/* listAlbums - Photos-aggregator contract. args: { accountId }
 * Surfaces ONE Mega folder as one album:
 *   { returnValue:true, albums:[ { aid, name, size:{images:N} } ] }
 * The folder is Config.PHOTO_ALBUM_NAME ("Camera Uploads") under the Cloud Drive root. aid is
 * the opaque node HANDLE (8 base64 chars - filesystem-safe, no "/"), handed to listPhotos
 * verbatim. If the folder doesn't exist yet the album is still surfaced (aid "", 0 images) so
 * the source shows up in Photos; it is created on the first device->cloud upload.
 */
function ListAlbumsCommandAssistant() {}

ListAlbumsCommandAssistant.prototype = {
	// NO allowedAppIds: the stock Photos aggregator calls provider services over the private bus
	// with no bus identity (see the other connectors' listAlbums).

	run: function (future) {
		var self = this, args = this.controller.args || {};
		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; } catch (e) { future.setException(e); return; }
			var renewed = null;
			var albF = Adapter.resolvePhotoAlbum(creds, function (nc) { renewed = nc; });
			albF.then(self, function () {
				var album;
				try { album = albF.result; }
				catch (e2) { album = { path: "", name: (Config && Config.PHOTO_ALBUM_NAME) || "Camera Uploads" }; }
				if (!album.path) {
					// Folder not created yet - surface an empty album.
					future.result = { returnValue: true,
						albums: [{ aid: "", name: album.name, size: { images: 0 } }] };
					return;
				}
				var lf = Adapter.listFolder(creds, album.path, function (nc) { renewed = nc; });
				lf.then(self, function () {
					var entries;
					try { entries = (lf.result && lf.result.entries) || []; }
					catch (e3) { entries = []; }
					if (renewed && args.accountId) { AccountCreds.save(args.accountId, renewed); }
					var count = 0;
					entries.forEach(function (e) { if (PhotoLib.isImage(e)) { count++; } });
					future.result = { returnValue: true,
						albums: [{ aid: album.path, name: album.name, size: { images: count } }] };
				});
			});
		});
	}
};
