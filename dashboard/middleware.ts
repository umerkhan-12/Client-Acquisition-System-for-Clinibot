import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

/**
 * Outer gate, and the place the Supabase session cookie is refreshed.
 *
 * This is the first of two checks, not the only one — `requireUserForAction()`
 * runs again inside every Server Action. Middleware is easy to bypass by
 * accident: add a route matcher exclusion, or a future Next.js change to how
 * actions are dispatched, and a gate that lived only here silently stops
 * gating. The duplicate check inside each action is what makes that a
 * degraded defence rather than no defence.
 *
 * It also refreshes the auth cookie, which Server Components cannot do (their
 * cookie store is read-only), so it has to happen here regardless.
 */
export async function middleware(request: NextRequest) {
  let response = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll: (toSet) => {
          toSet.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          toSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options),
          );
        },
      },
    },
  );

  // getUser(), never getSession(): the latter trusts the cookie as it stands.
  const { data } = await supabase.auth.getUser();
  const email = data.user?.email?.toLowerCase();

  const allowed = (process.env.ACQ_ALLOWED_EMAILS ?? "")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);

  const path = request.nextUrl.pathname;
  const isPublic = path.startsWith("/login") || path.startsWith("/auth/callback");

  if (!isPublic && (!email || !allowed.includes(email))) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.search = email ? "?denied=1" : "";
    return NextResponse.redirect(url);
  }

  // Already signed in and allowed: no reason to sit on the login page.
  if (path.startsWith("/login") && email && allowed.includes(email)) {
    const url = request.nextUrl.clone();
    url.pathname = "/";
    url.search = "";
    return NextResponse.redirect(url);
  }

  return response;
}

export const config = {
  /**
   * Everything except Next's own static assets.
   *
   * Note what is deliberately NOT excluded: Server Action POSTs, which arrive
   * on ordinary page paths. Excluding "/" here to save a request would unauth
   * every action on the page.
   */
  matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)"],
};
