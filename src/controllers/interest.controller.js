import asyncHandler from '../utils/asyncHandler.js';
import pool from '../config/db.js';

/**
 * Interest Management — self-contained CRUD over interest_parties /
 * interest_loans / interest_transactions. Touches no other module's tables.
 *
 * All interest math lives in the frontend (Frontend/src/utils/interest.js) so
 * there is exactly one implementation: the API returns raw rows plus payment
 * sums, the UI derives accrual from them.
 */

const asInt = (v) => parseInt(v, 10);
const asNum = (v) => (v === '' || v === null || v === undefined ? NaN : Number(v));

const getSiteId = (req) => {
  const siteId = asInt(req.query.site_id ?? req.body.site_id);
  return Number.isInteger(siteId) && siteId > 0 ? siteId : null;
};

const DIRECTIONS = ['BORROWED', 'LENT'];
const RATE_BASES = ['MONTHLY', 'YEARLY'];
const METHODS = ['SIMPLE', 'COMPOUND'];
const COMPOUNDINGS = ['MONTHLY', 'QUARTERLY', 'YEARLY'];
const TXN_DIRECTIONS = ['IN', 'OUT'];
const TXN_KINDS = ['AUTO', 'INTEREST', 'PRINCIPAL'];
const MODES = ['CASH', 'BANK', 'UPI', 'CHEQUE', 'OTHER'];

const oneOf = (value, allowed, fallback) => {
  const v = String(value ?? '').toUpperCase();
  return allowed.includes(v) ? v : fallback;
};

// Loan rows always carry their payment sums so the UI can run the accrual
// walk without a second round-trip per loan.
//
// start_date is TO_CHAR'd rather than selected raw: pg parses a DATE to local
// midnight, and res.json() then serialises that to UTC — which rewinds every
// date by a day for anyone east of Greenwich. A plain 'YYYY-MM-DD' string
// survives the round trip intact. Same reason on interest_transactions.date.
const LOAN_SELECT = `
  l.id, l.site_id, l.party_id, l.title, l.direction, l.principal, l.rate,
  l.rate_basis, l.method, l.compounding, l.tenure_months, l.status, l.note,
  l.created_by, l.created_at, l.updated_at,
  TO_CHAR(l.start_date, 'YYYY-MM-DD') AS start_date,
  COALESCE(t.txn_count, 0)::int AS txn_count,
  COALESCE(t.total_in,  0)      AS total_in,
  COALESCE(t.total_out, 0)      AS total_out
  FROM interest_loans l
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*)::int AS txn_count,
      COALESCE(SUM(amount) FILTER (WHERE direction = 'IN'),  0) AS total_in,
      COALESCE(SUM(amount) FILTER (WHERE direction = 'OUT'), 0) AS total_out
    FROM interest_transactions
    WHERE loan_id = l.id
  ) t ON TRUE
`;

// ── Parties ──────────────────────────────────────────────────────────

/**
 * All parties for a site, each with its loans nested, plus every transaction
 * for the site in one flat array.
 *
 * The transactions ride along because outstanding balance is a reducing-balance
 * walk over them — without them the list could only show the untouched
 * projection and would disagree with the detail page.
 */
export const listParties = asyncHandler(async (req, res) => {
  const siteId = getSiteId(req);
  if (!siteId) return res.status(400).json({ message: 'site_id is required' });

  // ponytail: three flat fetches grouped in JS. Fine at site scale; if a site
  // ever crosses a few thousand transactions, move the accrual walk server-side
  // and return per-party totals instead.
  const [parties, loans, transactions] = await Promise.all([
    pool.query(
      `SELECT * FROM interest_parties WHERE site_id = $1 ORDER BY LOWER(name) ASC`,
      [siteId]
    ),
    pool.query(
      `SELECT ${LOAN_SELECT} WHERE l.site_id = $1 ORDER BY l.start_date DESC, l.id DESC`,
      [siteId]
    ),
    pool.query(
      `SELECT id, loan_id, direction, amount, kind,
              TO_CHAR(date, 'YYYY-MM-DD') AS date
       FROM interest_transactions
       WHERE site_id = $1
       ORDER BY date ASC, id ASC`,
      [siteId]
    ),
  ]);

  const byParty = new Map();
  for (const loan of loans.rows) {
    if (!byParty.has(loan.party_id)) byParty.set(loan.party_id, []);
    byParty.get(loan.party_id).push(loan);
  }

  res.json({
    parties: parties.rows.map((p) => ({ ...p, loans: byParty.get(p.id) || [] })),
    transactions: transactions.rows,
  });
});

/** One party with all its loans and every transaction under them. */
export const getParty = asyncHandler(async (req, res) => {
  const id = asInt(req.params.id);
  const siteId = getSiteId(req);
  if (!Number.isInteger(id)) return res.status(400).json({ message: 'Invalid party id' });
  if (!siteId) return res.status(400).json({ message: 'site_id is required' });

  const party = await pool.query(
    `SELECT * FROM interest_parties WHERE id = $1 AND site_id = $2`,
    [id, siteId]
  );
  if (!party.rows[0]) return res.status(404).json({ message: 'Party not found' });

  const [loans, transactions] = await Promise.all([
    pool.query(
      `SELECT ${LOAN_SELECT} WHERE l.party_id = $1 ORDER BY l.start_date DESC, l.id DESC`,
      [id]
    ),
    pool.query(
      `SELECT t.id, t.site_id, t.loan_id, t.direction, t.amount, t.kind, t.mode,
              t.reference, t.note, t.created_at,
              TO_CHAR(t.date, 'YYYY-MM-DD') AS date,
              u.name AS created_by_name
       FROM interest_transactions t
       LEFT JOIN users u ON u.id = t.created_by
       WHERE t.loan_id IN (SELECT id FROM interest_loans WHERE party_id = $1)
       ORDER BY t.date ASC, t.id ASC`,
      [id]
    ),
  ]);

  res.json({ party: party.rows[0], loans: loans.rows, transactions: transactions.rows });
});

export const createParty = asyncHandler(async (req, res) => {
  const siteId = getSiteId(req);
  const name = (req.body.name || '').trim();
  if (!siteId) return res.status(400).json({ message: 'site_id is required' });
  if (!name) return res.status(400).json({ message: 'Party name is required' });

  const result = await pool.query(
    `INSERT INTO interest_parties (site_id, name, phone, address, note, created_by)
     VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
    [
      siteId,
      name,
      (req.body.phone || '').trim() || null,
      (req.body.address || '').trim() || null,
      (req.body.note || '').trim() || null,
      req.user.id,
    ]
  );
  res.status(201).json({ party: result.rows[0] });
});

export const updateParty = asyncHandler(async (req, res) => {
  const id = asInt(req.params.id);
  const siteId = getSiteId(req);
  if (!Number.isInteger(id)) return res.status(400).json({ message: 'Invalid party id' });
  if (!siteId) return res.status(400).json({ message: 'site_id is required' });

  const name = (req.body.name || '').trim();
  if (!name) return res.status(400).json({ message: 'Party name is required' });

  const result = await pool.query(
    `UPDATE interest_parties
     SET name = $1, phone = $2, address = $3, note = $4, updated_at = CURRENT_TIMESTAMP
     WHERE id = $5 AND site_id = $6 RETURNING *`,
    [
      name,
      (req.body.phone || '').trim() || null,
      (req.body.address || '').trim() || null,
      (req.body.note || '').trim() || null,
      id,
      siteId,
    ]
  );
  if (!result.rows[0]) return res.status(404).json({ message: 'Party not found' });
  res.json({ party: result.rows[0] });
});

/** Deleting a party cascades to its loans and their transactions. */
export const deleteParty = asyncHandler(async (req, res) => {
  const id = asInt(req.params.id);
  const siteId = getSiteId(req);
  if (!Number.isInteger(id)) return res.status(400).json({ message: 'Invalid party id' });
  if (!siteId) return res.status(400).json({ message: 'site_id is required' });

  const result = await pool.query(
    `DELETE FROM interest_parties WHERE id = $1 AND site_id = $2 RETURNING id`,
    [id, siteId]
  );
  if (!result.rows[0]) return res.status(404).json({ message: 'Party not found' });
  res.json({ message: 'Party deleted' });
});

// ── Loans ────────────────────────────────────────────────────────────

const readLoanBody = (body) => {
  const principal = asNum(body.principal);
  const rate = asNum(body.rate ?? 0);
  const tenure = asInt(body.tenure_months);
  const startDate = (body.start_date || '').trim();

  if (!Number.isFinite(principal) || principal <= 0) return { error: 'Principal must be greater than 0' };
  if (!Number.isFinite(rate) || rate < 0) return { error: 'Interest rate must be 0 or more' };
  if (!Number.isInteger(tenure) || tenure <= 0) return { error: 'Tenure (months) must be at least 1' };
  if (!startDate) return { error: 'Start date is required' };

  return {
    values: {
      title: (body.title || '').trim() || null,
      direction: oneOf(body.direction, DIRECTIONS, 'BORROWED'),
      principal,
      rate,
      rate_basis: oneOf(body.rate_basis, RATE_BASES, 'YEARLY'),
      method: oneOf(body.method, METHODS, 'SIMPLE'),
      compounding: oneOf(body.compounding, COMPOUNDINGS, 'YEARLY'),
      start_date: startDate,
      tenure_months: tenure,
      status: oneOf(body.status, ['ACTIVE', 'CLOSED'], 'ACTIVE'),
      note: (body.note || '').trim() || null,
    },
  };
};

export const createLoan = asyncHandler(async (req, res) => {
  const siteId = getSiteId(req);
  const partyId = asInt(req.body.party_id);
  if (!siteId) return res.status(400).json({ message: 'site_id is required' });
  if (!Number.isInteger(partyId)) return res.status(400).json({ message: 'party_id is required' });

  const { error, values } = readLoanBody(req.body);
  if (error) return res.status(400).json({ message: error });

  const party = await pool.query(
    `SELECT id FROM interest_parties WHERE id = $1 AND site_id = $2`,
    [partyId, siteId]
  );
  if (!party.rows[0]) return res.status(404).json({ message: 'Party not found' });

  const result = await pool.query(
    `INSERT INTO interest_loans
       (site_id, party_id, title, direction, principal, rate, rate_basis, method,
        compounding, start_date, tenure_months, status, note, created_by)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
     RETURNING *`,
    [
      siteId, partyId, values.title, values.direction, values.principal, values.rate,
      values.rate_basis, values.method, values.compounding, values.start_date,
      values.tenure_months, values.status, values.note, req.user.id,
    ]
  );
  res.status(201).json({ loan: result.rows[0] });
});

export const updateLoan = asyncHandler(async (req, res) => {
  const id = asInt(req.params.id);
  const siteId = getSiteId(req);
  if (!Number.isInteger(id)) return res.status(400).json({ message: 'Invalid loan id' });
  if (!siteId) return res.status(400).json({ message: 'site_id is required' });

  const { error, values } = readLoanBody(req.body);
  if (error) return res.status(400).json({ message: error });

  const result = await pool.query(
    `UPDATE interest_loans SET
       title = $1, direction = $2, principal = $3, rate = $4, rate_basis = $5,
       method = $6, compounding = $7, start_date = $8, tenure_months = $9,
       status = $10, note = $11, updated_at = CURRENT_TIMESTAMP
     WHERE id = $12 AND site_id = $13 RETURNING *`,
    [
      values.title, values.direction, values.principal, values.rate, values.rate_basis,
      values.method, values.compounding, values.start_date, values.tenure_months,
      values.status, values.note, id, siteId,
    ]
  );
  if (!result.rows[0]) return res.status(404).json({ message: 'Loan not found' });
  res.json({ loan: result.rows[0] });
});

export const deleteLoan = asyncHandler(async (req, res) => {
  const id = asInt(req.params.id);
  const siteId = getSiteId(req);
  if (!Number.isInteger(id)) return res.status(400).json({ message: 'Invalid loan id' });
  if (!siteId) return res.status(400).json({ message: 'site_id is required' });

  const result = await pool.query(
    `DELETE FROM interest_loans WHERE id = $1 AND site_id = $2 RETURNING id`,
    [id, siteId]
  );
  if (!result.rows[0]) return res.status(404).json({ message: 'Loan not found' });
  res.json({ message: 'Loan deleted' });
});

// ── Transactions ─────────────────────────────────────────────────────

const readTxnBody = (body) => {
  const amount = asNum(body.amount);
  const date = (body.date || '').trim();
  if (!Number.isFinite(amount) || amount <= 0) return { error: 'Amount must be greater than 0' };
  if (!date) return { error: 'Date is required' };

  return {
    values: {
      date,
      direction: oneOf(body.direction, TXN_DIRECTIONS, 'OUT'),
      amount,
      kind: oneOf(body.kind, TXN_KINDS, 'AUTO'),
      mode: oneOf(body.mode, MODES, 'CASH'),
      reference: (body.reference || '').trim() || null,
      note: (body.note || '').trim() || null,
    },
  };
};

export const createTransaction = asyncHandler(async (req, res) => {
  const siteId = getSiteId(req);
  const loanId = asInt(req.body.loan_id);
  if (!siteId) return res.status(400).json({ message: 'site_id is required' });
  if (!Number.isInteger(loanId)) return res.status(400).json({ message: 'loan_id is required' });

  const { error, values } = readTxnBody(req.body);
  if (error) return res.status(400).json({ message: error });

  const loan = await pool.query(
    `SELECT id FROM interest_loans WHERE id = $1 AND site_id = $2`,
    [loanId, siteId]
  );
  if (!loan.rows[0]) return res.status(404).json({ message: 'Loan not found' });

  const result = await pool.query(
    `INSERT INTO interest_transactions
       (site_id, loan_id, date, direction, amount, kind, mode, reference, note, created_by)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING *`,
    [
      siteId, loanId, values.date, values.direction, values.amount,
      values.kind, values.mode, values.reference, values.note, req.user.id,
    ]
  );
  res.status(201).json({ transaction: result.rows[0] });
});

export const updateTransaction = asyncHandler(async (req, res) => {
  const id = asInt(req.params.id);
  const siteId = getSiteId(req);
  if (!Number.isInteger(id)) return res.status(400).json({ message: 'Invalid transaction id' });
  if (!siteId) return res.status(400).json({ message: 'site_id is required' });

  const { error, values } = readTxnBody(req.body);
  if (error) return res.status(400).json({ message: error });

  const result = await pool.query(
    `UPDATE interest_transactions SET
       date = $1, direction = $2, amount = $3, kind = $4, mode = $5,
       reference = $6, note = $7
     WHERE id = $8 AND site_id = $9 RETURNING *`,
    [
      values.date, values.direction, values.amount, values.kind,
      values.mode, values.reference, values.note, id, siteId,
    ]
  );
  if (!result.rows[0]) return res.status(404).json({ message: 'Transaction not found' });
  res.json({ transaction: result.rows[0] });
});

export const deleteTransaction = asyncHandler(async (req, res) => {
  const id = asInt(req.params.id);
  const siteId = getSiteId(req);
  if (!Number.isInteger(id)) return res.status(400).json({ message: 'Invalid transaction id' });
  if (!siteId) return res.status(400).json({ message: 'site_id is required' });

  const result = await pool.query(
    `DELETE FROM interest_transactions WHERE id = $1 AND site_id = $2 RETURNING id`,
    [id, siteId]
  );
  if (!result.rows[0]) return res.status(404).json({ message: 'Transaction not found' });
  res.json({ message: 'Transaction deleted' });
});
