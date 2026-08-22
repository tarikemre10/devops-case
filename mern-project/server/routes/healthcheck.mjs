import express from "express";
import { client } from "../db/conn.mjs";

const router = express.Router();

// Liveness bağımlılıkları kontrol etmez.
router.get("/", async (req, res) => {
  const status = {
    uptime: process.uptime(),
    message: "OK",
    timestamp: Date.now(),
  };
  res.status(200).send(status);
});

// Readiness MongoDB bağlantısını da kontrol eder.
router.get("/ready", async (req, res) => {
  try {
    await client.db().command({ ping: 1 });
    res.status(200).send({ status: "ready", mongo: "up", timestamp: Date.now() });
  } catch (err) {
    res.status(503).send({ status: "not-ready", mongo: "down", error: err.message });
  }
});

export default router;
