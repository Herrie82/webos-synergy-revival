/*global Adapter, AccountCreds, PhotoLib, console */
/* listPhotos - Photos-aggregator contract. args: { accountId, aid }
 * There is exactly ONE surfaced album ("Camera Uploads"), so rather than trust the aid (which is
 * a bare name, since the real path has slashes), we re-resolve the album's full path via
 * Adapter.resolvePhotoAlbum and list it. Returns one entry per image:
 *   { returnValue:true, photos:[ { pid, src_big, src_small, caption, type:"image", fileName } ] }
 * src_big is a "/file?path=..&access_token=.." URL (Adapter.getTemporaryLink) the aggregator's
 * curl fetches header-less.
 */
function ListPhotosCommandAssistant() {}

ListPhotosCommandAssistant.prototype = {
	// NO allowedAppIds - see listAlbums_command.js.
	run: function (future) {
		var self = this, args = this.controller.args || {};
		if (args.aid == null || args.aid === "") { future.result = { returnValue: true, photos: [] }; return; }

		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; } catch (e) { future.setException(e); return; }
			var renewed = null;
			var albF = Adapter.resolvePhotoAlbum(creds, function (nc) { renewed = nc; });
			albF.then(self, function () {
				var album;
				try { album = albF.result; } catch (e2) { future.result = { returnValue: true, photos: [] }; return; }
				if (!album.path || !album.exists) { future.result = { returnValue: true, photos: [] }; return; }
				var lf = Adapter.listFolder(creds, album.path, function (nc) { renewed = nc; });
				lf.then(self, function () {
					var entries;
					try { entries = (lf.result && lf.result.entries) || []; }
					catch (e3) { future.setException(e3); return; }
					var images = entries.filter(PhotoLib.isImage);
					var photos = [], i = 0;
					function finish() {
						if (renewed && args.accountId) { AccountCreds.save(args.accountId, renewed); }
						future.result = { returnValue: true, photos: photos };
					}
					function next() {
						if (i >= images.length) { finish(); return; }
						var e = images[i++];
						var tl = Adapter.getTemporaryLink(creds, e.id, function (nc) { renewed = nc; });
						tl.then(self, function () {
							var link = null;
							try { link = tl.result && tl.result.link; } catch (er) { link = null; }
							if (link) {
								photos.push({ pid: e.id, src_big: link, src_small: link,
									caption: e.name, type: "image", fileName: e.name });
							}
							next();
						});
					}
					next();
				});
			});
		});
	}
};
