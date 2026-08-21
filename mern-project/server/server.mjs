import express from "express";
import cors from "cors";
import pinoHttp from "pino-http";
import "./loadEnvironment.mjs";
import logger from "./logger.mjs";
import { client } from "./db/conn.mjs";
import records from "./routes/record.mjs";
import healthcheck from "./routes/healthcheck.mjs";

const PORT = Number(process.env.PORT || 5050);
// Konteyner içinde loopback'e bind etmek servisi erişilemez kılar.
const HOST = process.env.HOST || "0.0.0.0";

const app = express();

// nginx reverse proxy sayesinde frontend ve backend aynı origin'den servis
// edilir, bu yüzden CORS varsayılan olarak kapalıdır. Gerekirse CORS_ORIGINS
// ile açık bir liste verilir.
const corsOrigins = (process.env.CORS_ORIGINS || "")
  .split(",")
  .map((origin) => origin.trim())
  .filter(Boolean);

if (corsOrigins.length > 0) {
  app.use(cors({ origin: corsOrigins }));
  logger.info({ corsOrigins }, "cors.enabled");
}

// İstek/yanıt logu (Aşama 6, madde 51). Bu middleware olmadan backend Loki'ye
// yalnızca açılış satırlarını yazıyordu; "loglama" panelleri pratikte boştu.
//
// Probe'lar BİLEREK dışarıda: liveness + readiness saniyede birkaç kez gelir ve
// gerçek trafiği gürültüde boğar — 14 günlük retention'ı da gereksiz doldurur.
app.use(
  pinoHttp({
    logger,
    autoLogging: {
      ignore: (req) => req.url.startsWith("/healthcheck"),
    },
    // 4xx uyarı, 5xx hata: Grafana'da severity'ye göre filtrelenebilsin.
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

const server = app.listen(PORT, HOST, () => {
  logger.info({ port: PORT, host: HOST, env: process.env.NODE_ENV }, "server.listening");
});

// Rolling update sırasında Kubernetes SIGTERM gönderir. Yeni bağlantıları
// kapatıp devam eden istekleri bitirmek, deploy sırasında 502 görülmesini
// engeller.
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
