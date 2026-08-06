"use strict";

const fs = require("node:fs");
const http2 = require("node:http2");

function argument(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || index + 1 >= process.argv.length) {
    throw new Error(`${name} is required`);
  }
  return process.argv[index + 1];
}

function patterned(size) {
  const result = Buffer.allocUnsafe(size);
  for (let index = 0; index < size; index += 1) {
    result[index] = "a".charCodeAt(0) + (index % 26);
  }
  return result;
}

const certificate = argument("--certificate");
const privateKey = argument("--private-key");
const portFile = argument("--port-file");
const server = http2.createSecureServer({
  cert: fs.readFileSync(certificate),
  key: fs.readFileSync(privateKey),
  allowHTTP1: false,
  ALPNProtocols: ["h2"],
});

server.on("stream", (stream, headers) => {
  const path = headers[http2.constants.HTTP2_HEADER_PATH];
  const method = headers[http2.constants.HTTP2_HEADER_METHOD];
  const chunks = [];
  let received = 0;
  stream.on("data", (chunk) => {
    received += chunk.length;
    if (received <= 1024 * 1024) {
      chunks.push(chunk);
    }
  });
  stream.on("end", () => {
    let body;
    switch (path) {
      case "/small": body = Buffer.from("flyology-http2-interop"); break;
      case "/first": body = Buffer.from("first"); break;
      case "/second": body = Buffer.from("second"); break;
      case "/large": body = patterned(256 * 1024); break;
      case "/echo":
        if (received > 1024 * 1024) {
          stream.respond({ ":status": 413, "content-length": 0 });
          stream.end();
          return;
        }
        body = Buffer.concat(chunks);
        break;
      default:
        stream.respond({ ":status": 404, "content-length": 0 });
        stream.end();
        return;
    }
    stream.respond({
      ":status": 200,
      "content-length": body.length,
      "x-peer": "node",
    });
    stream.end(method === "HEAD" ? undefined : body);
  });
});

server.on("sessionError", (error) => {
  process.stderr.write(`session error: ${error.message}\n`);
});
server.listen(0, "127.0.0.1", () => {
  const address = server.address();
  fs.writeFileSync(portFile, String(address.port), { mode: 0o600 });
});
