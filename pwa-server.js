const http = require('http');
const fs = require('fs');
const net = require('net');
const path = require('path');

const root = path.join(__dirname, 'pwa');
const preferredPort = Number(process.env.PORT || 8001);
const PORT_FALLBACK_ATTEMPTS = 100;

const contentTypes = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml; charset=utf-8',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
};

function portAvailable(port) {
  return new Promise((resolve) => {
    const probe = net.createServer();
    probe.once('error', () => resolve(false));
    probe.listen({ host: '127.0.0.1', port, exclusive: true }, () => {
      probe.close(() => resolve(true));
    });
  });
}

async function findAvailablePort() {
  const lastPort = Math.min(preferredPort + PORT_FALLBACK_ATTEMPTS - 1, 65535);
  for (let port = preferredPort; port <= lastPort; port += 1) {
    if (await portAvailable(port)) return port;
  }
  throw new Error(`PWA server could not start: ports ${preferredPort}-${lastPort} are already in use.`);
}

findAvailablePort().then((port) => {
  if (port !== preferredPort) {
    console.log(`Port ${preferredPort} is in use by another program; using ${port} instead.`);
  }
  const server = http.createServer((request, response) => {

  const requestUrl = new URL(request.url || '/', `http://${request.headers.host}`);
  const rawPath = decodeURIComponent(requestUrl.pathname);
  const normalizedPath = rawPath === '/' ? '/index.html' : rawPath;
  const filePath = path.normalize(path.join(root, normalizedPath));

  if (!filePath.startsWith(root)) {
    response.writeHead(403);
    response.end('Forbidden');
    return;
  }

  fs.readFile(filePath, (error, content) => {
    if (error) {
      fs.readFile(path.join(root, 'index.html'), (fallbackError, fallbackContent) => {
        if (fallbackError) {
          response.writeHead(404);
          response.end('Not found');
          return;
        }

        response.writeHead(200, { 'Content-Type': contentTypes['.html'] });
        response.end(fallbackContent);
      });
      return;
    }

    response.writeHead(200, {
      'Cache-Control': 'no-cache',
      'Content-Type': contentTypes[path.extname(filePath)] || 'application/octet-stream',
    });
    response.end(content);
  });
});

  server.listen(port, '0.0.0.0', () => {
    console.log(`PWA server running at http://localhost:${port}`);
  });
}).catch((error) => {
  console.error(error.message);
  process.exit(1);
});
