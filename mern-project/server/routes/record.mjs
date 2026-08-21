import express from "express";
import db from "../db/conn.mjs";
import { ObjectId } from "mongodb";

const router = express.Router();

// Express 4, async handler'lardan dönen reddedilmiş promise'leri hata
// middleware'ine İLETMEZ; işlenmeyen reddetme olarak dışarı sızarlar. Bu yüzden
// her async handler bu sarmalayıcıdan geçirilir: MongoDB erişilemezken istek
// sonsuza kadar asılı kalmak yerine server.mjs'teki hata middleware'ine düşüp
// 503 alır.
const wrap = (handler) => (req, res, next) => handler(req, res, next).catch(next);

// This section will help you get a list of all the records.
router.get("/", wrap(async (req, res) => {
  let collection = await db.collection("records");
  let results = await collection.find({}).toArray();
  res.status(200).send(results);
}));

// This section will help you get a single record by id
router.get("/:id", wrap(async (req, res) => {
  let collection = await db.collection("records");
  let query = {_id: new ObjectId(req.params.id)};
  let result = await collection.findOne(query);

  if (!result) res.status(404).send("Not found");
  else res.status(200).send(result);
}));

// Alan doğrulaması. Doğrulama olmadan `POST /record` boş bir gövdeyle 201
// dönüyor ve koleksiyona `{name: null, position: null, level: null}` yazıyordu.
// `level` değerleri client/src/components/create.js'teki radio butonlarından
// gelir; liste orayla aynı tutulmalı.
const LEVELS = ["Intern", "Junior", "Senior"];

function validateRecord(body) {
  const errors = [];

  for (const field of ["name", "position"]) {
    if (typeof body?.[field] !== "string" || body[field].trim() === "") {
      errors.push(`${field} is required`);
    }
  }

  if (!LEVELS.includes(body?.level)) {
    errors.push(`level must be one of: ${LEVELS.join(", ")}`);
  }

  return errors;
}

// This section will help you create a new record.
router.post("/", wrap(async (req, res) => {
  const errors = validateRecord(req.body);
  if (errors.length > 0) {
    res.status(400).send({ error: "validation failed", details: errors });
    return;
  }

  let newDocument = {
    name: req.body.name.trim(),
    position: req.body.position.trim(),
    level: req.body.level,
  };
  let collection = await db.collection("records");
  let result = await collection.insertOne(newDocument);
  res.status(201).send(result);
}));

// This section will help you update a record by id.
router.patch("/:id", wrap(async (req, res) => {
  // Bu handler üç alanı da $set ediyor; eksik alanlar kayda null olarak
  // yazılırdı. Bu yüzden POST ile aynı doğrulamadan geçirilir.
  const errors = validateRecord(req.body);
  if (errors.length > 0) {
    res.status(400).send({ error: "validation failed", details: errors });
    return;
  }

  const query = { _id: new ObjectId(req.params.id) };
  const updates =  {
    $set: {
      name: req.body.name.trim(),
      position: req.body.position.trim(),
      level: req.body.level
    }
  };

  let collection = await db.collection("records");
  let result = await collection.updateOne(query, updates);
  res.status(200).send(result);
}));

// This section will help you delete a record
router.delete("/:id", wrap(async (req, res) => {
  const query = { _id: new ObjectId(req.params.id) };

  const collection = db.collection("records");
  let result = await collection.deleteOne(query);

  res.status(200).send(result);
}));

export default router;