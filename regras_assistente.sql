-- Opção "Assistente" na importação do relatório: permite lembrar a escolha "Assistente" por código de vendedor.
-- Rode uma vez no Supabase: SQL Editor > New query > cole tudo > Run. Pode rodar de novo sem problema.

do $$
declare c record;
begin
  -- Remove a regra antiga que aceitava só "outros" e "ignorar" no destino (se existir).
  for c in select conname from pg_constraint
            where conrelid = 'public.regras_importacao'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%destino%' loop
    execute format('alter table public.regras_importacao drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.regras_importacao
  add constraint regras_importacao_destino_check
  check (destino in ('outros', 'ignorar', 'assistente'));
