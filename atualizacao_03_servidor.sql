-- =====================================================================
-- atualizacao_03_servidor.sql
-- Leva toda a leitura e gravação de dados para o servidor (Postgres).
--
-- Depois desta atualização:
--   * O navegador NÃO acessa mais nenhuma tabela diretamente.
--   * Tudo passa por funções do banco que conferem, no servidor, quem é o
--     usuário (auth.uid()), se está aprovado e o que o perfil dele permite.
--   * "Quem alterou" e "quando" são preenchidos pelo servidor.
--   * A atualização ao vivo usa a tabela "sinais", que só diz QUAL tabela
--     mudou (nunca os dados). O app então busca de novo pelas funções.
--
-- Como usar: Supabase > SQL Editor > New query > cole tudo > Run.
-- O script roda inteiro ou não roda nada (se der erro, nada muda).
-- Pode ser executado de novo sem problema.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Conferência de segurança antes de mexer em permissões.
--    As funções que já existem (lojas_publicas, solicitar_acesso) e o
--    gatilho que cria o perfil no cadastro precisam rodar como "security
--    definer", senão deixariam de funcionar quando o acesso direto às
--    tabelas for retirado. Se alguma não estiver assim, o script para
--    aqui sem alterar nada.
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as fn
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('lojas_publicas','solicitar_acesso') and not p.prosecdef
    union all
    select t.tgfoid::regprocedure::text
    from pg_trigger t join pg_proc p on p.oid = t.tgfoid
    where t.tgrelid = 'auth.users'::regclass and not t.tgisinternal and not p.prosecdef
  loop
    raise exception 'A função % não é SECURITY DEFINER. Nada foi alterado. Envie o código dela para ajustarmos antes de rodar esta atualização.', r.fn;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 1. Esquema privado para funções auxiliares (não fica exposto na API).
-- ---------------------------------------------------------------------
create schema if not exists app;
revoke all on schema app from public, anon, authenticated;

-- Perfil aprovado do usuário logado (ou nada).
create or replace function app.meu_perfil_aprovado()
returns public.perfis
language sql stable security definer set search_path = ''
as $$
  select p.* from public.perfis p
  where p.id = auth.uid() and p.status = 'aprovado' and p.perfil in ('admin','gestao','vendas')
$$;

create or replace function app.aprovado()
returns boolean
language sql stable security definer set search_path = ''
as $$ select (app.meu_perfil_aprovado()).id is not null $$;

create or replace function app.eh_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce((app.meu_perfil_aprovado()).perfil = 'admin', false) $$;

create or replace function app.exigir_admin()
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not app.eh_admin() then
    raise exception 'Seu perfil não tem permissão para esta alteração.' using errcode = '42501';
  end if;
end $$;

-- Converte um array (text[] ou jsonb) em text[].
create or replace function app.txt_array(v jsonb)
returns text[]
language sql immutable set search_path = ''
as $$
  select coalesce(array(select jsonb_array_elements_text(case when jsonb_typeof(v) = 'array' then v else '[]'::jsonb end)), '{}')
$$;

-- Lojas que o usuário logado pode ver.
--   admin  -> todas
--   gestao -> lojas das regiões marcadas + lojas marcadas
--   vendas -> lojas marcadas
--   outros / não aprovado -> nenhuma
create or replace function app.lojas_visiveis()
returns text[]
language plpgsql stable security definer set search_path = ''
as $$
declare
  p public.perfis;
  regs text[];
  ljs text[];
begin
  p := app.meu_perfil_aprovado();
  if p.id is null then return '{}'; end if;
  if p.perfil = 'admin' then
    return array(select l.id::text from public.lojas l);
  end if;
  ljs := app.txt_array(to_jsonb(p.lojas));
  if p.perfil = 'gestao' then
    regs := app.txt_array(to_jsonb(p.regioes));
    return array(select l.id::text from public.lojas l
                 where l.id::text = any(ljs) or coalesce(l.regiao,'') = any(regs));
  end if;
  return array(select l.id::text from public.lojas l where l.id::text = any(ljs));
end $$;

-- ---------------------------------------------------------------------
-- 2. Tabela de sinais para a atualização ao vivo (sem dados sensíveis).
-- ---------------------------------------------------------------------
create table if not exists public.sinais (
  tabela text primary key,
  em timestamptz not null default now()
);
alter table public.sinais enable row level security;
revoke all on public.sinais from anon, authenticated;
grant select on public.sinais to authenticated;
drop policy if exists "sinais: usuarios logados leem" on public.sinais;
create policy "sinais: usuarios logados leem" on public.sinais for select to authenticated using (true);

create or replace function app.sinalizar()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.sinais (tabela, em) values (tg_table_name, now())
  on conflict (tabela) do update set em = excluded.em;
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['lojas','vendedores','periodos','lancamentos','perfis','historico','pre_aprovacoes','regras_importacao','municipios'] loop
    if to_regclass('public.'||t) is null then continue; end if;
    execute format('drop trigger if exists zz_sinalizar on public.%I', t);
    execute format('create trigger zz_sinalizar after insert or update or delete on public.%I for each statement execute function app.sinalizar()', t);
  end loop;
end $$;

-- Realtime: publica só a tabela de sinais; tira as tabelas de dados.
do $$
declare t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then return; end if;
  foreach t in array array['lojas','vendedores','periodos','lancamentos','perfis','historico','pre_aprovacoes','regras_importacao','municipios'] loop
    if exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
      execute format('alter publication supabase_realtime drop table public.%I', t);
    end if;
  end loop;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='sinais') then
    alter publication supabase_realtime add table public.sinais;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. Funções de LEITURA (o app chama via .rpc('ler_...')).
-- ---------------------------------------------------------------------
create or replace function public.ler_meu_perfil()
returns setof public.perfis
language sql stable security definer set search_path = ''
as $$ select * from public.perfis where id = auth.uid() $$;

create or replace function public.ler_lojas()
returns setof public.lojas
language sql stable security definer set search_path = ''
as $$ select * from public.lojas where id::text in (select unnest(app.lojas_visiveis())) $$;

create or replace function public.ler_vendedores()
returns setof public.vendedores
language sql stable security definer set search_path = ''
as $$
  select v.* from public.vendedores v
  where app.eh_admin()
     or v.loja_id::text in (select unnest(app.lojas_visiveis()))
     or exists (select 1 from public.lancamentos x
                where x.vendedor_id = v.id and x.loja_id::text in (select unnest(app.lojas_visiveis())))
$$;

create or replace function public.ler_periodos()
returns setof public.periodos
language sql stable security definer set search_path = ''
as $$ select * from public.periodos where app.aprovado() $$;

create or replace function public.ler_lancamentos()
returns setof public.lancamentos
language sql stable security definer set search_path = ''
as $$ select * from public.lancamentos where loja_id::text in (select unnest(app.lojas_visiveis())) $$;

create or replace function public.ler_perfis()
returns setof public.perfis
language plpgsql stable security definer set search_path = ''
as $$ begin perform app.exigir_admin(); return query select * from public.perfis; end $$;

create or replace function public.ler_historico()
returns setof public.historico
language plpgsql stable security definer set search_path = ''
as $$ begin perform app.exigir_admin(); return query select * from public.historico; end $$;

create or replace function public.ler_pre_aprovacoes()
returns setof public.pre_aprovacoes
language plpgsql stable security definer set search_path = ''
as $$ begin perform app.exigir_admin(); return query select * from public.pre_aprovacoes; end $$;

create or replace function public.ler_regras_importacao()
returns setof public.regras_importacao
language plpgsql stable security definer set search_path = ''
as $$ begin perform app.exigir_admin(); return query select * from public.regras_importacao; end $$;

create or replace function public.ler_municipios()
returns setof public.municipios
language plpgsql stable security definer set search_path = ''
as $$ begin perform app.exigir_admin(); return query select * from public.municipios; end $$;

-- ---------------------------------------------------------------------
-- 4. Funções de GRAVAÇÃO (somente administradores).
--    p_linhas é uma lista JSON de linhas, no mesmo formato de antes.
-- ---------------------------------------------------------------------
create or replace function public.salvar_lojas(p_linhas jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.exigir_admin();
  insert into public.lojas (id, nome, regiao, uf, cidade, ativo)
  select r.id, r.nome, coalesce(r.regiao,''), coalesce(r.uf,''), coalesce(r.cidade,''), coalesce(r.ativo, true)
  from jsonb_populate_recordset(null::public.lojas, p_linhas) r
  on conflict (id) do update set nome = excluded.nome, regiao = excluded.regiao, uf = excluded.uf,
    cidade = excluded.cidade, ativo = excluded.ativo;
end $$;

create or replace function public.salvar_vendedores(p_linhas jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.exigir_admin();
  insert into public.vendedores (id, nome, loja_id, ativo)
  select r.id, r.nome, r.loja_id, coalesce(r.ativo, true)
  from jsonb_populate_recordset(null::public.vendedores, p_linhas) r
  on conflict (id) do update set nome = excluded.nome, loja_id = excluded.loja_id, ativo = excluded.ativo;
end $$;

create or replace function public.salvar_periodos(p_linhas jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.exigir_admin();
  insert into public.periodos (ano, mes, dias_uteis)
  select r.ano, r.mes, r.dias_uteis
  from jsonb_populate_recordset(null::public.periodos, p_linhas) r
  on conflict (ano, mes) do update set dias_uteis = excluded.dias_uteis;
end $$;

create or replace function public.salvar_lancamentos(p_linhas jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.exigir_admin();
  insert into public.lancamentos (ano, mes, loja_id, vendedor_id, meta, venda_real, venda_ideal, devolucoes,
                                  atualizado_em, atualizado_por, origem)
  select r.ano, r.mes, r.loja_id, r.vendedor_id, r.meta, r.venda_real, r.venda_ideal, r.devolucoes,
         coalesce(r.atualizado_em, now()), auth.uid(), coalesce(r.origem, 'manual')
  from jsonb_populate_recordset(null::public.lancamentos, p_linhas) r
  on conflict (ano, mes, loja_id, vendedor_id) do update set
    meta = excluded.meta, venda_real = excluded.venda_real, venda_ideal = excluded.venda_ideal,
    devolucoes = excluded.devolucoes, atualizado_em = excluded.atualizado_em,
    atualizado_por = excluded.atualizado_por, origem = excluded.origem;
end $$;

create or replace function public.salvar_municipios(p_linhas jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.exigir_admin();
  insert into public.municipios (uf, nome)
  select r.uf, r.nome from jsonb_populate_recordset(null::public.municipios, p_linhas) r
  on conflict (uf, nome) do nothing;
end $$;

create or replace function public.excluir_loja(p_id text)
returns void
language plpgsql security definer set search_path = ''
as $$ begin perform app.exigir_admin(); delete from public.lojas where id::text = p_id; end $$;

create or replace function public.excluir_vendedor(p_id text)
returns void
language plpgsql security definer set search_path = ''
as $$ begin perform app.exigir_admin(); delete from public.vendedores where id::text = p_id; end $$;

create or replace function public.excluir_periodo(p_ano int, p_mes int)
returns void
language plpgsql security definer set search_path = ''
as $$ begin perform app.exigir_admin(); delete from public.periodos where ano = p_ano and mes = p_mes; end $$;

create or replace function public.salvar_regras_importacao(p_set jsonb, p_del text[])
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.exigir_admin();
  if p_set is not null and jsonb_array_length(p_set) > 0 then
    insert into public.regras_importacao (vendedor_id, destino)
    select r.vendedor_id, r.destino from jsonb_populate_recordset(null::public.regras_importacao, p_set) r
    on conflict (vendedor_id) do update set destino = excluded.destino;
  end if;
  if p_del is not null and cardinality(p_del) > 0 then
    delete from public.regras_importacao where vendedor_id::text = any(p_del);
  end if;
end $$;

-- Histórico: o servidor grava quem fez e quando.
create or replace function public.registrar_historico(p_tipo text, p_descricao text, p_detalhes jsonb default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.exigir_admin();
  insert into public.historico (tipo, descricao, detalhes, usuario, em)
  select r.tipo, r.descricao, r.detalhes, r.usuario, now()
  from jsonb_populate_record(null::public.historico,
         jsonb_build_object('tipo', p_tipo, 'descricao', p_descricao, 'detalhes', p_detalhes, 'usuario', auth.uid())) r;
end $$;

-- ---------------------------------------------------------------------
-- 5. Usuários e pré-aprovações (somente administradores).
-- ---------------------------------------------------------------------
create or replace function public.atualizar_acesso(p_id uuid, p_perfil text, p_regioes jsonb, p_lojas jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare r public.perfis;
begin
  perform app.exigir_admin();
  if p_perfil not in ('admin','gestao','vendas') then
    raise exception 'Perfil inválido.' using errcode = '22P02';
  end if;
  if p_id = auth.uid() and p_perfil <> 'admin' then
    raise exception 'Você não pode tirar o seu próprio acesso de administrador.' using errcode = 'P0001';
  end if;
  r := jsonb_populate_record(null::public.perfis,
         jsonb_build_object('regioes', coalesce(p_regioes,'[]'::jsonb), 'lojas', coalesce(p_lojas,'[]'::jsonb)));
  update public.perfis p set
    perfil = p_perfil, regioes = r.regioes, lojas = r.lojas, status = 'aprovado',
    decidido_em = now(), decidido_por = auth.uid(),
    aprovado_em = case when p.status = 'aprovado' and p.aprovado_em is not null then p.aprovado_em else now() end
  where p.id = p_id;
end $$;

create or replace function public.definir_status(p_id uuid, p_status text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.exigir_admin();
  if p_status not in ('aprovado','recusado','bloqueado') then
    raise exception 'Situação inválida.' using errcode = '22P02';
  end if;
  if p_id = auth.uid() then
    raise exception 'Você não pode alterar a situação do seu próprio acesso.' using errcode = 'P0001';
  end if;
  update public.perfis set status = p_status, decidido_em = now(), decidido_por = auth.uid() where id = p_id;
end $$;

create or replace function public.pre_aprovar(p_email text, p_nome text, p_perfil text, p_regioes jsonb, p_lojas jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform app.exigir_admin();
  if p_perfil not in ('admin','gestao','vendas') then
    raise exception 'Perfil inválido.' using errcode = '22P02';
  end if;
  insert into public.pre_aprovacoes (email, nome, perfil, regioes, lojas)
  select r.email, r.nome, r.perfil, r.regioes, r.lojas
  from jsonb_populate_record(null::public.pre_aprovacoes,
         jsonb_build_object('email', lower(trim(p_email)), 'nome', coalesce(p_nome,''), 'perfil', p_perfil,
                            'regioes', coalesce(p_regioes,'[]'::jsonb), 'lojas', coalesce(p_lojas,'[]'::jsonb))) r
  on conflict (email) do update set nome = excluded.nome, perfil = excluded.perfil,
    regioes = excluded.regioes, lojas = excluded.lojas;
end $$;

create or replace function public.remover_pre_aprovacao(p_email text)
returns void
language plpgsql security definer set search_path = ''
as $$ begin perform app.exigir_admin(); delete from public.pre_aprovacoes where email = lower(trim(p_email)); end $$;

-- ---------------------------------------------------------------------
-- 6. Fecha o acesso direto às tabelas e libera só as funções.
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['lojas','vendedores','periodos','lancamentos','perfis','historico','pre_aprovacoes','regras_importacao','municipios'] loop
    if to_regclass('public.'||t) is null then continue; end if;
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
  end loop;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.ler_meu_perfil()','public.ler_lojas()','public.ler_vendedores()','public.ler_periodos()',
    'public.ler_lancamentos()','public.ler_perfis()','public.ler_historico()','public.ler_pre_aprovacoes()',
    'public.ler_regras_importacao()','public.ler_municipios()',
    'public.salvar_lojas(jsonb)','public.salvar_vendedores(jsonb)','public.salvar_periodos(jsonb)',
    'public.salvar_lancamentos(jsonb)','public.salvar_municipios(jsonb)',
    'public.excluir_loja(text)','public.excluir_vendedor(text)','public.excluir_periodo(int,int)',
    'public.salvar_regras_importacao(jsonb,text[])','public.registrar_historico(text,text,jsonb)',
    'public.atualizar_acesso(uuid,text,jsonb,jsonb)','public.definir_status(uuid,text)',
    'public.pre_aprovar(text,text,text,jsonb,jsonb)','public.remover_pre_aprovacao(text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- Funções auxiliares privadas: ninguém de fora chama.
revoke all on all functions in schema app from public, anon, authenticated;

commit;

-- ---------------------------------------------------------------------
-- 7. Conferência: todas as linhas devem mostrar "acesso_direto = false".
-- ---------------------------------------------------------------------
select c.relname as tabela,
       c.relrowsecurity as rls_ligado,
       (has_table_privilege('authenticated', c.oid, 'select,insert,update,delete')
        or has_table_privilege('anon', c.oid, 'select,insert,update,delete')) as acesso_direto
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r' and c.relname <> 'sinais'
order by 1;
