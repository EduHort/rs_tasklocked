import { supabase } from './supabase.ts'
import type { CompletedPage, GroupState, PendingTaskPage, Session, Task, Tier } from './types.ts'

/**
 * Mensagens para os codigos de erro que as funcoes do Postgres levantam.
 * Ver supabase/schema.sql.
 */
const MESSAGES: Record<string, string> = {
  INVALID_CODE: 'Código do grupo incorreto.',
  INVALID_NAME: 'Escolha um nome de 1 a 20 caracteres.',
  GROUP_FULL: 'O grupo já está cheio (5 pessoas).',
  INVALID_TOKEN: 'Sua sessão expirou. Entre de novo com o código do grupo.',
  ALREADY_ACTIVE: 'Você já tem uma task ativa. Conclua ela primeiro.',
  NO_ACTIVE_TASK: 'Você não tem nenhuma task ativa.',
  TIER_LOCKED:
    'As tasks que sobraram deste tier já estão com outras pessoas. Espere alguém concluir.',
  ALL_DONE: 'Acabou: o grupo concluiu todas as 990 tasks.',
  UNDO_EXPIRED: 'Só dá para desfazer até 10 minutos depois de concluir.',
  NOT_INITIALIZED: 'O grupo ainda não foi configurado. Rode `npm run set-code`.',
  TASK_NOT_FOUND: 'Essa task não existe mais. Recarregue a página.',
  ALREADY_COMPLETED: 'Essa task já foi concluída pelo grupo.',
  TASK_TAKEN: 'Essa task está ativa com outra pessoa. Só quem está com ela pode concluir.',
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
    const code = Object.keys(MESSAGES).find((key) => error.message.includes(key))
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

export function listCompleted(token: string, limit = 50, offset = 0): Promise<CompletedPage> {
  return call<CompletedPage>('list_completed', {
    p_token: token,
    p_limit: limit,
    p_offset: offset,
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
