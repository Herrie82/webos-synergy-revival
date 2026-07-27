/*jslint node: true */
/*global Future, Log, xml, checkResult */

/*
 * curl-backed drop-in replacement for httpClient.js.
 *
 * WHY: the webOS 3.0.5 node (v0.4.12) is linked against libssl.so.0.9.8. Its TLS stack
 * cannot complete a handshake with any modern CardDAV/CalDAV server (TLS 1.2+), so every
 * https request dies with "socket hang up" in tls.js and (via the uncaughtException handler)
 * takes the whole service down. The device ships a modern curl at /usr/bin/curl (a wrapper
 * that LD_LIBRARY_PATHs /usr/lib/curl11 -> curl 7.88.1 / OpenSSL 1.1.1w). Routing all HTTP
 * through that curl gives us working modern TLS plus native WebDAV verb + digest support.
 *
 * Implements the same public interface as httpClient.js:
 *   sendRequest(options, data) -> Future{ returnValue, returnCode, headers, body, etag,
 *                                         parsedBody?, uri, method }
 *   parseURLIntoOptions(url, options)
 *   setTimeoutDefault(ms)
 *   cancelRequest(reqNum)
 * See httpClient.js for the full options contract (filestream, binary, parse, authCallback,
 * redirectCallback, sizeCallback, receivedCallback, reqNumCallback, ignoreSSLCertificateErrors).
 */

var childProcess = require("child_process");
var fs = require("fs");
var url = require("url");

var CURL = "/usr/bin/curl";
var TMPDIR = "/tmp/cdav-http";

var httpClient = (function () {
	"use strict";
	var timeoutDefault = 60000,
		globalReqNum = 0,
		requests = {}; //reqNum -> { child, aborted }

	try {
		fs.mkdirSync(TMPDIR, "0755");
	} catch (ignore) { /* EEXIST is fine */ }

	function parseURLIntoOptionsImpl(inUrl, options) {
		if (!inUrl) {
			return;
		}
		var parsedUrl = url.parse(inUrl);
		if (!parsedUrl.hostname) {
			parsedUrl = url.parse(inUrl.replace(":/", "://")); //SOGo sometimes returns uri with a single /
		}
		options.path = parsedUrl.pathname || "/";
		if (parsedUrl.search) {
			options.path += parsedUrl.search;
		}
		if (!options.headers) {
			options.headers = {};
		}
		options.host = parsedUrl.hostname;
		options.headers.host = parsedUrl.hostname;
		options.port = parsedUrl.port;
		options.protocol = parsedUrl.protocol;
		if (!parsedUrl.port) {
			options.port = parsedUrl.protocol === "https:" ? 443 : 80;
		}
		options.prefix = options.protocol + "//" + options.headers.host + ":" + options.port;
		options.originalUrl = inUrl;
	}

	//parse a curl header dump (-D). With -L this can contain several blocks; keep the last one.
	function parseHeaderDump(text) {
		var headers = {}, statusCode = 0, blocks, lastBlock, lines, i, line, idx, key, val;
		if (!text) {
			return { statusCode: 0, headers: headers };
		}
		//split into header blocks on the HTTP/ status line
		blocks = text.replace(/\r/g, "").split(/\n(?=HTTP\/)/);
		lastBlock = blocks[blocks.length - 1];
		lines = lastBlock.split("\n");
		for (i = 0; i < lines.length; i += 1) {
			line = lines[i];
			if (i === 0 && line.indexOf("HTTP/") === 0) {
				val = line.split(" ")[1];
				statusCode = parseInt(val, 10) || 0;
			} else {
				idx = line.indexOf(":");
				if (idx > 0) {
					key = line.substring(0, idx).trim().toLowerCase();
					val = line.substring(idx + 1).trim();
					if (headers[key] !== undefined) {
						headers[key] = headers[key] + ", " + val;
					} else {
						headers[key] = val;
					}
				}
			}
		}
		return { statusCode: statusCode, headers: headers };
	}

	function buildArgs(options, dataFile, bodyFile, hdrFile) {
		var args = ["-s", "-S", "-L", "--max-redirs", "8", "--max-time", String(Math.round(timeoutDefault / 1000)),
				"-o", bodyFile, "-D", hdrFile, "-w", "%{http_code}\\n%{url_effective}"],
			method = options.method || "GET",
			fullUrl,
			key;

		if (options.ignoreSSLCertificateErrors) {
			args.push("-k");
		}
		if (method !== "GET") {
			args.push("-X", method);
		}
		if (options.headers) {
			Object.keys(options.headers).forEach(function (k) {
				var lk = k.toLowerCase();
				//curl manages these itself; passing them can conflict.
				if (lk === "content-length" || lk === "host") {
					return;
				}
				if (options.headers[k] === undefined || options.headers[k] === null) {
					return;
				}
				args.push("-H", k + ": " + options.headers[k]);
			});
		}
		//suppress curl's default Content-Type/Expect behaviour where the caller didn't set them
		if (dataFile) {
			args.push("--data-binary", "@" + dataFile);
		}
		//prevent "Expect: 100-continue" stalls on some servers
		args.push("-H", "Expect:");

		if (options.path && options.path.indexOf(":/") >= 0) {
			fullUrl = options.path; //already absolute (proxy path)
		} else {
			fullUrl = (options.prefix || (options.protocol + "//" + options.host + ":" + options.port)) + options.path;
		}
		args.push(fullUrl);
		return { args: args, fullUrl: fullUrl, method: method };
	}

	function sendRequestImpl(options, data, authretry) {
		var future = new Future(),
			reqNum = globalReqNum,
			stamp = TMPDIR + "/req" + reqNum + "_" + (new Date()).getTime(),
			bodyFile = stamp + ".body",
			hdrFile = stamp + ".hdr",
			dataFile = null,
			built,
			child,
			wout = "",
			werr = "";

		globalReqNum += 1;
		requests[reqNum] = { aborted: false };
		if (typeof options.reqNumCallback === "function") {
			options.reqNumCallback(reqNum);
		}

		if (data !== undefined && data !== null && data !== "") {
			dataFile = stamp + ".data";
			try {
				if (data instanceof Buffer) {
					fs.writeFileSync(dataFile, data);
				} else if (typeof data === "object") {
					fs.writeFileSync(dataFile, JSON.stringify(data), "utf8");
				} else {
					fs.writeFileSync(dataFile, String(data), "utf8");
				}
			} catch (e) {
				Log.log("curlHttp: could not write data file: ", e.message);
			}
		}

		built = buildArgs(options, dataFile, bodyFile, hdrFile);
		Log.debug("curlHttp: ", built.method, " ", built.fullUrl);
		Log.log_httpClient && Log.log_httpClient("curl args: ", built.args.join(" "));

		function cleanup() {
			[bodyFile, hdrFile, dataFile].forEach(function (f) {
				if (f) {
					try { fs.unlinkSync(f); } catch (ignore) {}
				}
			});
		}

		function finish(result) {
			cleanup();
			delete requests[reqNum];
			future.result = result;
		}

		try {
			child = childProcess.spawn(CURL, built.args);
		} catch (spawnErr) {
			Log.log("curlHttp: spawn failed: ", spawnErr.message);
			finish({ returnValue: false, returnCode: -1, msg: "spawn failed: " + spawnErr.message });
			return future;
		}
		requests[reqNum].child = child;

		child.stdout.on("data", function (d) { wout += d.toString("utf8"); });
		child.stderr.on("data", function (d) { werr += d.toString("utf8"); });

		child.on("error", function (e) {
			Log.log("curlHttp: child error: ", e.message);
			finish({ returnValue: false, returnCode: -1, msg: "curl error: " + e.message });
		});

		child.on("exit", function (code) {
			if (requests[reqNum] && requests[reqNum].aborted) {
				finish({ returnValue: false, returnCode: -1, msg: "aborted" });
				return;
			}
			//curl exit codes: 6 dns, 7 connect, 28 timeout, 35/52/55/56 tls/recv
			var wlines = wout.split("\n"),
				statusFromW = parseInt(wlines[0], 10) || 0,
				effectiveUrl = (wlines[1] || "").trim(),
				hdrText = "",
				parsed,
				headers,
				statusCode,
				bodyBuf = new Buffer(0),
				result;

			if (code !== 0 && statusFromW === 0) {
				Log.log("curlHttp: curl exit ", code, " stderr: ", werr);
				finish({ returnValue: false, returnCode: -1, msg: "curl exit " + code + ": " + werr });
				return;
			}

			try { hdrText = fs.readFileSync(hdrFile, "utf8"); } catch (ignore) {}
			parsed = parseHeaderDump(hdrText);
			headers = parsed.headers;
			statusCode = statusFromW || parsed.statusCode;

			if (typeof options.sizeCallback === "function" && headers["content-length"]) {
				options.sizeCallback(headers["content-length"]);
			}

			//deliver body: either into the caller's filestream, or as buffer/string
			if (options.filestream && statusCode >= 200 && statusCode < 300) {
				try {
					bodyBuf = fs.readFileSync(bodyFile);
					options.filestream.write(bodyBuf);
					options.filestream.end();
				} catch (fe) {
					Log.log("curlHttp: filestream write failed: ", fe.message);
				}
				if (typeof options.receivedCallback === "function") {
					options.receivedCallback(bodyBuf.length);
				}
			} else {
				try { bodyBuf = fs.readFileSync(bodyFile); } catch (ignore) { bodyBuf = new Buffer(0); }
			}

			if (effectiveUrl && built.fullUrl && effectiveUrl !== built.fullUrl &&
					typeof options.redirectCallback === "function") {
				options.redirectCallback(effectiveUrl);
			}

			result = {
				returnValue: (statusCode > 0 && statusCode < 400),
				returnCode: statusCode,
				etag: headers.etag,
				headers: headers,
				body: (options.binary || options.filestream) ? bodyBuf : bodyBuf.toString("utf8"),
				uri: effectiveUrl || built.fullUrl,
				method: built.method
			};

			//401 -> let caller compute a digest/auth header and retry once
			if (statusCode === 401 && !authretry && typeof options.authCallback === "function") {
				var innerfuture = options.authCallback(result);
				innerfuture.then(function () {
					var cbResult = checkResult(innerfuture);
					if (cbResult && cbResult.returnValue === true) {
						if (cbResult.newAuthHeader) {
							options.headers.Authorization = cbResult.newAuthHeader;
						}
						cleanup();
						delete requests[reqNum];
						future.nest(sendRequestImpl(options, data, true));
					} else {
						finish(result);
					}
				});
				return;
			}

			if (statusCode > 0 && statusCode < 300 && options.parse) {
				try {
					result.parsedBody = xml.xmlstr2json(bodyBuf.toString("utf8"));
				} catch (pe) {
					Log.log("curlHttp: xml parse failed: ", pe.message);
				}
			}

			finish(result);
		});

		return future;
	}

	return {
		sendRequest: function (options, data) {
			return sendRequestImpl(options, data, false);
		},
		parseURLIntoOptions: function (inUrl, options) {
			return parseURLIntoOptionsImpl(inUrl, options);
		},
		setTimeoutDefault: function (inVal) {
			if (inVal) {
				timeoutDefault = inVal;
			}
		},
		cancelRequest: function (reqNum) {
			var r = requests[reqNum];
			if (r && !r.aborted) {
				r.aborted = true;
				if (r.child) {
					try { r.child.kill("SIGKILL"); } catch (ignore) {}
				}
			}
		}
	};
}());

module.exports = httpClient;
