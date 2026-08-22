import express from "express";
import db from "../db/conn.mjs";
import { ObjectId } from "mongodb";

const router = express.Router();

// Express 4 async hatalarını merkezi middleware'e aktar.
const wrap = (handler) => (req, res, next) => handler(req, res, next).catch(next);

router.get("/", wrap(async (req, res) => {
  let collection = await db.collection("records");
  let results = await collection.find({}).toArray();
  res.status(200).send(results);
}));

router.get("/:id", wrap(async (req, res) => {
  let collection = await db.collection("records");
  let query = {_id: new ObjectId(req.params.id)};
  let result = await collection.findOne(query);

  if (!result) res.status(404).send("Not found");
  else res.status(200).send(result);
}));

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

router.patch("/:id", wrap(async (req, res) => {
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

router.delete("/:id", wrap(async (req, res) => {
  const query = { _id: new ObjectId(req.params.id) };

  const collection = db.collection("records");
  let result = await collection.deleteOne(query);

  res.status(200).send(result);
}));

export default router;
