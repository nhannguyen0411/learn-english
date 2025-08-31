// Placeholder client until @supabase/supabase-js is installed.
// Replace with real implementation when dependency is available.

type SupabaseClient = Record<string, unknown>;

// eslint-disable-next-line @typescript-eslint/no-unused-vars
function createClient(_url: string, _key: string): SupabaseClient {
  return {};
}

export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY
);
