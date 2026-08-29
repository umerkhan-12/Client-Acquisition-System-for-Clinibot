/** @type {import('next').NextConfig} */
const nextConfig = {
  // `pg` is a native-ish driver; keep it out of the bundler and require it at
  // runtime on the server.
  serverExternalPackages: ["pg"],
};

export default nextConfig;
