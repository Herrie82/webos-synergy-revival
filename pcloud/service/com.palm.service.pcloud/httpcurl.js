/*global IMPORTS, Config, require, process, console */
/*
 * httpcurl.js - HTTPS transport for the pCloud service, via the modern curl.
 *
 * WHY: the device node runtime is OpenSSL 0.9.8k (no TLS 1.2/1.3), so its built-in
 * HTTP stack (Foundations.Comms.AjaxCall) CANNOT complete a TLS handshake with
 * api.pcloud.com / eapi.pcloud.com. This mirrors the Dropbox/Box/OneDrive connectors -
 * "no modern HTTPS in the webOS JS layer" - by shelling every pCloud request out to the
 * modern curl (curl 7.88.1 + OpenSSL 1.1.1, TLS 1.3) from the deployment-bundle. The JS
 * layer is pure orchestration; all TLS lives in curl.
 *
 * SECURITY: pCloud ships a client_secret (no PKCE - see oauth2.js). Form fields passed via
 * --data-urlencode and query params include the client_id/client_secret, the one-time auth
 * code, and the long-lived access_token - briefly visible in `ps` argv. On this single-user
 * rooted device that is acceptable. TODO harden via `curl --config -` (stdin).
 */
var Foundations = IMPORTS.foundations;
var Future = Foundations.Control.Future;

var reqf = (typeof require !== "undefined") ? require : (IMPORTS.require || null);
var cp = reqf ? reqf("child_process") : null;

var HttpCurl = {
	// request({ method, url, headers:{}, form:{k:v}, body:"", bearer:"" }) -> Future
	// resolves to { status: <int>, responseText: <string> }
	request: function (opts) {
		opts = opts || {};
		var f = new Future();

		if (!cp) {
			f.setException({ returnValue: false, errorCode: "NO_CHILD_PROCESS",
				detail: "child_process unavailable in this service context" });
			return f;
		}

		var method = opts.method || "GET";
		var args = ["-s", "-S", "--tlsv1.2", "-w", "\n%{http_code}", "-X", method];

		// Point curl at the system CA store (/etc/ssl/certs/ca-certificates.crt). The
		// stock rootfs stub is from 2011; the deployment-bundle prerequisite refreshes
		// it to a current bundle so verify succeeds (verify=0) even on a reset device.
		if (Config.CURL_CAINFO) {
			args.push("--cacert", Config.CURL_CAINFO);
		}

		if (opts.bearer) {
			args.push("-H", "Authorization: Bearer " + opts.bearer);
		}
		if (opts.headers) {
			Object.keys(opts.headers).forEach(function (k) {
				args.push("-H", k + ": " + opts.headers[k]);
			});
		}
		// outFile: write the response BODY straight to a local file (getfilelink download).
		// curl streams to disk, so big files don't hit node's maxBuffer; stdout keeps only the
		// -w "\n<http_code>" line.
		if (opts.follow) {
			args.push("-L");   // pCloud content hosts may redirect
		}
		if (opts.outFile) {
			args.push("--create-dirs", "-o", opts.outFile);
		}
		if (opts.multipart) {
			// [{name, value} | {name, file}] -> curl -F. pCloud uploadfile takes its params
			// (folderid, filename, access_token) as query string and the bytes as a file part.
			opts.multipart.forEach(function (p) {
				args.push("-F", p.file ? (p.name + "=@" + p.file) : (p.name + "=" + p.value));
			});
		} else if (opts.form) {
			Object.keys(opts.form).forEach(function (k) {
				args.push("--data-urlencode", k + "=" + opts.form[k]);
			});
		} else if (opts.dataFile) {
			// Send a local file as the raw request body. "@" makes curl read the file directly -
			// the request is NOT limited by node's maxBuffer.
			args.push("--data-binary", "@" + opts.dataFile);
		} else if (opts.body) {
			args.push("--data-binary", opts.body);
		}
		args.push(opts.url);

		// Inherit env; point the loader at the modern libssl/libcrypto if configured.
		var env = {};
		var src = (typeof process !== "undefined" && process.env) ? process.env : {};
		Object.keys(src).forEach(function (k) { env[k] = src[k]; });
		if (Config.CURL_LD_LIBRARY_PATH) {
			env.LD_LIBRARY_PATH = Config.CURL_LD_LIBRARY_PATH +
				(env.LD_LIBRARY_PATH ? ":" + env.LD_LIBRARY_PATH : "");
		}

		cp.execFile(Config.CURL || "/usr/bin/curl", args,
			{ env: env, maxBuffer: 8 * 1024 * 1024 },
			function (err, stdout, stderr) {
				stdout = stdout || "";
				if (err && !stdout) {
					f.setException({ returnValue: false, errorCode: "CURL_FAILED",
						detail: (stderr || String(err)) });
					return;
				}
				// -w appended "\n<http_code>" after the body; split on the LAST newline.
				var cut = stdout.lastIndexOf("\n");
				var head = (cut >= 0) ? stdout.substring(0, cut) : stdout;
				var tail = (cut >= 0) ? stdout.substring(cut + 1) : "";
				f.result = { status: parseInt(tail, 10) || 0, responseText: head };
			});

		return f;
	}
};

if (typeof exports !== "undefined") { exports.HttpCurl = HttpCurl; }
