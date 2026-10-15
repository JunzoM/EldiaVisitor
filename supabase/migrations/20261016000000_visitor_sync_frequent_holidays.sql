-- 来店記録アプリ：通信の削減・よく使う組み合わせ・祝日表の自動補充
-- 共通の Supabase プロジェクト（cleaning-log）に適用する。何度流しても同じ結果になる。

-- =========================================================
-- 1. 同期を1回の呼び出しにまとめる（直前5組×2店舗＋今日の件数）
--    p_known に前回の版を渡すと、変化がなければ版だけを返す（通信量がほぼゼロ）
-- =========================================================

create index if not exists visitor_logs_created_idx on public.visitor_logs (created_at desc);

create or replace function public.visitor_sync(p_since timestamptz, p_known text default null, p_recent int default 5)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v text;
begin
  -- 版＝件数＋最後に登録された時刻（追加・削除のどちらでも変わる）
  select count(*)::text || ':' || coalesce(max(created_at)::text, '') into v from visitor_logs;
  if p_known is not null and p_known = v then
    return jsonb_build_object('v', v, 'changed', false);
  end if;
  return jsonb_build_object(
    'v', v,
    'changed', true,
    'recent', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.store, r.visited_at desc)
      from unnest(array['modern', 'luxury']) s(store)
      cross join lateral (
        select l.id, l.client_id, l.store, l.visited_at, l.segment,
               l.m10, l.m20, l.m30, l.m40, l.m50, l.m60,
               l.f10, l.f20, l.f30, l.f40, l.f50, l.f60
        from visitor_logs l
        where l.store = s.store
        order by l.visited_at desc
        limit p_recent
      ) r
    ), '[]'::jsonb),
    'today', coalesce((
      select jsonb_agg(jsonb_build_object('store', l.store, 'total', l.total, 'client_id', l.client_id) order by l.visited_at)
      from visitor_logs l
      where l.visited_at >= p_since
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.visitor_sync(timestamptz, text, int) from public, anon;
grant execute on function public.visitor_sync(timestamptz, text, int) to authenticated;

-- =========================================================
-- 2. よく使う組み合わせ（店舗ごと、直近 p_days 日で3回以上あった客層×人数の上位）
-- =========================================================

create or replace function public.visitor_frequent(p_days int default 30, p_limit int default 3)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.store, t.n desc, t.total, t.segment), '[]'::jsonb)
  from (
    select *, row_number() over (partition by store order by n desc, total, segment) as rk
    from (
      select store, segment, m10, m20, m30, m40, m50, m60, f10, f20, f30, f40, f50, f60,
             max(total) as total, count(*)::int as n
      from visitor_logs
      where visited_at >= now() - make_interval(days => p_days)
      group by store, segment, m10, m20, m30, m40, m50, m60, f10, f20, f30, f40, f50, f60
      having count(*) >= 3
    ) g
  ) t
  where t.rk <= p_limit
$$;

revoke all on function public.visitor_frequent(int, int) from public, anon;
grant execute on function public.visitor_frequent(int, int) to authenticated;

-- =========================================================
-- 3. 祝日表の自動補充（毎月1日に、今年〜翌々年の祝日を足す）
--    計算は祝日法（2020年以降の規定）。春分・秋分は 1980〜2099 年で有効な近似式。
--    手で登録・修正した日は上書きしない（特例の祝日は手で直す）。
--    2025〜2027年の登録済みの54日と完全に一致することを確認済み。
-- =========================================================

create schema if not exists private;

create or replace function private.jp_holidays_for(p_year int)
returns table(d date, name text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  k int := p_year - 1980;
  spring int := floor(20.8431 + 0.242194 * k - floor(k / 4.0));
  autumn int := floor(23.2488 + 0.242194 * k - floor(k / 4.0));
  h record;
  x date;
begin
  if p_year < 2020 or p_year > 2099 then
    raise exception '2020〜2099年のみ対応: %', p_year;
  end if;

  create temp table if not exists _h(d date primary key, name text) on commit drop;
  delete from _h;

  -- 第n月曜日 = 1日 + (その週の月曜までの日数) + 7×(n-1)
  insert into _h values
    (make_date(p_year, 1, 1), '元日'),
    (make_date(p_year, 1, 1) + ((8 - extract(isodow from make_date(p_year, 1, 1))::int) % 7) + 7, '成人の日'),
    (make_date(p_year, 2, 11), '建国記念の日'),
    (make_date(p_year, 2, 23), '天皇誕生日'),
    (make_date(p_year, 3, spring), '春分の日'),
    (make_date(p_year, 4, 29), '昭和の日'),
    (make_date(p_year, 5, 3), '憲法記念日'),
    (make_date(p_year, 5, 4), 'みどりの日'),
    (make_date(p_year, 5, 5), 'こどもの日'),
    (make_date(p_year, 7, 1) + ((8 - extract(isodow from make_date(p_year, 7, 1))::int) % 7) + 14, '海の日'),
    (make_date(p_year, 8, 11), '山の日'),
    (make_date(p_year, 9, 1) + ((8 - extract(isodow from make_date(p_year, 9, 1))::int) % 7) + 14, '敬老の日'),
    (make_date(p_year, 9, autumn), '秋分の日'),
    (make_date(p_year, 10, 1) + ((8 - extract(isodow from make_date(p_year, 10, 1))::int) % 7) + 7, 'スポーツの日'),
    (make_date(p_year, 11, 3), '文化の日'),
    (make_date(p_year, 11, 23), '勤労感謝の日');

  -- 国民の休日：前日と翌日が祝日で、その日自体は祝日でも日曜でもない日
  insert into _h
  select a.d + 1, '国民の休日'
  from _h a
  join _h b on b.d = a.d + 2
  where not exists (select 1 from _h c where c.d = a.d + 1)
    and extract(isodow from a.d + 1) <> 7;

  -- 振替休日：日曜の祝日のあと、最初の祝日でない日
  for h in select t.d from _h t where extract(isodow from t.d) = 7 order by t.d loop
    x := h.d + 1;
    while exists (select 1 from _h t where t.d = x) loop
      x := x + 1;
    end loop;
    insert into _h values (x, '振替休日');
  end loop;

  return query select t.d, t.name from _h t order by t.d;
end;
$$;

create or replace function private.fill_jp_holidays()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  y int := extract(year from (now() at time zone 'Asia/Tokyo'))::int;
  n int := 0;
  added int;
begin
  for yy in y .. y + 2 loop
    insert into public.jp_holidays(d, name)
    select g.d, g.name from private.jp_holidays_for(yy) g
    on conflict (d) do nothing;
    get diagnostics added = row_count;
    n := n + added;
  end loop;
  return n;
end;
$$;

revoke all on function private.jp_holidays_for(int) from public, anon, authenticated;
revoke all on function private.fill_jp_holidays() from public, anon, authenticated;

comment on table public.jp_holidays is
  '日本の祝日（来店客層記録の祝日・祝前日の判定用）。毎月1日に private.fill_jp_holidays() が今年〜翌々年分を自動で補充する。特例の祝日は手で修正する';

select cron.unschedule(jobid) from cron.job where jobname = 'fill-jp-holidays';
select cron.schedule('fill-jp-holidays', '10 0 1 * *', 'select private.fill_jp_holidays()');

-- 今すぐ一度実行して2028年分を補充
select private.fill_jp_holidays();
