import { supabase } from './supabase.ts'
import type {
  ActiveAssignment,
  CompletedPage,
  GroupState,
  PendingTaskPage,
  Session,
  Task,
  Tier,
} from './types.ts'

/**
 * Mensagens para os codigos de erro que as funcoes do Postgres levantam.
 * Ver supabase/schema.sql.
 */
const MESSAGES: Record<string, string> = {
  INVALID_CODE: 'Código do grupo incorreto.',
  INVALID_NAME: 'Escolha um nome de 1 a 20 caracteres.',
  NAME_TAKEN: 'Esse nome já é de outra pessoa do grupo.',
  GROUP_FULL: 'O grupo já está cheio (5 pessoas).',
  INVALID_TOKEN: 'Sua sessão expirou. Entre de novo com o código do grupo.',
  ALREADY_ACTIVE: 'Você já tem uma task ativa. Conclua ela primeiro.',
  NO_ACTIVE_TASK: 'Você não tem nenhuma task ativa.',
  TIER_LOCKED:
    'As tasks que sobraram deste tier já estão com outras pessoas. Espere alguém concluir.',
  ALL_DONE: 'Acabou: o grupo concluiu todas as tasks.',
  UNDO_EXPIRED: 'Só dá para desfazer até 10 minutos depois de concluir.',
  NOT_INITIALIZED: 'O grupo ainda não foi configurado. Rode `npm run set-code`.',
  TASK_NOT_FOUND: 'Essa task não existe mais. Recarregue a página.',
  ALREADY_COMPLETED: 'Essa task já foi concluída pelo grupo.',
  TASK_TAKEN: 'Essa task está ativa com outra pessoa. Só quem está com ela pode concluir.',
  NOT_COMPLETED_YET:
    'Essa task está livre. Só dá para pegar de extra o que já foi concluído ou o que está com outra pessoa.',
  EXTRA_ALREADY_ACTIVE: 'Você já tem uma task extra. Conclua ou devolva ela primeiro.',
  EXTRA_ALREADY_DONE: 'Você já fez essa task.',
  EXTRA_OWN_TASK: 'Essa já é a sua task principal.',
  NO_EXTRA_TASK: 'Você não tem nenhuma task extra ativa.',
  NO_EXTRA_AVAILABLE: 'Não há nenhuma task concluída que você ainda não tenha feito.',
}

export class ApiError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message)
    this.name = 'ApiError'
  }
}

/** true quando o token nao vale mais e o usuario precisa refazer o login. */
export function isAuthError(error: unknown): boolean {
  return error instanceof ApiError && error.code === 'INVALID_TOKEN'
}

async function call<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args)

  if (error) {
    // Sem resposta do servidor: internet caiu, ou o projeto Supabase esta
    // pausado por inatividade. "Failed to fetch" nao ajuda ninguem.
    if (!error.code && /fetch|network/i.test(error.message)) {
      throw new ApiError('NETWORK', 'Sem conexão com o servidor. Tente de novo em instantes.')
    }

    // O PostgREST devolve a mensagem do `raise exception` em error.message.
    // Vale o codigo MAIS LONGO que casar, nao o primeiro: uns sao prefixados por
    // outros (EXTRA_ALREADY_ACTIVE contem ALREADY_ACTIVE) e o primeiro match
    // daria a mensagem errada, dependendo so da ordem do objeto acima.
    const code = Object.keys(MESSAGES)
      .filter((key) => error.message.includes(key))
      .sort((a, b) => b.length - a.length)[0]

    throw new ApiError(code ?? 'UNKNOWN', code ? MESSAGES[code] : error.message)
  }

  return data as T
}

export function joinGroup(code: string, name: string): Promise<Session> {
  return call<{ member_id: string; token: string; name: string }>('join_group', {
    p_code: code,
    p_name: name,
  }).then((row) => ({ memberId: row.member_id, token: row.token, name: row.name }))
}

/**
 * Troca o nome do dono do token. O token continua o mesmo; o que muda e o nome
 * que ele usa para entrar de novo. Devolve o nome como ficou salvo (com trim).
 */
export function renameMember(token: string, name: string): Promise<string> {
  return call<{ member_id: string; name: string }>('rename_member', {
    p_token: token,
    p_name: name,
  }).then((row) => row.name)
}

export function getState(token: string): Promise<GroupState> {
  return call<GroupState>('get_state', { p_token: token })
}

/** Sorteia uma task para o dono do token — e so para ele. */
export function rollTask(token: string): Promise<Task> {
  return call<Task>('roll_task', { p_token: token })
}

/** Conclui a task ativa do dono do token — e so a dele. */
export function completeTask(token: string): Promise<{ assignment_id: string }> {
  return call('complete_task', { p_token: token })
}

export function undoComplete(token: string): Promise<{ assignment_id: string }> {
  return call('undo_complete', { p_token: token })
}

/**
 * Tasks que ja sairam do pool. `doneByMe` filtra pelo que quem olha ja fez
 * (true) ou nao fez (false); `doneBy` pelo que um membro fez. "Fez" inclui
 * concluir de extra. null = sem aquele filtro.
 */
export function listCompleted(
  token: string,
  {
    limit = 50,
    offset = 0,
    search = '',
    doneByMe = null as boolean | null,
    doneBy = null as string | null,
  } = {},
): Promise<CompletedPage> {
  return call<CompletedPage>('list_completed', {
    p_token: token,
    p_limit: limit,
    p_offset: offset,
    p_search: search || null,
    p_done_by_me: doneByMe,
    p_done_by: doneBy,
  })
}

/** Tasks que o grupo ainda nao concluiu, de todos os tiers. */
export function listPending(
  token: string,
  { limit = 50, offset = 0, tier = null as Tier | null, search = '' } = {},
): Promise<PendingTaskPage> {
  return call<PendingTaskPage>('list_pending', {
    p_token: token,
    p_limit: limit,
    p_offset: offset,
    p_tier: tier,
    p_search: search || null,
  })
}

/**
 * Conclui uma task escolhida na lista, sem precisar sortea-la antes.
 * Falha com TASK_TAKEN se ela estiver ativa com outro membro.
 */
export function completeTaskById(
  token: string,
  taskId: string,
): Promise<{ assignment_id: string }> {
  return call('complete_task_by_id', { p_token: token, p_task_id: taskId })
}

/**
 * Pega como EXTRA uma task que ja tem dono no pool — seja uma que o grupo ja
 * concluiu, seja a task ATIVA de outra pessoa (sem esperar ela concluir). Fica
 * ao lado da task normal e nao mexe no pool. So uma extra ativa por vez,
 * ninguem repete uma task que ja fez, e task livre nunca vale.
 */
export function takeExtraTask(token: string, taskId: string): Promise<ActiveAssignment> {
  return call<ActiveAssignment>('take_extra_task', { p_token: token, p_task_id: taskId })
}

/**
 * Sorteia como EXTRA uma task que o grupo ja concluiu e que voce ainda nao fez.
 * Mesmas regras do `takeExtraTask`; so muda que quem escolhe e o banco.
 * Falha com NO_EXTRA_AVAILABLE se nao sobrou nenhuma.
 */
export function rollExtraTask(token: string): Promise<ActiveAssignment> {
  return call<ActiveAssignment>('roll_extra_task', { p_token: token })
}

/**
 * Registra que voce fez uma task, sem pegar ela de extra antes — serve para o
 * que voce concluiu de passagem. Funciona mesmo com uma extra ativa na mao: a
 * conclusao nasce pronta, entao nao disputa o limite de uma extra por vez.
 * Se a task JA for a sua extra ativa, conclui aquela extra.
 */
export function completeExtraById(
  token: string,
  taskId: string,
): Promise<{ assignment_id: string }> {
  return call('complete_extra_by_id', { p_token: token, p_task_id: taskId })
}

/**
 * Conclui a extra ativa: sobe o contador de pessoas daquela task na /completed.
 * E a unica saida — o app nao devolve extra.
 *
 * A RPC `abandon_extra_task` continua no banco de proposito, mas so como
 * valvula manual pelo dashboard do Supabase: se alguem pegar uma extra
 * inviavel, e o unico jeito de destrava-la. Nao ha wrapper aqui porque nenhuma
 * tela pode chamar isso.
 */
export function completeExtraTask(token: string): Promise<{ assignment_id: string }> {
  return call('complete_extra_task', { p_token: token })
}
