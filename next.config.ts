import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: 'standalone',                             // Requierd so that Docker container stays tiny and efficient. 
  images: {
    remotePatterns: [
      {
        protocol: "https",
        hostname: "avatars.githubusercontent.com",  // Allows the app to load GitHub avatars
      },
    ],
  },
};

export default nextConfig;
