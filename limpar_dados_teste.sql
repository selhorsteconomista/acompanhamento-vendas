-- LIMPEZA PARA TESTES — NÃO TEM COMO DESFAZER.
-- Antes de rodar, baixe o backup completo no app (Cadastros > botão "Baixar backup").
--
-- Apaga: vendas diárias, lançamentos mensais (metas, venda real, devoluções),
--        dias úteis (padrão do mês e por loja), vendedores e o histórico.
-- Mantém: lojas, usuários/acessos, pré-aprovações, municípios e as regras de
--         importação ("Outros"/"Ignorar" lembrados para cada código do relatório).
--
-- Rode no Supabase: SQL Editor > New query > cole tudo > Run.

do $$
declare
  t text;
  n bigint;
begin
  foreach t in array array[
    'vendas_diarias',
    'lancamentos',
    'dias_uteis_lojas',
    'periodos',
    'vendedores',
    'historico'
  ] loop
    if to_regclass('public.' || t) is not null then
      execute format('delete from public.%I', t);
      get diagnostics n = row_count;
      raise notice '%: % registros apagados', t, n;
    end if;
  end loop;
end $$;

-- Para apagar também as regras de importação lembradas, tire os dois traços da linha abaixo:
-- delete from public.regras_importacao;
