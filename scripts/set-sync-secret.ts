/**
 * Define o segredo que o worker do cron usa para chamar a RPC `sync_tasks`.
 * Guarda so o hash bcrypt no banco e imprime o segredo em claro UMA vez.
 *
 *   npm run set-sync-secret            # gera um segredo aleatorio
 *   npm run set-sync-secret MEUSEGREDO # usa um escolhido por voce
 *
 * Depois, mande o mesmo valor para o worker:
 *
 *   npx wrangler secret put SYNC_SECRET
 *
 * Este segredo nao e o codigo do grupo e nao e a service_role key: ele so abre
 * a `sync_tasks`, que so faz upsert em `tasks`. Nao le membros nem tokens.
 */
import { randomBytes } from 'node:crypto'
import { adminClient } from './_env.ts'

// 32 chars base64url ~ 192 bits. Nao e digitado a mao por ninguem, entao aqui
// nao vale a pena evitar caracteres parecidos como no codigo do grupo.
const secret = process.argv[2]?.trim() || randomBytes(24).toString('base64url')

if (secret.length < 16) {
  console.error('\n  O segredo precisa de pelo menos 16 caracteres.\n')
  process.exit(1)
}

const { error } = await adminClient().rpc('set_sync_secret', { p_secret: secret })
if (error) {
  console.error('falhou:', error.message)
  if (error.message.includes('NOT_INITIALIZED')) {
    console.error('Rode `npm run set-code` antes: o grupo precisa existir.')
  }
  process.exit(1)
}

console.log(`
  Segredo de sincronizacao definido:

      ${secret}

  Guarde agora — o banco so tem o hash. Mande o mesmo valor para o worker:

      npx wrangler secret put SYNC_SECRET

  Rodar de novo troca o segredo, e o worker para de funcionar ate voce
  atualizar o secret la tambem.
`)
