import express from "express";
import { client } from "../db/conn.mjs";

const router = express.Router();

// Liveness: yalnızca process canlılığı. Bağımlılıkları kontrol etmez, aksi
// halde MongoDB'nin kısa bir kesintisi backend pod'larının gereksiz yere
// yeniden başlatılmasına yol açar.
// Yanıt gövdesi bilinçli olarak korundu — client/src/components/healthcheck.js
// bunu ekranda gösteriyor.
router.get("/", async (req, res) => {
  const status = {
    uptime: process.uptime(),
    message: "OK",
    timestamp: Date.now(),
  };
  res.status(200).send(status);
});

// Readiness: MongoDB'ye ping atar. Başarısızsa 503 döner, Kubernetes pod'u
// Service endpoint'lerinden çıkarır ama restart etmez.
router.get("/ready", async (req, res) => {
  try {
    await client.db().command({ ping: 1 });
    res.status(200).send({ status: "ready", mongo: "up", timestamp: Date.now() });
  } catch (err) {
    res.status(503).send({ status: "not-ready", mongo: "down", error: err.message });
  }
});

export default router;
