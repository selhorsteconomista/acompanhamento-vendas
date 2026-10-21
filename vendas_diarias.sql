-- Aba "Vendas diárias": cria a tabela, as regras de acesso e o tempo real.
-- Rode uma vez no Supabase: SQL Editor > New query > cole tudo > Run.
-- Pode rodar de novo sem problema (não apaga nada).

create table if not exists public.vendas_diarias (
  data          date          not null,
  loja_id       text          not null references public.lojas(id) on update cascade,
  valor         numeric(14,2) not null default 0 check (valor >= 0),
  atualizado_em timestamptz   not null default now(),
  atualizado_por uuid         default auth.uid(),
  primary key (data, loja_id)
);

create index if not exists vendas_diarias_loja_data on public.vendas_diarias (loja_id, data);

alter table public.vendas_diarias enable row level security;

-- Leitura: cada pessoa vê os dias das lojas que ela já pode ver na tabela de lojas
-- (a subconsulta respeita as mesmas regras de acesso da tabela lojas).
drop policy if exists "vendas_diarias leitura" on public.vendas_diarias;
create policy "vendas_diarias leitura" on public.vendas_diarias
  for select to authenticated
  using (exists (select 1 from public.lojas l where l.id = vendas_diarias.loja_id));

-- Gravação: somente administradores aprovados.
drop policy if exists "vendas_diarias gravacao admin" on public.vendas_diarias;
create policy "vendas_diarias gravacao admin" on public.vendas_diarias
  for all to authenticated
  using (exists (select 1 from public.perfis p where p.id = auth.uid() and p.status = 'aprovado' and p.perfil = 'admin'))
  with check (exists (select 1 from public.perfis p where p.id = auth.uid() and p.status = 'aprovado' and p.perfil = 'admin'));

grant select, insert, update, delete on public.vendas_diarias to authenticated;

-- Atualização em tempo real entre aparelhos.
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'vendas_diarias') then
    alter publication supabase_realtime add table public.vendas_diarias;
  end if;
end $$;
