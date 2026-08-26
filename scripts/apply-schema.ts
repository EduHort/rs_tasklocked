/**
 * Aplica o supabase/schema.sql no banco, via psql.
 *
 *   npm run schema
 *
 * O schema.sql e a fonte da verdade e e idempotente de ponta a ponta: so
 * `create table if not exists`, `create index if not exists` e
 * `create or replace function`. Nao ha delete nem truncate no arquivo, entao
 * rodar por cima de um banco em producao preserva tasks, membros, assignments,
 * extras, tokens e o codigo do grupo — e so troca as funcoes.
 *
 * E por isso que este projeto NAO cria um arquivo de migracao por mudanca:
 * mudou o schema.sql, roda o schema.sql. As `migration-*.sql` que existem sao
 * historico do que ja foi aplicado, nao um passo do fluxo.
 *
 * A excecao seria uma mudanca que mexe em DADO (backfill de coluna, constraint
 * nova sobre linhas que ja existem). Nenhuma ate hoje precisou disso; quando
 * precisar, ai sim vale um arquivo separado com o passo de dados.
 */
import { spawnSync } from 'node:child_process'
import { required } from './_env.ts'

const SCHEMA = 'supabase/schema.sql'

const url = required('SUPABASE_DB_URL')

// Mostra em qual banco vai mexer sem vazar a senha no terminal: um projeto
// Supabase errado no .env.local e o unico jeito real de errar aqui.
let alvo: string
try {
  const parsed = new URL(url)
  alvo = `${parsed.hostname}${parsed.port ? `:${parsed.port}` : ''}${parsed.pathname}`
} catch {
  console.error(`\nSUPABASE_DB_URL nao parece uma URL de conexao valida.`)
  console.error(`Pegue em Project Settings > Database > Connection string (URI).\n`)
  process.exit(1)
}

console.log(`\n  aplicando ${SCHEMA}`)
console.log(`  em ${alvo}\n`)

// ON_ERROR_STOP: sem isso o psql segue depois de um erro e o relatorio final
// do schema.sql sairia bonito mesmo com metade das funcoes quebradas.
const result = spawnSync('psql', [url, '-v', 'ON_ERROR_STOP=1', '-f', SCHEMA], {
  stdio: 'inherit',
})

if (result.error) {
  const semPsql = (result.error as NodeJS.ErrnoException).code === 'ENOENT'
  console.error(
    semPsql
      ? '\n  psql nao encontrado. Instale o cliente do Postgres (ex.: apt install postgresql-client),\n' +
          '  ou cole o supabase/schema.sql no SQL Editor do Supabase.\n'
      : `\n  falhou ao rodar o psql: ${result.error.message}\n`,
  )
  process.exit(1)
}

if (result.status !== 0) {
  console.error(`\n  o psql saiu com codigo ${result.status} — o schema NAO foi aplicado por inteiro.\n`)
  process.exit(result.status ?? 1)
}

console.log(`
  pronto. O relatorio acima e do proprio schema.sql — esperado:
  5 tabelas, 4 indices unicos, 15 funcoes.
`)
