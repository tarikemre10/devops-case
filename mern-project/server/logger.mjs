import pino from "pino";

// Yapılandırılmış JSON log. Kubernetes'te stdout'a yazılır, Grafana Alloy
// tarafından toplanıp Loki'ye gönderilir. pino-pretty bilinçli olarak
// kullanılmıyor — ek bağımlılık getirmemek için lokalde de JSON okunur.
const logger = pino({
  level: process.env.LOG_LEVEL || (process.env.NODE_ENV === "production" ? "info" : "debug"),
  base: { service: "mern-server" },
  timestamp: pino.stdTimeFunctions.isoTime,

  // pino-http istek header'larının tamamını log'a yazar. Bu uygulamada kimlik
  // doğrulama yok, ama log satırları Loki'de 14 gün duruyor: bir gün auth
  // eklenirse token'lar sessizce log'a akmaya başlardı. Maskeleme şimdi konur.
  redact: {
    paths: [
      "req.headers.authorization",
      "req.headers.cookie",
      "res.headers['set-cookie']",
    ],
    censor: "[redacted]",
  },
});

export default logger;
