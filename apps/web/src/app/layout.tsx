import type { Metadata, Viewport } from "next";
import { JetBrains_Mono } from "next/font/google";
import localFont from "next/font/local";

import "./globals.css";

const sans = localFont({
  display: "auto",
  src: [
    { path: "../lib/fonts/OpenRunde-Regular.woff2", weight: "400" },
    { path: "../lib/fonts/OpenRunde-Medium.woff2", weight: "500" },
    { path: "../lib/fonts/OpenRunde-Semibold.woff2", weight: "600" },
  ],
  variable: "--font-open-runde",
});

const mono = JetBrains_Mono({
  subsets: ["latin"],
  variable: "--font-jetbrains",
});

export const metadata: Metadata = {
  description:
    "marmot (mm) cleans up after coding agents on Debian and Ubuntu. It never deletes what an agent or tool still uses.",
  metadataBase: new URL("https://marmot.oscartrev.io"),
  title: "marmot",
};

export const viewport: Viewport = {
  themeColor: "#ffffff",
};

const RootLayout = ({ children }: { children: React.ReactNode }) => (
  <html className={`${sans.variable} ${mono.variable}`} lang="en">
    <body className="font-sans antialiased">{children}</body>
  </html>
);

export default RootLayout;
