import { defineConfig } from "oxlint";
import next from "ultracite/oxlint/next";
import react from "ultracite/oxlint/react";

import root from "../../oxlint.config.ts";

// Oxlint lints each file with its nearest config alone, so this extends the
// root config and repeats the properties that extends doesn't carry over.
export default defineConfig({
  env: root.env,
  extends: [root, next, react],
  ignorePatterns: root.ignorePatterns,
  settings: root.settings,
});
