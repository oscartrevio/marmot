import type { NextConfig } from "next";

// A static site: `next build` writes it to out/, ready for any static host.
const config: NextConfig = {
  // Hosts that may load the dev server's live reload besides localhost: set
  // DEV_ORIGINS (comma-separated, e.g. "*.example.ts.net") in .env.local when
  // the dev server is reached from another machine.
  allowedDevOrigins: process.env.DEV_ORIGINS?.split(",").filter(Boolean),
  output: "export",
  reactStrictMode: true,
};

export default config;
