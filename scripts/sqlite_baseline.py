"""Emit SQLite DDL for the current state of a Postgres database (public schema).

The desktop runs on SQLite. Its schema starts from this baseline, taken from a
Postgres database migrated to the version the baseline migration is named for
(priv/sqlite/migrations); every Postgres migration after that has a SQLite
counterpart beside it.

    python3 scripts/sqlite_baseline.py <postgres-db> > priv/sqlite/baseline.sql
"""
import json, re, subprocess, sys

DB = sys.argv[1]


def q(sql):
    out = subprocess.run(["psql", "-X", "-At", "-F", "\x1f", "-d", DB, "-c", sql],
                         capture_output=True, text=True, check=True).stdout
    return [line.split("\x1f") for line in out.splitlines() if line]


TYPES = {
    "uuid": "TEXT", "text": "TEXT", "character varying": "TEXT", "citext": "TEXT COLLATE NOCASE",
    "bigint": "INTEGER", "integer": "INTEGER", "smallint": "INTEGER", "boolean": "INTEGER",
    "timestamp without time zone": "TEXT", "timestamp with time zone": "TEXT", "date": "TEXT",
    "time without time zone": "TEXT", "jsonb": "TEXT", "json": "TEXT", "bytea": "BLOB",
    "double precision": "REAL", "real": "REAL", "numeric": "NUMERIC", "ARRAY": "TEXT",
    "USER-DEFINED": "BLOB",  # pgvector
    "interval": "TEXT", "inet": "TEXT",
}


def default(expr, sqltype, dt=None):
    if expr is None or expr == "":
        return None
    if "nextval(" in expr:
        return "AUTOINCREMENT"
    e = re.sub(r"::[a-z_ \[\]]+(\(\d+\))?", "", expr)
    if e in ("true", "false"):
        return "1" if e == "true" else "0"
    if e.startswith("ARRAY[]") or (e == "'{}'" and dt == "ARRAY"):
        return "'[]'"
    if e in ("now()", "CURRENT_TIMESTAMP", "timezone('UTC', now())", "(now() AT TIME ZONE 'utc')"):
        return "CURRENT_TIMESTAMP"
    if re.fullmatch(r"-?\d+(\.\d+)?", e) or re.fullmatch(r"'.*'", e, re.S):
        return e
    if e.startswith("gen_random_uuid") or e.startswith("uuid_generate"):
        return None
    return None


def main():
    # schema_migrations is Ecto's own; the migrator creates it.
    tables = [r[0] for r in q("select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE' and table_name <> 'schema_migrations' order by 1")]
    cols = {}
    for t, c, dt, udt, nullable, dflt in q("select table_name, column_name, data_type, udt_name, is_nullable, coalesce(column_default,'') from information_schema.columns where table_schema='public' order by table_name, ordinal_position"):
        # citext and vector are both USER-DEFINED; the udt name tells them apart.
        if dt == "USER-DEFINED":
            dt = "citext" if udt == "citext" else "USER-DEFINED"
        cols.setdefault(t, []).append((c, dt, nullable == "YES", dflt))
    pks = {}
    for t, c in q("select tc.table_name, kcu.column_name from information_schema.table_constraints tc join information_schema.key_column_usage kcu on tc.constraint_name=kcu.constraint_name and tc.table_schema=kcu.table_schema where tc.table_schema='public' and tc.constraint_type='PRIMARY KEY' order by tc.table_name, kcu.ordinal_position"):
        pks.setdefault(t, []).append(c)
    fks = {}
    for t, c, ft, fc, delete in q("""select cl.relname, a.attname, fcl.relname, fa.attname, con.confdeltype
        from pg_constraint con join pg_class cl on cl.oid=con.conrelid join pg_class fcl on fcl.oid=con.confrelid
        join pg_namespace n on n.oid=cl.relnamespace
        join lateral unnest(con.conkey) with ordinality k(attnum, i) on true
        join lateral unnest(con.confkey) with ordinality fk(attnum, j) on fk.j = k.i
        join pg_attribute a on a.attrelid=cl.oid and a.attnum=k.attnum
        join pg_attribute fa on fa.attrelid=fcl.oid and fa.attnum=fk.attnum
        where con.contype='f' and n.nspname='public'"""):
        on_delete = {"c": " ON DELETE CASCADE", "n": " ON DELETE SET NULL", "r": " ON DELETE RESTRICT"}.get(delete, "")
        fks.setdefault(t, []).append(f'FOREIGN KEY ("{c}") REFERENCES "{ft}" ("{fc}"){on_delete}')

    out, notes = [], []
    for t in tables:
        lines = []
        pk = pks.get(t, [])
        for c, dt, nullable, dflt in cols[t]:
            sqltype = TYPES.get(dt)
            if sqltype is None:
                notes.append(f"{t}.{c}: unmapped type {dt}")
                sqltype = "TEXT"
            d = default(dflt, sqltype, dt)
            if d == "AUTOINCREMENT" and pk == [c]:
                lines.append(f'"{c}" INTEGER PRIMARY KEY AUTOINCREMENT')
                pk = []
                continue
            col = f'"{c}" {sqltype}'
            # PaperTrail's strict mode (Postgres) fills these; off on SQLite.
            if not nullable and c not in ("first_version_id", "current_version_id"):
                col += " NOT NULL"
            if d and d != "AUTOINCREMENT":
                col += f" DEFAULT {d}" if not d.startswith("CURRENT") else f" DEFAULT {d}"
            elif dflt and d is None and "nextval" not in dflt and not dflt.startswith("gen_random") and not dflt.startswith("uuid_gen"):
                notes.append(f"{t}.{c}: dropped default {dflt}")
            lines.append(col)
        if pk:
            lines.append("PRIMARY KEY (" + ", ".join(f'"{c}"' for c in pk) + ")")
        lines += fks.get(t, [])
        out.append(f'CREATE TABLE "{t}" (\n  ' + ",\n  ".join(lines) + "\n);")

    for name, idef in q("select indexname, indexdef from pg_indexes where schemaname='public' and tablename <> 'schema_migrations' and indexname not in (select constraint_name from information_schema.table_constraints where constraint_type in ('PRIMARY KEY')) order by tablename, indexname"):
        s = idef.replace("public.", "")
        if " USING hnsw" in s or " USING ivfflat" in s or " USING gin" in s or " USING gist" in s:
            notes.append(f"index {name}: skipped ({s.split('USING')[1].split()[0]})")
            continue
        s = re.sub(r" USING btree", "", s)
        s = re.sub(r"::[a-z_ ]+(\[\])?", "", s)
        s = re.sub(r"= ANY \(ARRAY\[([^\]]*)\]\)", r"IN (\1)", s)
        s = re.sub(r"<> ALL \(ARRAY\[([^\]]*)\]\)", r"NOT IN (\1)", s)
        if "NULLS NOT DISTINCT" in s:
            # SQLite's NULLs are always distinct in a unique index; coalescing
            # makes them collide, which is what NULLS NOT DISTINCT asked for.
            s = s.replace(" NULLS NOT DISTINCT", "")
            m = re.search(r"\(([^()]*)\)", s)
            cols = ", ".join(f"coalesce({c.strip()}, '')" for c in m.group(1).split(","))
            s = s[: m.start()] + "(" + cols + ")" + s[m.end():]
        s = s.replace("CREATE INDEX", "CREATE INDEX IF NOT EXISTS").replace("CREATE UNIQUE INDEX", "CREATE UNIQUE INDEX IF NOT EXISTS")
        out.append(s + ";")

    for note in notes:
        print(note, file=sys.stderr)
    sys.stdout.write("\n\n".join(out) + "\n")


main()
