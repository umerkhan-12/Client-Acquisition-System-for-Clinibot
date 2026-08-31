import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/auth";

/**
 * Where the magic link lands. Exchanges the one-time code for a session.
 *
 * The allowlist is re-checked here and the session torn down if it fails.
 * Middleware would redirect such a user to /login anyway, but leaving them
 * holding a valid session cookie for a dashboard they may not use is a state
 * worth not having: it survives a future route being added without a matcher,
 * and it is invisible to anyone auditing who is signed in.
 */
export async function GET(request: NextRequest) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get("code");

  if (!code) {
    return NextResponse.redirect(`${origin}/login?error=1`);
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.exchangeCodeForSession(code);

  if (error) {
    return NextResponse.redirect(`${origin}/login?error=1`);
  }

  const { data } = await supabase.auth.getUser();
  const email = data.user?.email?.toLowerCase();
  const allowed = (process.env.ACQ_ALLOWED_EMAILS ?? "")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);

  if (!email || !allowed.includes(email)) {
    await supabase.auth.signOut();
    return NextResponse.redirect(`${origin}/login?denied=1`);
  }

  return NextResponse.redirect(origin);
}
