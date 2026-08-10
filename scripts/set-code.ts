/**
 * Define o codigo (senha) do grupo. Guarda so o hash bcrypt no banco e imprime
 * o codigo em claro UMA vez, no terminal, para voce mandar pros amigos.
 *
 *   npm run set-code            # gera um codigo aleatorio de 6 caracteres
 *   npm run set-code MEUCODIGO  # usa um codigo escolhido por voce
 */
import { randomInt } from 'node:crypto'
import { adminClient } from './_env.ts'

// Sem 0/O/1/I/L: o codigo vai ser digitado a mao e ditado no Discord.
const ALPHABET = '23456789ABCDEFGHJKMNPQRSTUVWXYZ'

function generateCode(length = 6): string {
  let code = ''
  for (let i = 0; i < length; i++) code += ALPHABET[randomInt(ALPHABET.length)]
  return code
}

const code = process.argv[2]?.trim() || generateCode()

const { error } = await adminClient().rpc('set_group_code', { p_code: code })
if (error) {
  console.error('falhou:', error.message)
  process.exit(1)
}

console.log(`
  Codigo do grupo definido:

      ${code}

  Guarde agora — o banco so tem o hash, nao da para recuperar depois.
  Rodar de novo troca o codigo (quem ja entrou continua logado pelo token).
`)
