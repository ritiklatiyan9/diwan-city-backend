import pool from '../config/db.js';
import path from 'path';
import { pathToFileURL } from 'url';

/**
 * Interest Management — standalone module.
 * Run directly: node src/migrations/060_interest_management.js
 *
 * Deliberately isolated: no triggers, no daybook/cashflow sync, no approval
 * workflow. Nothing outside these three tables reads or writes them, so the
 * module can be dropped without touching any other feature.
 *
 *   interest_parties       the person/party money is borrowed from or lent to
 *   interest_loans         one deal — principal + rate + tenure + direction
 *   interest_transactions  mid-term give/receive against a loan
 *
 * direction on a loan is from OUR side:
 *   BORROWED — the party gave us money, we owe them
 *   LENT     — we gave the party money, they owe us
 *
 * direction on a transaction is cash flow, again from OUR side:
 *   IN  — money came to us      OUT — money left us
 */
export const up = async () => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');

    await client.query(`
      CREATE TABLE IF NOT EXISTS interest_parties (
        id SERIAL PRIMARY KEY,
        site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
        name VARCHAR(200) NOT NULL,
        phone VARCHAR(20),
        address TEXT,
        note TEXT,
        created_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
      )
    `);

    await client.query(`
      CREATE INDEX IF NOT EXISTS idx_interest_parties_site_id
      ON interest_parties(site_id)
    `);

    await client.query(`
      CREATE TABLE IF NOT EXISTS interest_loans (
        id SERIAL PRIMARY KEY,
        site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
        party_id INTEGER NOT NULL REFERENCES interest_parties(id) ON DELETE CASCADE,
        title VARCHAR(200),
        direction VARCHAR(10) NOT NULL CHECK (direction IN ('BORROWED', 'LENT')),
        principal NUMERIC(15,2) NOT NULL CHECK (principal > 0),
        rate NUMERIC(8,4) NOT NULL DEFAULT 0 CHECK (rate >= 0),
        rate_basis VARCHAR(10) NOT NULL DEFAULT 'YEARLY' CHECK (rate_basis IN ('MONTHLY', 'YEARLY')),
        method VARCHAR(10) NOT NULL DEFAULT 'SIMPLE' CHECK (method IN ('SIMPLE', 'COMPOUND')),
        compounding VARCHAR(10) NOT NULL DEFAULT 'YEARLY' CHECK (compounding IN ('MONTHLY', 'QUARTERLY', 'YEARLY')),
        start_date DATE NOT NULL,
        tenure_months INTEGER NOT NULL DEFAULT 12 CHECK (tenure_months > 0),
        status VARCHAR(10) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'CLOSED')),
        note TEXT,
        created_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
      )
    `);

    await client.query(`
      CREATE INDEX IF NOT EXISTS idx_interest_loans_party_id
      ON interest_loans(party_id)
    `);

    await client.query(`
      CREATE INDEX IF NOT EXISTS idx_interest_loans_site_id
      ON interest_loans(site_id)
    `);

    await client.query(`
      CREATE TABLE IF NOT EXISTS interest_transactions (
        id SERIAL PRIMARY KEY,
        site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
        loan_id INTEGER NOT NULL REFERENCES interest_loans(id) ON DELETE CASCADE,
        date DATE NOT NULL,
        direction VARCHAR(3) NOT NULL CHECK (direction IN ('IN', 'OUT')),
        amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
        kind VARCHAR(12) NOT NULL DEFAULT 'AUTO' CHECK (kind IN ('AUTO', 'INTEREST', 'PRINCIPAL')),
        mode VARCHAR(10) NOT NULL DEFAULT 'CASH' CHECK (mode IN ('CASH', 'BANK', 'UPI', 'CHEQUE', 'OTHER')),
        reference VARCHAR(120),
        note TEXT,
        created_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
      )
    `);

    await client.query(`
      CREATE INDEX IF NOT EXISTS idx_interest_transactions_loan_id
      ON interest_transactions(loan_id, date)
    `);

    await client.query('COMMIT');
    console.log('Migration 060: interest management tables created.');
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('Migration 060 failed:', err.message);
    throw err;
  } finally {
    client.release();
  }
};

export const down = async () => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('DROP TABLE IF EXISTS interest_transactions');
    await client.query('DROP TABLE IF EXISTS interest_loans');
    await client.query('DROP TABLE IF EXISTS interest_parties');
    await client.query('COMMIT');
    console.log('Migration 060 rollback complete.');
  } catch (err) {
    await client.query('ROLLBACK');
    console.error('Migration 060 rollback failed:', err.message);
    throw err;
  } finally {
    client.release();
  }
};

const isDirectRun = process.argv[1]
  ? import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
  : false;

if (isDirectRun) {
  up()
    .then(() => process.exit(0))
    .catch(() => process.exit(1));
}
