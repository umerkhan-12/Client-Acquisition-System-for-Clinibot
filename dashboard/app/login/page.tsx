import { redirect } from "next/navigation";
import { createClient } from "@/lib/auth";

export const dynamic = "force-dynamic";

/**
 * Magic-link sign-in.
 *
 * No password to phish, reuse or leak, and the set of people who can actually
 * get in is fixed by ACQ_ALLOWED_EMAILS rather than by who manages to sign up.
 */

async function sendLink(formData: FormData): Promise<void> {
  "use server";

  const email = String(formData.get("email") ?? "").trim().toLowerCase();
  if (!email) redirect("/login?error=1");

  const allowed = (process.env.ACQ_ALLOWED_EMAILS ?? "")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);

  // Check before asking Supabase to send anything, and still answer "sent"
  // below either way. Telling an anonymous visitor whether an address is on
  // the allowlist would turn this form into a way to enumerate the operators.
  if (allowed.includes(email)) {
    const supabase = await createClient();
    await supabase.auth.signInWithOtp({
      email,
      options: {
        emailRedirectTo: `${process.env.NEXT_PUBLIC_SITE_URL}/auth/callback`,
        // The dashboard has a fixed set of operators; a link must never
        // create an account for someone who is not already one.
        shouldCreateUser: false,
      },
    });
  }

  redirect("/login?sent=1");
}

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ sent?: string; denied?: string; error?: string }>;
}) {
  const params = await searchParams;

  return (
    <main style={{ maxWidth: 380, margin: "12vh auto", padding: "0 1.5rem",
                   fontFamily: "system-ui, sans-serif" }}>
      <h1 style={{ fontSize: "1.25rem", marginBottom: ".25rem" }}>
        Acquisition dashboard
      </h1>
      <p style={{ color: "#666", fontSize: ".875rem", marginTop: 0 }}>
        Sign in with your work email.
      </p>

      {params.sent && (
        <p role="status" style={{ background: "#f0f7f0", border: "1px solid #cfe3cf",
                                  padding: ".75rem", borderRadius: 6, fontSize: ".875rem" }}>
          If that address is authorised, a sign-in link is on its way.
        </p>
      )}
      {params.denied && (
        <p role="alert" style={{ background: "#fdf2f2", border: "1px solid #f5c6c6",
                                 padding: ".75rem", borderRadius: 6, fontSize: ".875rem" }}>
          That account is not authorised for this dashboard.
        </p>
      )}

      <form action={sendLink} style={{ display: "flex", flexDirection: "column", gap: ".6rem" }}>
        <label htmlFor="email" style={{ fontSize: ".8rem", color: "#444" }}>Email</label>
        <input
          id="email" name="email" type="email" required autoComplete="email"
          style={{ padding: ".55rem .7rem", border: "1px solid #ccc",
                   borderRadius: 6, fontSize: ".95rem" }}
        />
        <button
          type="submit"
          style={{ padding: ".6rem", border: 0, borderRadius: 6, cursor: "pointer",
                   background: "#111", color: "#fff", fontSize: ".9rem" }}
        >
          Send sign-in link
        </button>
      </form>
    </main>
  );
}
