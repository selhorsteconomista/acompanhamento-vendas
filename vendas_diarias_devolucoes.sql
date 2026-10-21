-- Devoluções nas vendas diárias: guarda as devoluções que vêm do relatório diário do sistema.
-- Rode uma vez no Supabase: SQL Editor > New query > cole tudo > Run. Pode rodar de novo sem problema.
-- Rode depois do vendas_diarias.sql e do vendas_diarias_vendedor.sql.

alter table public.vendas_diarias add column if not exists devolucoes numeric(14,2) check (devolucoes >= 0);
