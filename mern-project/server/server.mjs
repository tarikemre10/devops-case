import express from "express";
import cors from "cors";
import pinoHttp from "pino-http";
import "./loadEnvironment.mjs";
import logger from "./logger.mjs";
import { client } from "./db/conn.mjs";
import records from "./routes/record.mjs";
import healthcheck from "./routes/healthcheck.mjs";

const PORT = Number(process.env.PORT || 5050);
const HOST = process.env.HOST || "0.0.0.0";

const app = express();

const corsOrigins = (process.env.CORS_ORIGINS || "")
  .split(",")
  .map((origin) => origin.trim())
  .filter(Boolean);

if (corsOrigins.length > 0) {
  app.use(cors({ origin: corsOrigins }));
  logger.info({ corsOrigins }, "cors.enabled");
}

app.use(
  pinoHttp({
    logger,
    autoLogging: {
      ignore: (req) => req.url.startsWith("/healthcheck"),
    },
    customLogLevel: (req, res, err) => {
      if (err || res.statusCode >= 500) return "error";
      if (res.statusCode >= 400) return "warn";
      return "info";
    },
    customSuccessMessage: () => "http.request",
    customErrorMessage: () => "http.request_failed",
  }),
);

app.use(express.json());

app.use("/record", records);
app.use("/healthcheck", healthcheck);

// eslint-disable-next-line no-unused-vars -- Express hata middleware'i 4 argüman ister.
app.use((err, req, res, next) => {
  const isMongo = typeof err?.name === "string" && err.name.startsWith("Mongo");

  logger.error({ err: err.message, name: err.name, path: req.originalUrl }, "request.failed");

  if (res.headersSent) return;

  if (isMongo) {
    res.status(503).send({ error: "database unavailable" });
  } else if (err?.name === "BSONError" || err?.name === "BSONTypeError") {
    res.status(400).send({ error: "invalid id" });
  } else {
    res.status(500).send({ error: "internal server error" });
  }
});

const server = app.listen(PORT, HOST, () => {
  logger.info({ port: PORT, host: HOST, env: process.env.NODE_ENV }, "server.listening");
});

function shutdown(signal) {
  logger.info({ signal }, "server.shutdown_started");

  const forceExit = setTimeout(() => {
    logger.error("server.shutdown_timeout");
    process.exit(1);
  }, 10000);
  forceExit.unref();

  server.close(async () => {
    try {
      await client.close();
      logger.info("server.shutdown_complete");
      process.exit(0);
    } catch (err) {
      logger.error({ err: err.message }, "server.shutdown_error");
      process.exit(1);
    }
  });
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

// Mongo kesintisinde readiness trafiği durdurur; driver yeniden bağlanır.
function isMongoError(err) {
  return typeof err?.name === "string" && err.name.startsWith("Mongo");
}

process.on("uncaughtException", (err) => {
  if (isMongoError(err)) {
    logger.error({ err: err.message, name: err.name }, "mongo.transient_error");
    return;
  }

  logger.fatal({ err: err.message, stack: err.stack }, "process.uncaught_exception");
  process.exit(1);
});

process.on("unhandledRejection", (reason) => {
  if (isMongoError(reason)) {
    logger.error({ err: reason.message, name: reason.name }, "mongo.transient_error");
    return;
  }

  logger.fatal({ err: reason?.message ?? String(reason) }, "process.unhandled_rejection");
  process.exit(1);
});
