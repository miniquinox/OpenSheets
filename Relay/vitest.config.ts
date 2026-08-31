import { defineConfig } from "vitest/config";
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        // 120 s is the production response timeout; tests wait 500 ms.
        bindings: { RESPONSE_TIMEOUT_MS: "500" },
      },
    }),
  ],
});
