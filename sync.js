import { Redis } from '@upstash/redis';

const redis = Redis.fromEnv();

const LEASE_TTL = 300;              // аренда роли сборщика, сек
const MAX_TRADES = 200000;          // сколько сделок держим на сервер
const FEED_TTL = 60 * 60 * 24 * 60; // 60 дней
const PULL_LIMIT = 800;
const TRIM_EVERY = 50;              // обрезаем ленту не каждый пуш

function num(v, def = 0) {
  const n = Number(v);
  return Number.isFinite(n) ? n : def;
}

// оставляем только известные поля и приводим типы,
// чтобы в базу не улетело что попало
function cleanTrade(t) {
  return {
    ts: Math.floor(num(t.ts, Math.floor(Date.now() / 1000))),
    id: String(t.id ?? '').replace(/[^0-9]/g, '').slice(0, 12),
    ench: Math.max(0, Math.min(16, Math.floor(num(t.ench, 0)))),
    name: String(t.name ?? '').slice(0, 120),
    side: t.side === 'buy' ? 'buy' : 'sell',
    price: Math.max(0, Math.floor(num(t.price, 0))),
    qty: Math.max(0, Math.floor(num(t.qty, 0))),
    shop: String(t.shop ?? '').slice(0, 40),
    exact: t.exact ? 1 : 0
  };
}

/*
 * Один заход по одному игровому серверу:
 *   1. пробуем занять/продлить аренду
 *   2. забираем новое из ленты (если просили)
 *   3. дописываем своё (если мы держатель)
 *
 * Порядок важен: сначала читаем, потом пишем. Иначе свои же
 * свежие записи вернулись бы в том же ответе.
 */
async function handleServer(entry, client) {
  const id = String(entry.id ?? '').replace(/[^0-9]/g, '') || '0';
  const leaseKey = `cc:lease:${id}`;
  const seqKey = `cc:seq:${id}`;
  const feedKey = `cc:feed:${id}`;
  const trimKey = `cc:trim:${id}`;

  const acquired = await redis.set(leaseKey, client, { nx: true, ex: LEASE_TTL });
  const holder = acquired ? client : await redis.get(leaseKey);
  const isHolder = holder === client;

  if (isHolder && !acquired && entry.renew) {
    await redis.expire(leaseKey, LEASE_TTL);
  }

  const since = Math.max(0, Math.floor(num(entry.since, 0)));
  const wantPull = entry.pull !== false;

  let trades = [];
  if (wantPull) {
    const rows = await redis.zrange(feedKey, since + 1, '+inf', {
      byScore: true,
      offset: 0,
      count: PULL_LIMIT
    });
    trades = rows.map((r) => (typeof r === 'string' ? JSON.parse(r) : r));
  }

  let lastId = since;
  if (wantPull && trades.length) {
    lastId = trades[trades.length - 1].sid;
  }

  let added = 0;
  let firstPushedId = 0;

  const incoming = isHolder && Array.isArray(entry.trades) ? entry.trades.slice(0, 500) : [];
  if (incoming.length > 0) {
    // один INCRBY на всю пачку вместо N инкрементов
    const last = await redis.incrby(seqKey, incoming.length);
    firstPushedId = last - incoming.length + 1;

    const members = incoming.map((t, i) => {
      const sid = firstPushedId + i;
      return { score: sid, member: JSON.stringify({ sid, ...cleanTrade(t) }) };
    });

    await redis.zadd(feedKey, ...members);
    added = members.length;

    // двигаем курсор только если в этом же заходе читали ленту,
    // иначе можно перескочить чужие записи
    if (wantPull) lastId = last;

    const trims = await redis.incr(trimKey);
    if (trims % TRIM_EVERY === 0) {
      await redis.zremrangebyrank(feedKey, 0, -MAX_TRADES - 1);
      await redis.expire(feedKey, FEED_TTL);
    }
  }

  return {
    id: Number(id),
    isHolder,
    holder: holder ?? null,
    trades,
    lastId,
    added,
    firstPushedId,
    more: wantPull && trades.length === PULL_LIMIT
  };
}

export default async function handler(req, res) {
  if (req.method === 'GET') {
    return res.status(200).json({ ok: true, service: 'cc-market-sync', api: 2 });
  }
  if (req.method !== 'POST') {
    return res.status(405).json({ ok: false, error: 'POST only' });
  }

  let body = req.body;
  if (typeof body === 'string') {
    try { body = JSON.parse(body); } catch { body = {}; }
  }
  body = body || {};

  // если переменная окружения SYNC_KEY не задана — проверки нет
  const secret = process.env.SYNC_KEY;
  if (secret && body.key !== secret) {
    return res.status(403).json({ ok: false, error: 'bad key' });
  }

  const client = String(body.client ?? '').slice(0, 64);
  if (!client) return res.status(400).json({ ok: false, error: 'no client id' });

  const entries = Array.isArray(body.servers) ? body.servers.slice(0, 8) : [];
  if (entries.length === 0) {
    return res.status(400).json({ ok: false, error: 'no servers' });
  }

  try {
    const out = [];
    for (const entry of entries) {
      out.push(await handleServer(entry, client));
    }
    return res.status(200).json({ ok: true, servers: out });
  } catch (e) {
    return res.status(500).json({ ok: false, error: String(e && e.message ? e.message : e) });
  }
}
