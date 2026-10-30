import { defineConfig } from "oxfmt";
import ultracite from "ultracite/oxfmt";

// The CLI's prose and workflows are wrapped by hand at 100 columns (.editorconfig): oxfmt formats
// the website's code and config only.
export default defineConfig({
  ...ultracite,
  ignorePatterns: [
    ...ultracite.ignorePatterns,
    "**/*.md",
    ".github/**",
    "tests/**",
  ],
});
