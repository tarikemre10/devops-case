import fs from "node:fs";
import dotenv from "dotenv";

// Konteynerde konfigürasyon env değişkenlerinden gelir; dosya yalnızca lokal
// geliştirme kolaylığıdır. Yoksa sessizce atlanır.
const envFile = process.env.ENV_FILE || "./config.env";

if (fs.existsSync(envFile)) {
  dotenv.config({ path: envFile });
}
