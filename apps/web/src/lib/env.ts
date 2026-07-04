import { z } from "zod";

const envSchema = z.object({
  VITE_API_URL: z.string().url().default("http://localhost:4000"),
  VITE_WS_URL: z.string().default("ws://localhost:4000/socket"),
  VITE_ASSETS_CDN_URL: z.string().default(""),
  VITE_DISABLE_3D: z
    .string()
    .optional()
    .transform((v) => v === "true"),
});

export const env = envSchema.parse(import.meta.env);
