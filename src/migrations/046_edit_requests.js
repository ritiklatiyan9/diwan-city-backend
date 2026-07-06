import pool from '../config/db.js';

/**
 * Creates the `edit_requests` table used by the edit-approval workflow
 * (EditRequest.model.js / editRequest.controller.js). Columns mirror the
 * fields written on create (requested_by, site_id, module, record_id,
 * original_data, proposed_data, proof_photo_url, status) and on review
 * (reviewed_by, reviewed_at, review_photo_url, rejection_reason, updated_at).
 */
const migrateEditRequests = async () => {
  try {
    const query = `
      CREATE TABLE IF NOT EXISTS edit_requests (
        id SERIAL PRIMARY KEY,
        requested_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
        reviewed_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
        site_id INTEGER REFERENCES sites(id) ON DELETE SET NULL,
        module VARCHAR(64) NOT NULL,
        record_id INTEGER NOT NULL,
        original_data JSONB,
        proposed_data JSONB,
        proof_photo_url TEXT,
        review_photo_url TEXT,
        status VARCHAR(20) NOT NULL DEFAULT 'pending',
        rejection_reason TEXT,
        reviewed_at TIMESTAMP WITH TIME ZONE,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
      );

      CREATE INDEX IF NOT EXISTS idx_edit_requests_status ON edit_requests(status);
      CREATE INDEX IF NOT EXISTS idx_edit_requests_requested_by ON edit_requests(requested_by);
      CREATE INDEX IF NOT EXISTS idx_edit_requests_site_id ON edit_requests(site_id);
      CREATE INDEX IF NOT EXISTS idx_edit_requests_module_record ON edit_requests(module, record_id);
    `;
    await pool.query(query);
    console.log('✓ Migration applied: edit_requests table created');
  } catch (error) {
    console.error('Error in edit_requests migration:', error);
    throw error;
  }
};

export default migrateEditRequests;
