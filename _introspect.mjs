// Standalone schema introspection -> database.sql (schema only, public schema).
// Uses Postgres' own DDL-emitting functions for faithful output.
import 'dotenv/config';
import fs from 'fs';
import pkg from 'pg';
const { Client } = pkg;

const ssl =
  process.env.DB_SSL === 'true' || (process.env.DB_HOST || '').includes('neon')
    ? { rejectUnauthorized: false }
    : false;

const client = new Client({
  host: process.env.DB_HOST,
  port: process.env.DB_PORT ? parseInt(process.env.DB_PORT, 10) : 5432,
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: String(process.env.DB_PASSWORD ?? ''),
  ssl,
});

const q = async (text, params) => (await client.query(text, params)).rows;
const out = [];
const w = (s = '') => out.push(s);

await client.connect();

// ---- server / db info -------------------------------------------------------
const [{ version }] = await q('select version()');
const [{ current_database }] = await q('select current_database()');

w('--');
w('-- PostgreSQL schema dump (schema only, no data)');
w(`-- Source database: ${current_database}`);
w(`-- Server: ${version}`);
w('-- Generated via catalog introspection (pg_get_* functions)');
w('-- Restore order: extensions, types, functions, sequences, tables,');
w('--   defaults, constraints (PK/UNIQUE/CHECK), foreign keys, indexes, triggers, views.');
w('--');
w('');
w('SET statement_timeout = 0;');
w('SET client_encoding = \'UTF8\';');
w('SET standard_conforming_strings = on;');
w('SET check_function_bodies = false;');
w('SET client_min_messages = warning;');
w('');

// ---- extensions -------------------------------------------------------------
const exts = await q(`
  select extname from pg_extension
  where extname not in ('plpgsql')
  order by extname`);
if (exts.length) {
  w('-- ============================ EXTENSIONS ============================');
  for (const e of exts) w(`CREATE EXTENSION IF NOT EXISTS "${e.extname}";`);
  w('');
}

// ---- enum / composite types (user-defined) ---------------------------------
const enums = await q(`
  select t.typname,
         array_agg(e.enumlabel order by e.enumsortorder) as labels
  from pg_type t
  join pg_enum e on e.enumtypid = t.oid
  join pg_namespace n on n.oid = t.typnamespace
  where n.nspname = 'public'
  group by t.typname
  order by t.typname`);
if (enums.length) {
  w('-- ============================ ENUM TYPES ===========================');
  for (const t of enums) {
    const vals = t.labels.map((l) => `'${l.replace(/'/g, "''")}'`).join(', ');
    w(`CREATE TYPE public.${t.typname} AS ENUM (${vals});`);
  }
  w('');
}

// ---- domains ----------------------------------------------------------------
const domains = await q(`
  select t.typname,
         format_type(t.typbasetype, t.typtypmod) as basetype,
         t.typnotnull,
         pg_get_expr(t.typdefaultbin, 0) as defexpr
  from pg_type t
  join pg_namespace n on n.oid = t.typnamespace
  where n.nspname='public' and t.typtype='d'
  order by t.typname`);
if (domains.length) {
  w('-- ============================ DOMAINS ==============================');
  for (const d of domains) {
    let s = `CREATE DOMAIN public.${d.typname} AS ${d.basetype}`;
    if (d.defexpr) s += ` DEFAULT ${d.defexpr}`;
    if (d.typnotnull) s += ' NOT NULL';
    w(s + ';');
  }
  w('');
}

// ---- functions (needed before triggers; may back column defaults) ----------
const funcs = await q(`
  select pg_get_functiondef(p.oid) as def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public'
    and p.prokind in ('f','p','w')
  order by p.proname`);
if (funcs.length) {
  w('-- ============================ FUNCTIONS ============================');
  for (const f of funcs) {
    w(f.def.trimEnd() + (f.def.trimEnd().endsWith(';') ? '' : ';'));
    w('');
  }
}

// ---- sequences --------------------------------------------------------------
const seqs = await q(`
  select c.relname as seqname,
         s.seqstart, s.seqincrement, s.seqmax, s.seqmin, s.seqcache, s.seqcycle,
         format_type(s.seqtypid, null) as seqtype
  from pg_sequence s
  join pg_class c on c.oid = s.seqrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname='public'
  order by c.relname`);
if (seqs.length) {
  w('-- ============================ SEQUENCES ============================');
  for (const s of seqs) {
    let str = `CREATE SEQUENCE IF NOT EXISTS public.${s.seqname}\n`;
    str += `    AS ${s.seqtype}\n`;
    str += `    START WITH ${s.seqstart}\n`;
    str += `    INCREMENT BY ${s.seqincrement}\n`;
    str += `    MINVALUE ${s.seqmin}\n`;
    str += `    MAXVALUE ${s.seqmax}\n`;
    str += `    CACHE ${s.seqcache}${s.seqcycle ? '\n    CYCLE' : ''};`;
    w(str);
  }
  w('');
}

// ---- tables + columns -------------------------------------------------------
const tables = await q(`
  select c.oid, c.relname
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname='public' and c.relkind='r'
  order by c.relname`);

w('-- ============================ TABLES ===============================');
for (const t of tables) {
  const cols = await q(
    `
    select a.attname,
           format_type(a.atttypid, a.atttypmod) as coltype,
           a.attnotnull,
           a.attidentity,
           a.attgenerated,
           pg_get_expr(d.adbin, d.adrelid) as defexpr
    from pg_attribute a
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
    where a.attrelid = $1 and a.attnum > 0 and not a.attisdropped
    order by a.attnum`,
    [t.oid]
  );
  const lines = cols.map((c) => {
    let line = `    ${c.attname} ${c.coltype}`;
    if (c.attidentity === 'a') line += ' GENERATED ALWAYS AS IDENTITY';
    else if (c.attidentity === 'd') line += ' GENERATED BY DEFAULT AS IDENTITY';
    else if (c.attgenerated === 's') line += ` GENERATED ALWAYS AS (${c.defexpr}) STORED`;
    else if (c.defexpr) line += ` DEFAULT ${c.defexpr}`;
    if (c.attnotnull) line += ' NOT NULL';
    return line;
  });
  w(`CREATE TABLE public.${t.relname} (`);
  w(lines.join(',\n'));
  w(');');
  w('');
}

// ---- sequence ownership -----------------------------------------------------
const owned = await q(`
  select s.relname as seqname, t.relname as tabname, a.attname as colname
  from pg_depend d
  join pg_class s on s.oid = d.objid and s.relkind='S'
  join pg_class t on t.oid = d.refobjid
  join pg_attribute a on a.attrelid = t.oid and a.attnum = d.refobjsubid
  join pg_namespace n on n.oid = s.relnamespace
  where d.deptype='a' and n.nspname='public'
  order by s.relname`);
if (owned.length) {
  w('-- ===================== SEQUENCE OWNERSHIP ==========================');
  for (const o of owned)
    w(`ALTER SEQUENCE public.${o.seqname} OWNED BY public.${o.tabname}.${o.colname};`);
  w('');
}

// ---- constraints: PK / UNIQUE / CHECK (not FK) ------------------------------
const cons = await q(`
  select rel.relname as tabname, con.conname, con.contype,
         pg_get_constraintdef(con.oid) as def
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  join pg_namespace n on n.oid = rel.relnamespace
  where n.nspname='public' and con.contype in ('p','u','c')
  order by rel.relname, con.contype desc, con.conname`);
if (cons.length) {
  w('-- ================= PRIMARY / UNIQUE / CHECK CONSTRAINTS =============');
  for (const c of cons)
    w(`ALTER TABLE public.${c.tabname} ADD CONSTRAINT ${c.conname} ${c.def};`);
  w('');
}

// ---- foreign keys (after all PK/UNIQUE exist) -------------------------------
const fks = await q(`
  select rel.relname as tabname, con.conname, pg_get_constraintdef(con.oid) as def
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  join pg_namespace n on n.oid = rel.relnamespace
  where n.nspname='public' and con.contype='f'
  order by rel.relname, con.conname`);
if (fks.length) {
  w('-- ========================= FOREIGN KEYS ============================');
  for (const c of fks)
    w(`ALTER TABLE public.${c.tabname} ADD CONSTRAINT ${c.conname} ${c.def};`);
  w('');
}

// ---- indexes (exclude those backing constraints) ---------------------------
const idx = await q(`
  select t.relname as tabname, ic.relname as idxname, pg_get_indexdef(i.indexrelid) as def
  from pg_index i
  join pg_class ic on ic.oid = i.indexrelid
  join pg_class t on t.oid = i.indrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname='public'
    and not exists (select 1 from pg_constraint c where c.conindid = i.indexrelid)
  order by t.relname, ic.relname`);
if (idx.length) {
  w('-- ============================ INDEXES ==============================');
  for (const i of idx) w(i.def + ';');
  w('');
}

// ---- triggers ---------------------------------------------------------------
const trigs = await q(`
  select t.relname as tabname, tg.tgname, pg_get_triggerdef(tg.oid) as def
  from pg_trigger tg
  join pg_class t on t.oid = tg.tgrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname='public' and not tg.tgisinternal
  order by t.relname, tg.tgname`);
if (trigs.length) {
  w('-- ============================ TRIGGERS =============================');
  for (const tr of trigs) w(tr.def + ';');
  w('');
}

// ---- views & materialized views --------------------------------------------
const views = await q(`
  select c.relname, c.relkind, pg_get_viewdef(c.oid, true) as def
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname='public' and c.relkind in ('v','m')
  order by c.relkind, c.relname`);
if (views.length) {
  w('-- ============================ VIEWS ================================');
  for (const v of views) {
    const kw = v.relkind === 'm' ? 'MATERIALIZED VIEW' : 'VIEW';
    w(`CREATE ${kw} public.${v.relname} AS\n${v.def.trimEnd()}`);
    w('');
  }
}

w('-- ============================ END ==================================');

fs.writeFileSync('database.sql', out.join('\n'));
console.log(
  JSON.stringify(
    {
      tables: tables.length,
      enums: enums.length,
      functions: funcs.length,
      sequences: seqs.length,
      constraints: cons.length,
      foreign_keys: fks.length,
      indexes: idx.length,
      triggers: trigs.length,
      views: views.length,
    },
    null,
    2
  )
);
await client.end();
