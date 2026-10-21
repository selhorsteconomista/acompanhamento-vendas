-- Dias úteis por loja: permite que cada loja tenha sua própria quantidade de dias úteis no mês.
-- Se a loja não tiver valor próprio, vale o padrão do mês (Cadastros > Períodos).
-- Rode uma vez no Supabase: SQL Editor > New query > cole tudo > Run. Pode rodar de novo sem problema.

create table if not exists public.dias_uteis_lojas (
  ano            int           not null,
  mes            int           not null check (mes between 1 and 12),
  loja_id        text          not null references public.lojas(id) on update cascade on delete cascade,
  dias_uteis     numeric(4,2)  not null check (dias_uteis >= 1 and dias_uteis <= 31),
  atualizado_em  timestamptz   not null default now(),
  atualizado_por uuid          default auth.uid(),
  primary key (ano, mes, loja_id)
);

alter table public.dias_uteis_lojas enable row level security;

-- Leitura: cada pessoa vê as lojas que já pode ver na tabela de lojas.
drop policy if exists "dias_uteis_lojas leitura" on public.dias_uteis_lojas;
create policy "dias_uteis_lojas leitura" on public.dias_uteis_lojas
  for select to authenticated
  using (exists (select 1 from public.lojas l where l.id = dias_uteis_lojas.loja_id));

-- Gravação: somente administradores aprovados.
drop policy if exists "dias_uteis_lojas gravacao admin" on public.dias_uteis_lojas;
create policy "dias_uteis_lojas gravacao admin" on public.dias_uteis_lojas
  for all to authenticated
  using (exists (select 1 from public.perfis p where p.id = auth.uid() and p.status = 'aprovado' and p.perfil = 'admin'))
  with check (exists (select 1 from public.perfis p where p.id = auth.uid() and p.status = 'aprovado' and p.perfil = 'admin'));

grant select, insert, update, delete on public.dias_uteis_lojas to authenticated;

-- Atualização em tempo real entre aparelhos.
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'dias_uteis_lojas') then
    alter publication supabase_realtime add table public.dias_uteis_lojas;
  end if;
end $$;
