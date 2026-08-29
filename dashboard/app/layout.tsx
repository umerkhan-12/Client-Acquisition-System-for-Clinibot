import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Clinibot — Acquisition Pipeline",
  description: "Lead pipeline, deliverability and the outreach approval queue.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
