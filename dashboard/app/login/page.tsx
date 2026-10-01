import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/auth";

export const dynamic = "force-dynamic";

/**
 * Email one-time-code sign-in.
 *
 * No password to phish, reuse or leak, and the set of people who can actually
 * get in is fixed by ACQ_ALLOWED_EMAILS rather than by who manages to sign up.
 *
 * A typed code rather than a clicked link: a magic link is single-use and
 * bound to the browser that asked for it, so it fails when Gmail's link
 * scanner opens it first or when it is tapped in the phone's mail app. A code
 * has neither problem. Supabase sends both in one email once the "Magic Link"
 * template includes {{ .Token }}; /auth/callback still handles the link.
 */

// The address between the two steps lives in a short-lived httpOnly cookie,
// not in the URL, so it never lands in browser history or Vercel's logs.
const EMAIL_COOKIE = "acq_login_email";

function allowlist(): string[] {
  return (process.env.ACQ_ALLOWED_EMAILS ?? "")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);
}

async function sendCode(formData: FormData): Promise<void> {
  "use server";

  const email = String(formData.get("email") ?? "").trim().toLowerCase();
  if (!email) redirect("/login?error=missing");

  // Check before asking Supabase to send anything, and move to the code step
  // either way. Telling an anonymous visitor whether an address is on the
  // allowlist would turn this form into a way to enumerate the operators.
  if (allowlist().includes(email)) {
    const supabase = await createClient();
    await supabase.auth.signInWithOtp({
      email,
      options: {
        emailRedirectTo: `${process.env.NEXT_PUBLIC_SITE_URL}/auth/callback`,
        // The dashboard has a fixed set of operators; a code must never
        // create an account for someone who is not already one.
        shouldCreateUser: false,
      },
    });
  }

  const jar = await cookies();
  jar.set(EMAIL_COOKIE, email, {
    httpOnly: true, secure: true, sameSite: "lax", path: "/login", maxAge: 15 * 60,
  });
  redirect("/login?step=code");
}

async function verifyCode(formData: FormData): Promise<void> {
  "use server";

  const jar = await cookies();
  const email = jar.get(EMAIL_COOKIE)?.value ?? "";
  const token = String(formData.get("code") ?? "").replace(/\D/g, "");
  if (!email) redirect("/login?error=expired");
  if (token.length < 6) redirect("/login?step=code&error=format");

  // Re-checked here too: the code step is its own POST endpoint.
  if (!allowlist().includes(email)) redirect("/login?denied=1");

  const supabase = await createClient();
  const { error } = await supabase.auth.verifyOtp({ email, token, type: "email" });
  if (error) redirect("/login?step=code&error=invalid");

  jar.delete({ name: EMAIL_COOKIE, path: "/login" });
  redirect("/");
}

const ERRORS: Record<string, string> = {
  missing: "Enter your email address.",
  expired: "That took too long. Enter your email again to get a new code.",
  format: "The code is the number in the email, at least 6 digits.",
  invalid: "That code is wrong or has expired. Check the newest email, or send a new code.",
  "1": "That sign-in link has expired. Use a code instead.",
};

const box = { padding: ".75rem", borderRadius: 6, fontSize: ".875rem" } as const;
const input = { padding: ".55rem .7rem", border: "1px solid #ccc",
                borderRadius: 6, fontSize: ".95rem" } as const;
const button = { padding: ".6rem", border: 0, borderRadius: 6, cursor: "pointer",
                 background: "#0f766e", color: "#fff", fontSize: ".9rem" } as const;

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ step?: string; denied?: string; error?: string }>;
}) {
  const params = await searchParams;
  const jar = await cookies();
  const pendingEmail = jar.get(EMAIL_COOKIE)?.value;
  const codeStep = params.step === "code" && !!pendingEmail;
  const error = params.error ? ERRORS[params.error] ?? ERRORS.invalid : null;

  return (
    <main style={{ maxWidth: 380, margin: "12vh auto", padding: "0 1.5rem",
                   fontFamily: "system-ui, sans-serif" }}>
      <h1 style={{ fontSize: "1.25rem", marginBottom: ".25rem" }}>
        Acquisition dashboard
      </h1>

      {params.denied && (
        <p role="alert" style={{ ...box, background: "#fdf2f2", color: "#7f1d1d",
                                 border: "1px solid #f5c6c6" }}>
          That account is not authorised for this dashboard.
        </p>
      )}
      {error && (
        <p role="alert" style={{ ...box, background: "#fdf2f2", color: "#7f1d1d",
                                 border: "1px solid #f5c6c6" }}>
          {error}
        </p>
      )}

      {codeStep ? (
        <>
          <p style={{ color: "#888", fontSize: ".875rem", marginTop: 0 }}>
            If {pendingEmail} is authorised, a sign-in code is on its way. Check spam too.
          </p>
          <form action={verifyCode} style={{ display: "flex", flexDirection: "column", gap: ".6rem" }}>
            <label htmlFor="code" style={{ fontSize: ".8rem", color: "#888" }}>Code from the email</label>
            <input
              id="code" name="code" required inputMode="numeric" autoComplete="one-time-code"
              pattern="[0-9 ]{6,12}" maxLength={12} autoFocus
              style={{ ...input, fontSize: "1.3rem", letterSpacing: ".3em", textAlign: "center" }}
            />
            <button type="submit" style={button}>Sign in</button>
          </form>
          <form action={sendCode} style={{ marginTop: ".9rem" }}>
            <input type="hidden" name="email" value={pendingEmail} />
            <button type="submit" style={{ ...button, background: "transparent", color: "#0f766e",
                                           padding: 0, fontSize: ".85rem" }}>
              Send a new code
            </button>
          </form>
        </>
      ) : (
        <>
          <p style={{ color: "#888", fontSize: ".875rem", marginTop: 0 }}>
            Sign in with your work email. We&apos;ll email you a code.
          </p>
          <form action={sendCode} style={{ display: "flex", flexDirection: "column", gap: ".6rem" }}>
            <label htmlFor="email" style={{ fontSize: ".8rem", color: "#888" }}>Email</label>
            <input id="email" name="email" type="email" required autoComplete="email" style={input} />
            <button type="submit" style={button}>Email me a code</button>
          </form>
        </>
      )}
    </main>
  );
}
