/** @type {import('next').NextConfig} */
const nextConfig = {
  output: "standalone",
  reactStrictMode: true,
  async rewrites() {
    // Local/dev: proxy API to Phoenix so the CRM can use same-origin /api.
    // In prod on crm.mokaid.com, the ALB routes /api/* → API service first;
    // rewrites are only needed when NEXT_PUBLIC_API_URL is empty and there is no ALB.
    const apiOrigin = process.env.API_PROXY_ORIGIN || "http://localhost:4000";
    if (process.env.NEXT_PUBLIC_API_URL) {
      return [];
    }
    return [
      {
        source: "/api/:path*",
        destination: `${apiOrigin}/api/:path*`,
      },
    ];
  },
};

module.exports = nextConfig;
