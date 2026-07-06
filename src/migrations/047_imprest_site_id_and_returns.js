import pool from '../config/db.js';

/**
 * Reconciles the imprest schema with the code:
 *  - adds the `site_id` column the models filter on (imprest_ledger,
 *    imprest_allocations) — see ImprestLedgerModel / ImprestAllocationModel.
 *  - creates the `imprest_returns` table used by ImprestReturnModel
 *    (columns mirror the create payload in imprest.controller.js + the
 *    review fields set in acceptReturn/rejectReturn).
 */
const migrateImprestSiteAndReturns = async () => {
  try {
    const query = `
      ALTER TABLE imprest_ledger
        ADD COLUMN IF NOT EXISTS site_id INTEGER REFERENCES sites(id) ON DELETE SET NULL;

      ALTER TABLE imprest_allocations
        ADD COLUMN IF NOT EXISTS site_id INTEGER REFERENCES sites(id) ON DELETE SET NULL;

      CREATE INDEX IF NOT EXISTS idx_imprest_ledger_site_id ON imprest_ledger(site_id);
      CREATE INDEX IF NOT EXISTS idx_imprest_allocations_site_id ON imprest_allocations(site_id);

      CREATE TABLE IF NOT EXISTS imprest_returns (
        id SERIAL PRIMARY KEY,
        sub_admin_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
        amount NUMERIC NOT NULL DEFAULT 0,
        reason TEXT,
        payment_mode VARCHAR(20) NOT NULL DEFAULT 'CASH',
        site_id INTEGER REFERENCES sites(id) ON DELETE SET NULL,
        assigned_admin_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
        status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
        reviewed_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
        reviewed_at TIMESTAMP WITH TIME ZONE,
        review_remark TEXT,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
      );

      CREATE INDEX IF NOT EXISTS idx_imprest_returns_status ON imprest_returns(status);
      CREATE INDEX IF NOT EXISTS idx_imprest_returns_sub_admin_id ON imprest_returns(sub_admin_id);
      CREATE INDEX IF NOT EXISTS idx_imprest_returns_site_id ON imprest_returns(site_id);
    `;
    await pool.query(query);
    console.log('✓ Migration applied: imprest site_id columns + imprest_returns table');
  } catch (error) {
    console.error('Error in imprest site/returns migration:', error);
    throw error;
  }
};

export default migrateImprestSiteAndReturns;
