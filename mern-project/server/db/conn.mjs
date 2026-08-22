import { MongoClient } from "mongodb";
import logger from "../logger.mjs";

const connectionString = process.env.ATLAS_URI || "mongodb://localhost:27017";
const dbName = process.env.MONGO_DB || "sample_training";
const maxRetries = Number(process.env.MONGO_MAX_RETRIES || 10);

const client = new MongoClient(connectionString, {
  serverSelectionTimeoutMS: 5000,
});

// MongoDB backend'den sonra hazır olabilir.
async function connectWithRetry() {
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      await client.connect();
      await client.db(dbName).command({ ping: 1 });
      logger.info({ attempt, db: dbName }, "mongo.connected");
      return client.db(dbName);
    } catch (err) {
      const isLastAttempt = attempt === maxRetries;
      const retryInMs = Math.min(2 ** attempt * 250, 10000);

      logger.error(
        { attempt, maxRetries, err: err.message, retryInMs: isLastAttempt ? null : retryInMs },
        "mongo.connect_failed"
      );

      if (isLastAttempt) {
        logger.fatal({ maxRetries }, "mongo.giving_up");
        process.exit(1);
      }

      await new Promise((resolve) => setTimeout(resolve, retryInMs));
    }
  }
}

const db = await connectWithRetry();

export { client, db };
export default db;
