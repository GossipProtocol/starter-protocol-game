import { z } from "zod";

const address = z.string().regex(/^0x[0-9a-fA-F]{40}$/, "expected a 0x address");

/** Shared server-side env. Each app validates only the keys it uses by picking from these. */
export const serverEnv = z.object({
  CHAIN_ID: z.coerce.number().int().default(4663),
  RPC_URL: z.string().url(),
  DATABASE_URL: z.string().url(),
  FACTORY_ADDRESS: address,
  START_BLOCK: z.coerce.number().int().nonnegative().default(0),
  KEEPER_PRIVATE_KEY: z.string().regex(/^0x[0-9a-fA-F]{64}$/).optional(),
  SUPABASE_URL: z.string().url().optional(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().optional(),
  PRIVY_APP_ID: z.string().optional(),
  PRIVY_APP_SECRET: z.string().optional(),
});
export type ServerEnv = z.infer<typeof serverEnv>;

export function parseEnv<T extends z.ZodTypeAny>(schema: T, source: Record<string, string | undefined> = process.env): z.infer<T> {
  const r = schema.safeParse(source);
  if (!r.success) {
    const issues = r.error.issues.map((i) => `  ${i.path.join(".")}: ${i.message}`).join("\n");
    throw new Error(`Invalid environment:\n${issues}`);
  }
  return r.data;
}
