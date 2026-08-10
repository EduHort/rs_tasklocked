import { createClient } from '@supabase/supabase-js'
import { config } from 'dotenv'

config({ path: '.env.local' })
config({ path: '.env' })

function required(name: string): string {
  const value = process.env[name]
  if (!value) {
    console.error(`\nFalta a variavel ${name}. Copie .env.example para .env.local e preencha.\n`)
    process.exit(1)
  }
  return value
}

/**
 * Cliente com a service_role key: ignora RLS. Use SOMENTE em scripts locais,
 * nunca no front.
 */
export function adminClient() {
  return createClient(required('VITE_SUPABASE_URL'), required('SUPABASE_SERVICE_ROLE_KEY'), {
    auth: { persistSession: false, autoRefreshToken: false },
  })
}

/** Cliente com a anon key: enxerga o mesmo que o navegador dos jogadores. */
export function anonClient() {
  return createClient(required('VITE_SUPABASE_URL'), required('VITE_SUPABASE_ANON_KEY'), {
    auth: { persistSession: false, autoRefreshToken: false },
  })
}
