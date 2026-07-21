/*global Adapter, AccountCreds, PhotoLib, Config, console */
/* listPhotos - Photos-aggregator contract. args: { accountId, aid }
 * aid is the bare album name from listAlbums; the album lives at "/<name>" in the mount. Returns
 * one entry per image:
 *   { returnValue:true, photos:[ { pid, src_big, src_small, caption, type:"image", fileName } ] }
 * src_big is Koofr's files/download link (Adapter.getTemporaryLink), a ready-to-GET URL the
 * aggregator's curl fetches. Links are resolved sequentially to avoid a burst of curl processes.
 */
function ListPhotosCommandAssistant() {}

ListPhotosCommandAssistant.prototype = {
	// NO allowedAppIds - see listAlbums_command.js.
	run: function (future) {
		var self = this, args = this.controller.args || {};
		if (args.aid == null || args.aid === "") { future.result = { returnValue: true, photos: [] }; return; }
		var albumPath = "/" + String(args.aid).replace(/^\/+|\/+$/g, "");

		var credF = AccountCreds.resolve(args);
		credF.then(this, function () {
			var creds;
			try { creds = credF.result; } catch (e) { future.setException(e); return; }
			var renewed = null;
			var lf = Adapter.listFolder(creds, albumPath, function (nc) { renewed = nc; });
			lf.then(self, function () {
				var entries;
				try { entries = (lf.result && lf.result.entries) || []; }
				catch (e2) { future.setException(e2); return; }
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
	}
};
