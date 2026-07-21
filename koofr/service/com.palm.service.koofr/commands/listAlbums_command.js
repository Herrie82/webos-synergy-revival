/*global Adapter, AccountCreds, PhotoLib, Config, console */
/* listAlbums - Photos-aggregator contract. args: { accountId }
 * Surfaces ONE Koofr folder ("Camera Uploads" at the mount root) as one album:
 *   { returnValue:true, albums:[ { aid, name, size:{images:N} } ] }
 * aid is the bare folder NAME (filesystem-safe); listPhotos maps it back to the "/<name>" path.
 * If the folder doesn't exist yet it is still surfaced (0 images); created on first upload.
 */
function ListAlbumsCommandAssistant() {}

ListAlbumsCommandAssistant.prototype = {
	// NO allowedAppIds: the Photos aggregator calls provider services over the private bus.
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
				catch (e2) { album = { path: "/" + (Config.PHOTO_ALBUM_NAME || "Camera Uploads"),
					name: (Config.PHOTO_ALBUM_NAME || "Camera Uploads"), exists: false }; }
				if (!album.exists) {
					future.result = { returnValue: true,
						albums: [{ aid: album.name, name: album.name, size: { images: 0 } }] };
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
						albums: [{ aid: album.name, name: album.name, size: { images: count } }] };
				});
			});
		});
	}
};
