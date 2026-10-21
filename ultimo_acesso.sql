-- Último acesso dos usuários: guarda quando cada pessoa abriu o app pela última vez.
-- Rode uma vez no Supabase: SQL Editor > New query > cole tudo > Run. Pode rodar de novo sem problema.

create table if not exists public.acessos (
  usuario_id    uuid primary key references auth.users(id) on delete cascade,
  ultimo_acesso timestamptz not null default now(),
  total         integer     not null default 1
);

alter table public.acessos enable row level security;

-- Somente administradores aprovados consultam. Ninguém grava direto: só pela função abaixo.
drop policy if exists "acessos leitura admin" on public.acessos;
create policy "acessos leitura admin" on public.acessos
  for select to authenticated
  using (exists (select 1 from public.perfis p where p.id = auth.uid() and p.status = 'aprovado' and p.perfil = 'admin'));

grant select on public.acessos to authenticated;

-- Chamada pelo app ao abrir (no máximo a cada 10 minutos por pessoa).
create or replace function public.registrar_acesso()
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.acessos (usuario_id, ultimo_acesso, total)
  select auth.uid(), now(), 1
  where auth.uid() is not null
  on conflict (usuario_id) do update
    set ultimo_acesso = now(), total = public.acessos.total + 1;
$$;

revoke all on function public.registrar_acesso() from public, anon;
grant execute on function public.registrar_acesso() to authenticated;

-- Ponto de partida: quem já entrou antes recebe a data do último login registrado pelo Supabase.
insert into public.acessos (usuario_id, ultimo_acesso, total)
select u.id, u.last_sign_in_at, 1
from auth.users u
where u.last_sign_in_at is not null
on conflict (usuario_id) do nothing;
