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

// Merkezi hata middleware'i. record.mjs'teki `wrap` sarmalayıcısı sayesinde
// async handler hataları buraya düşer.
//
// MongoDB erişilemezken 503 döndürülür: bu geçici bir bağımlılık hatasıdır,
// uygulama bozuk değildir — istemci ve ALB için 500'den daha doğru sinyal.
// Yanıt, serverSelectionTimeoutMS (5sn) dolar dolmaz gider; istek asılı kalmaz.
// eslint-disable-next-line no-unused-vars -- Express hata middleware'i 4 argüman ister.
app.use((err, req, res, next) => {
  const isMongo = typeof err?.name === "string" && err.name.startsWith("Mongo");

  logger.error({ err: err.message, name: err.name, path: req.originalUrl }, "request.failed");

  if (res.headersSent) return;

  if (isMongo) {
    res.status(503).send({ error: "database unavailable" });
  } else if (err?.name === "BSONError" || err?.name === "BSONTypeError") {
    // Geçersiz ObjectId istemci hatasıdır; 500 yanlış sinyal verir ve
    // Prometheus'ta sahte 5xx alarmı üretir.
    res.status(400).send({ error: "invalid id" });
  } else {
    res.status(500).send({ error: "internal server error" });
  }
});

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

// MongoDB kesintisi süreci ÖLDÜRMEMELİ.
//
// Ölçüm: `kubectl delete pod mongodb-0` sonrası üç backend pod'u da
// exitCode 1 ile restart etti ve kesinti 26 saniye sürdü. Sebep, driver'ın
// topology monitörünün `MongoServerSelectionError: getaddrinfo ENOTFOUND
// mongodb-0.mongodb...` hatasını bir zamanlayıcı callback'inden fırlatması:
// hata hiçbir istek try/catch'ine düşmüyor, doğrudan uncaughtException olup
// süreci sonlandırıyor. Bu, healthcheck.mjs'teki "liveness bağımlılık kontrol
// etmez ki kısa Mongo kesintisi pod'ları restart ettirmesin" tasarımını da
// boşa çıkarıyordu.
//
// Mongo kaynaklı hatalarda: logla ve ayakta kal. Readiness probe'u ping
// atamadığı için pod'u Service endpoint'lerinden zaten çıkarır, driver Mongo
// geri gelince kendi yeniden bağlanır ve pod restart'sız hazır duruma döner.
// Mongo dışı hatalarda davranış değişmez: bilinmeyen bir durumda çalışmaya
// devam etmek, restart'tan daha risklidir.
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
