import { createServer } from "node:http";

/**
 * Deliberately minimal. This repository is about the deployment pipeline, not
 * about application or container design — those are demonstrated in
 * docker-node-postgres-stack and are not duplicated here.
 *
 * What matters for deployment is that the service reports which build it is
 * running, so a deploy can be verified as having actually taken effect rather
 * than merely having exited zero.
 */
const PORT = Number(process.env.PORT ?? 3000);
const VERSION = process.env.APP_VERSION ?? "unknown";
const COLOR = process.env.DEPLOY_COLOR ?? "unknown";
const startedAt = Date.now();

const server = createServer((req, res) => {
  const send = (status, body) => {
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(body));
  };

  switch (req.url) {
    case "/healthz":
      return send(200, {
        status: "ok",
        version: VERSION,
        color: COLOR,
        uptime_s: Math.round((Date.now() - startedAt) / 1000),
      });
    case "/version":
      return send(200, { version: VERSION, color: COLOR });
    case "/":
      return send(200, { service: "deploy-payload", version: VERSION });
    default:
      return send(404, { error: "not found" });
  }
});

server.listen(PORT, () => console.log(`listening on :${PORT} version=${VERSION} color=${COLOR}`));

// docker stop sends SIGTERM. Without a handler the runtime waits out the grace
// period and then SIGKILLs, which during a deploy means dropped requests at
// exactly the moment traffic is being switched away.
const shutdown = (signal) => {
  console.log(`${signal} received, draining`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10_000).unref();
};
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
