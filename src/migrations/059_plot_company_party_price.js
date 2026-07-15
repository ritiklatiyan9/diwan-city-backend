import pool from '../config/db.js';

/**
 * Company Price vs Party Price (broker margin tracking).
 *   company_price — price the owner/company sets for the plot (given to the
 *                   broker as their cost basis, e.g. ₹20L).
 *   party_price   — price the broker actually sells to the end client for
 *                   (e.g. ₹25L). Margin = party_price − company_price is the
 *                   broker's markup, shown derived in the UI (not stored).
 *
 * These are independent of sale_price — sale_price still drives all balance/
 * received/installment math; these two are pure tracking fields.
 */
export const up = async () => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(`
      ALTER TABLE plots
      ADD COLUMN IF NOT EXISTS company_price NUMERIC(15,2) DEFAULT 0
    `);
    await client.query(`
      ALTER TABLE plots
      ADD COLUMN IF NOT EXISTS party_price NUMERIC(15,2) DEFAULT 0
    `);
    await client.query('COMMIT');
    console.log('Migration 059: Added company_price and party_price columns to plots');
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
};

export const down = async () => {
  await pool.query('ALTER TABLE plots DROP COLUMN IF EXISTS company_price');
  await pool.query('ALTER TABLE plots DROP COLUMN IF EXISTS party_price');
  console.log('Migration 059: Removed company_price and party_price columns');
};
