import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";

/**
 * Authentication for the acquisition dashboard.
 *
 * This view renders scraped clinic contact details and drafted email bodies,
 * and its Server Actions approve real outbound mail and suppress leads
 * permanently. Until this file existed it had no authentication of any kind —
 * which was survivable while it ran on localhost and is not once it is a
 * public Vercel URL.
 *
 * Two deliberate choices:
 *
 *   - **An allowlist, not just "any authenticated user".** Supabase Auth will
 *     happily sign up anybody who asks for a magic link. Signing in must not
 *     be the same thing as being allowed in.
 *   - **Checked in middleware AND in every Server Action.** Middleware alone
 *     is not a sufficient gate: a Server Action is an individually addressable
 *     POST endpoint, so anything relying only on the page having rendered is
 *     bypassable by calling the action directly.
 */

/** Emails permitted to use the dashboard. Comma-separated, no wildcards. */
function allowlist(): string[] {
  return (process.env.ACQ_ALLOWED_EMAILS ?? "")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);
}

export async function createClient() {
  const cookieStore = await cookies();

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => cookieStore.getAll(),
        setAll: (toSet) => {
          try {
            toSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options),
            );
          } catch {
            // Called from a Server Component, where cookies are read-only.
            // Middleware refreshes the session, so this is safe to ignore.
          }
        },
      },
    },
  );
}

/**
 * The signed-in, allowlisted user — or a redirect.
 *
 * Uses getUser(), which validates the JWT with Supabase on every call. Do not
 * swap it for getSession(): that reads the cookie and trusts it, so a forged
 * cookie would pass.
 */
export async function requireUser() {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getUser();

  if (error || !data.user?.email) redirect("/login");

  const email = data.user.email.toLowerCase();
  const allowed = allowlist();

  // An empty allowlist denies everyone. The alternative — treating "unset" as
  // "allow all" — turns a missing environment variable into an open door,
  // which is exactly the wrong direction for a config mistake to fail.
  if (allowed.length === 0 || !allowed.includes(email)) {
    redirect("/login?denied=1");
  }

  return { id: data.user.id, email };
}

/**
 * Same check, for Server Actions.
 *
 * Throws instead of redirecting: an action called directly by a script should
 * fail loudly rather than answer with a 307 to a login page.
 */
export async function requireUserForAction(): Promise<{ id: string; email: string }> {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getUser();

  const email = data.user?.email?.toLowerCase();
  if (error || !email) throw new Error("unauthorized");
  if (!allowlist().includes(email)) throw new Error("forbidden");

  return { id: data.user!.id, email };
}
