import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Zenvexa — Acquisition Pipeline",
  description: "Lead pipeline, deliverability, the email approval queue and the website outreach queue.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
