-- Permite dias úteis com casas decimais (ex.: 23,5) na tabela de períodos.
-- Rode uma vez no Supabase: SQL Editor > New query > cole tudo > Run.
-- Os valores que já existem (23, 22...) são mantidos.

alter table public.periodos
  alter column dias_uteis type numeric(4,2) using dias_uteis::numeric;
