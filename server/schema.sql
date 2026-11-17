create table if not exists assets(symbol text primary key,name text not null,sector text not null,kind text not null,price numeric(18,4) not null check(price>0),previous_price numeric(18,4) not null,dividend_rate numeric(8,4) not null default 0);
create table if not exists profiles(user_id uuid primary key references auth.users(id) on delete cascade,display_name text not null,balance numeric(18,2) not null default 1000000 check(balance>=0),created_at timestamptz not null default now());
create table if not exists positions(user_id uuid references profiles(user_id) on delete cascade,symbol text references assets(symbol),quantity integer not null check(quantity>=0),avg_price numeric(18,4) not null default 0,primary key(user_id,symbol));
create table if not exists transactions(id bigserial primary key,user_id uuid references profiles(user_id) on delete cascade,symbol text references assets(symbol),type text not null check(type in ('buy','sell','dividend')),quantity integer not null,price numeric(18,4) not null,fee numeric(18,2) not null default 0,total numeric(18,2) not null,created_at timestamptz not null default now());
create table if not exists candles(symbol text references assets(symbol),bucket timestamptz not null,open numeric(18,4) not null,high numeric(18,4) not null,low numeric(18,4) not null,close numeric(18,4) not null,primary key(symbol,bucket));
create table if not exists events(id bigserial primary key,title text not null,description text not null,symbols text[] not null,impact numeric(8,4) not null,created_at timestamptz not null default now());
create table if not exists engine_state(id integer primary key check(id=1),last_tick timestamptz not null default now(),last_event timestamptz not null default now(),last_crisis timestamptz not null default now(),last_dividend timestamptz not null default now());
insert into engine_state(id) values(1) on conflict do nothing;
insert into assets(symbol,name,sector,kind,price,previous_price,dividend_rate) values
('SBER','Сбербанк','Банки','stock',315.40,315.40,0.0005),('T','Т-Банк','Финтех','stock',3300,3300,0),('GAZP','Газпром','Газ','stock',142.80,142.80,0.0004),('YDEX','Яндекс','Технологии','stock',4200,4200,0),('LKOH','Лукойл','Нефть','stock',6900,6900,0.0006),('AAPL','Apple','Технологии','stock',24500,24500,0.0002),('NVDA','NVIDIA','Технологии','stock',18000,18000,0),('TSLA','Tesla','Авто','stock',25000,25000,0),('USD','Доллар США','Валюты','currency',90,90,0),('EUR','Евро','Валюты','currency',98,98,0) on conflict do nothing;
alter table assets enable row level security; alter table profiles enable row level security; alter table positions enable row level security; alter table transactions enable row level security; alter table candles enable row level security; alter table events enable row level security; alter table engine_state enable row level security;
create or replace function execute_trade(p_user uuid,p_symbol text,p_side text,p_quantity integer) returns jsonb language plpgsql security definer set search_path=public as $$
declare a assets%rowtype; b numeric; q integer; avg numeric; gross numeric; fee numeric; amount numeric;
begin
 if p_user <> auth.uid() and current_setting('app.server_trade',true) <> 'on' then raise exception 'Unauthorized'; end if;
 if p_quantity is null or p_quantity < 1 or p_quantity > 1000000 or p_side not in ('buy','sell') then raise exception 'Invalid trade'; end if;
 select * into a from assets where symbol=p_symbol for share; if not found then raise exception 'Unknown asset'; end if;
 insert into profiles(user_id,display_name) values(p_user,'Игрок '||left(p_user::text,6)) on conflict do nothing;
 select balance into b from profiles where user_id=p_user for update;
 select quantity,avg_price into q,avg from positions where user_id=p_user and symbol=p_symbol for update;
 q:=coalesce(q,0); avg:=coalesce(avg,0); gross:=round(a.price*p_quantity,2); fee:=round(gross*0.002,2);
 if p_side='buy' then
  amount:=gross+fee; if b<amount then raise exception 'Insufficient funds'; end if;
  update profiles set balance=balance-amount where user_id=p_user;
  insert into positions(user_id,symbol,quantity,avg_price) values(p_user,p_symbol,p_quantity,a.price) on conflict(user_id,symbol) do update set avg_price=(positions.quantity*positions.avg_price+p_quantity*a.price)/(positions.quantity+p_quantity),quantity=positions.quantity+p_quantity;
 else
  if q<p_quantity then raise exception 'Insufficient position'; end if;
  amount:=gross-fee; update profiles set balance=balance+amount where user_id=p_user;
  update positions set quantity=quantity-p_quantity where user_id=p_user and symbol=p_symbol;
 end if;
 insert into transactions(user_id,symbol,type,quantity,price,fee,total) values(p_user,p_symbol,p_side,p_quantity,a.price,fee,amount);
 return jsonb_build_object('symbol',p_symbol,'side',p_side,'quantity',p_quantity,'price',a.price,'fee',fee,'total',amount);
end $$;
revoke all on function execute_trade(uuid,text,text,integer) from public;
