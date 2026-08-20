import pino from "pino";

// Yapılandırılmış JSON log. Kubernetes'te stdout'a yazılır, Grafana Alloy
// tarafından toplanıp Loki'ye gönderilir. pino-pretty bilinçli olarak
// kullanılmıyor — ek bağımlılık getirmemek için lokalde de JSON okunur.
const logger = pino({
  level: process.env.LOG_LEVEL || (process.env.NODE_ENV === "production" ? "info" : "debug"),
  base: { service: "mern-server" },
  timestamp: pino.stdTimeFunctions.isoTime,
});

export default logger;
