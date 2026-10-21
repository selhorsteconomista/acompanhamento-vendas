-- Vendas diárias por vendedor: acrescenta o vendedor na tabela vendas_diarias.
-- Rode uma vez no Supabase: SQL Editor > New query > cole tudo > Run. Pode rodar de novo sem problema.
-- Se ainda não rodou o vendas_diarias.sql, rode ele antes deste.
-- Valores diários já lançados por loja (sem vendedor) passam para "Outros" e podem ser redistribuídos depois.

alter table public.vendas_diarias add column if not exists vendedor_id text;
update public.vendas_diarias set vendedor_id = '~outros' where vendedor_id is null;
alter table public.vendas_diarias alter column vendedor_id set default '~outros';
alter table public.vendas_diarias alter column vendedor_id set not null;

-- Chave passa a ser dia + loja + vendedor.
do $$
declare pk text;
begin
  select conname into pk from pg_constraint
   where conrelid = 'public.vendas_diarias'::regclass and contype = 'p';
  if pk is not null and pk <> 'vendas_diarias_pkey_v2' then
    execute format('alter table public.vendas_diarias drop constraint %I', pk);
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.vendas_diarias'::regclass and conname = 'vendas_diarias_pkey_v2') then
    alter table public.vendas_diarias add constraint vendas_diarias_pkey_v2 primary key (data, loja_id, vendedor_id);
  end if;
end $$;

create index if not exists vendas_diarias_loja_vend_data on public.vendas_diarias (loja_id, vendedor_id, data);

