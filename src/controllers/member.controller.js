import asyncHandler from '../utils/asyncHandler.js';
import { memberModel } from '../models/Member.model.js';
import { uploadSingle } from '../utils/upload.js';
import pool from '../config/db.js';

// ── MEMBER FIELDS (whitelist) ──
const MEMBER_FIELDS = [
  'member_type', 'full_name', 'father_name', 'gender', 'date_of_birth', 'blood_group',
  'phone', 'alt_phone', 'email', 'whatsapp',
  'address', 'city', 'state', 'pincode',
  'aadhar_no', 'pan_no', 'voter_id',
  'bank_name', 'account_no', 'ifsc_code', 'branch',
  'occupation', 'company_name', 'reference', 'notes', 'status',
  // New personal fields
  'mother_name', 'spouse_name', 'nationality', 'religion', 'caste',
  'marital_status', 'anniversary_date', 'qualification',
  // Additional identity
  'passport_no', 'driving_license_no', 'gst_no', 'tin_no',
  // Emergency contact
  'emergency_contact_name', 'emergency_contact_phone', 'emergency_contact_relation',
  // Nominee
  'nominee_name', 'nominee_relation', 'nominee_phone',
  // Employee-specific
  'employee_id', 'designation', 'department', 'date_of_joining', 'salary', 'employment_type',
  // Farmer-specific
  'land_area', 'crop_type', 'farm_location', 'irrigation_type', 'farming_experience',
  // Broker-specific
  'license_number', 'commission_rate', 'operating_areas',
  // Vendor-specific
  'business_name', 'service_type', 'payment_terms',
  // Team (for broker/member/employee/partner)
  'team',
];

const sanitize = (body) => {
  const data = {};
  MEMBER_FIELDS.forEach(f => {
    if (body[f] !== undefined) {
      let val = body[f];
      if (typeof val === 'string') val = val.trim();
      // Uppercase certain fields
      if (['full_name', 'father_name', 'member_type', 'gender', 'blood_group',
        'city', 'state', 'aadhar_no', 'pan_no', 'voter_id', 'ifsc_code',
        'occupation', 'company_name', 'reference', 'status',
        'mother_name', 'spouse_name', 'nationality', 'religion', 'caste',
        'marital_status', 'qualification', 'passport_no', 'driving_license_no',
        'gst_no', 'tin_no', 'emergency_contact_name', 'emergency_contact_relation',
        'nominee_name', 'nominee_relation', 'designation', 'department',
        'employment_type', 'team'].includes(f) && val) {
        val = val.toUpperCase();
      }
      data[f] = val || null;
    }
  });
  return data;
};

// Document field names that map to file upload keys
const DOC_FIELDS = [
  'photo', 'aadhar_front_url', 'aadhar_back_url', 'pan_card_url',
  'voter_id_url', 'passport_url', 'driving_license_url', 'cheque_url', 'other_kyc_url',
  'resume_url', 'marksheet_10th_url', 'marksheet_12th_url',
  'degree_certificate_url', 'experience_certificate_url',
  'offer_letter_url', 'other_certificate_url',
];

/** Upload all document files from req.files in PARALLEL and return a map of field→url */
const uploadDocuments = async (files) => {
  const urls = {};
  if (!files) return urls;

  const tasks = [];
  for (const fieldName of DOC_FIELDS) {
    const fileArr = files[fieldName];
    if (fileArr && fileArr.length > 0) {
      tasks.push(
        uploadSingle(fileArr[0], 'cloudinary')
          .then((url) => { urls[fieldName] = url; })
          .catch((err) => { console.error(`Upload failed for ${fieldName}:`, err?.message || err); })
      );
    }
  }
  if (tasks.length > 0) await Promise.all(tasks);
  return urls;
};

/** POST /members — Create a new member */
export const createMember = asyncHandler(async (req, res) => {
  const { site_id } = req.body;
  if (!site_id) return res.status(400).json({ message: 'Site is required' });

  const data = sanitize(req.body);
  if (!data.full_name) return res.status(400).json({ message: 'Full name is required' });

  data.site_id = parseInt(site_id);
  data.created_by = req.user.id;

  // Run phone uniqueness check + document uploads in PARALLEL
  const phoneCheckPromise = data.phone
    ? pool.query(
        `SELECT id, full_name FROM members WHERE site_id = $1 AND phone = $2 LIMIT 1`,
        [data.site_id, data.phone]
      )
    : Promise.resolve({ rows: [] });

  const [phoneCheck, docUrls] = await Promise.all([
    phoneCheckPromise,
    uploadDocuments(req.files),
  ]);

  if (phoneCheck.rows.length > 0) {
    return res.status(409).json({ message: `Phone number ${data.phone} is already registered to ${phoneCheck.rows[0].full_name}` });
  }

  Object.assign(data, docUrls);

  const member = await memberModel.create(data, pool);
  res.status(201).json({ member });
});

/** GET /members?site_id=X&type=CLIENT */
export const listMembers = asyncHandler(async (req, res) => {
  const { site_id, type } = req.query;
  if (!site_id) return res.status(400).json({ message: 'site_id is required' });

  const [members, summary] = await Promise.all([
    memberModel.findBySiteIdList(parseInt(site_id), pool, type || null),
    memberModel.getSummary(parseInt(site_id), pool),
  ]);
  res.json({ members, summary });
});

/** GET /members/search?site_id=X&q=... */
export const searchMembers = asyncHandler(async (req, res) => {
  const { site_id, q } = req.query;
  if (!site_id) return res.status(400).json({ message: 'site_id is required' });
  const members = await memberModel.search(parseInt(site_id), q || '', pool);
  res.json({ members });
});

/** GET /members/autocomplete?site_id=X */
export const getMemberAutocomplete = asyncHandler(async (req, res) => {
  const { site_id } = req.query;
  if (!site_id) return res.status(400).json({ message: 'site_id is required' });
  const data = await memberModel.getAutocomplete(parseInt(site_id), pool);
  res.json(data);
});

/** GET /members/:id */
export const getMember = asyncHandler(async (req, res) => {
  const member = await memberModel.findById(parseInt(req.params.id), pool);
  if (!member) return res.status(404).json({ message: 'Member not found' });
  res.json({ member });
});

/** PUT /members/:id */
export const updateMember = asyncHandler(async (req, res) => {
  const memberId = parseInt(req.params.id);

  // Run all 3 in PARALLEL: existence/site lookup, phone uniqueness, document uploads.
  // The phone check runs unconditionally (with `$2 IS NULL` guard) so we don't add a serial step.
  const data = sanitize(req.body);

  const existingPromise = pool.query(
    `SELECT id, site_id FROM members WHERE id = $1`,
    [memberId]
  );
  const phoneCheckPromise = data.phone
    ? pool.query(
        `SELECT m.id, m.full_name
           FROM members m
           JOIN members me ON me.id = $2
          WHERE m.site_id = me.site_id AND m.phone = $1 AND m.id != $2
          LIMIT 1`,
        [data.phone, memberId]
      )
    : Promise.resolve({ rows: [] });
  const docUploadPromise = uploadDocuments(req.files);

  const [existingRes, phoneCheck, docUrls] = await Promise.all([
    existingPromise,
    phoneCheckPromise,
    docUploadPromise,
  ]);

  const existing = existingRes.rows[0];
  if (!existing) return res.status(404).json({ message: 'Member not found' });

  if (phoneCheck.rows.length > 0) {
    return res.status(409).json({ message: `Phone number ${data.phone} is already registered to ${phoneCheck.rows[0].full_name}` });
  }

  Object.assign(data, docUrls);

  // Handle removing documents
  for (const field of DOC_FIELDS) {
    if (req.body[`remove_${field}`] === 'true') {
      data[field] = null;
    }
  }

  if (Object.keys(data).length === 0) return res.status(400).json({ message: 'Nothing to update' });

  const updated = await memberModel.update(memberId, data, pool);
  res.json({ member: updated });
});

/** DELETE /members/:id */
export const deleteMember = asyncHandler(async (req, res) => {
  const existing = await memberModel.findById(parseInt(req.params.id), pool);
  if (!existing) return res.status(404).json({ message: 'Member not found' });
  await memberModel.delete(parseInt(req.params.id), pool);
  res.json({ message: 'Member deleted' });
});

/** GET /members/:id/transactions?site_id=X */
export const getMemberTransactions = asyncHandler(async (req, res) => {
  const memberId = parseInt(req.params.id);
  const { site_id } = req.query;
  if (!site_id) return res.status(400).json({ message: 'site_id is required' });

  const member = await memberModel.findById(memberId, pool);
  if (!member) return res.status(404).json({ message: 'Member not found' });

  const siteId = parseInt(site_id);
  const memberName = member.full_name;

  // Fetch expenses linked by assigned_user_id OR by name match
  const expensesQuery = `
    SELECT e.id, e.date, e.from_entity, e.to_entity, e.payment_mode,
           e.debit, e.credit, e.remark, e.category, e.account_no, e.branch,
           e.voucher_url, e.status, e.created_at,
           'EXPENSE' as source
    FROM expenses e
    WHERE e.site_id = $1
      AND (e.assigned_user_id = $2 OR UPPER(e.to_entity) = UPPER($3) OR UPPER(e.from_entity) = UPPER($3))
    ORDER BY e.date DESC, e.id DESC
  `;

  // Fetch daybook entries linked by assigned_user_id OR by name match.
  // The column is day_book.remarks (plural) — selecting d.remark threw
  // "column d.remark does not exist", which 500'd this whole endpoint and left
  // the member's transactions permanently empty in the UI. Aliased back to
  // `remark` because that is the key ClientDetail renders.
  // Rows mirrored in from other modules are excluded by the same 6-FK predicate
  // the approvals feed uses, so a vendor/farmer payment isn't counted twice.
  const daybookQuery = `
    SELECT d.id, d.date, d.from_entity, d.to_entity, d.payment_mode,
           d.debit, d.credit, d.remarks as remark, d.category, d.account_no, d.branch,
           d.entry_type, d.status, d.created_at,
           'DAYBOOK' as source
    FROM day_book d
    WHERE d.site_id = $1
      AND d.entry_type != 'EXPENSE'
      AND (d.assigned_user_id = $2 OR UPPER(d.to_entity) = UPPER($3) OR UPPER(d.from_entity) = UPPER($3))
      AND d.plot_payment_id IS NULL
    ORDER BY d.date DESC, d.id DESC
  `;
  // NOTE the dedup above is deliberately ONLY plot_payment_id. The full 6-FK
  // predicate (as used by the approvals feed and by LEDGER_SQL) is correct only
  // where every mirrored source is also unioned in as a sibling branch. This
  // endpoint unions just expenses + day_book + plot_payments, so excluding
  // farmer/commission/vendor/firm/cashflow mirrors would delete the member's
  // only copy of that money — a farmer's day_book payment would vanish from the
  // page while the Financial Overview tile above it still showed the amount.

  // Plot payments this member booked, bought, or received — linked by name,
  // since plot_payments stores free text rather than a members FK. Payment mode
  // is reported (payment_type) but never filters: a CASH or UPI payment must
  // show up here exactly like a BANK one.
  // Takes only ($1 site_id, $2 name) — there is no member FK to bind, and an
  // unreferenced placeholder makes Postgres reject the whole statement with
  // "could not determine data type of parameter".
  const plotPaymentsQuery = `
    SELECT pp.id, pp.date,
           pp.payment_from as from_entity,
           COALESCE(pp.buyer_name, pl.buyer_name) as to_entity,
           pp.payment_type as payment_mode,
           0 as debit, COALESCE(pp.amount, 0) as credit,
           pp.narration as remark, NULL as category,
           pp.bank_details as account_no, NULL as branch,
           pp.voucher_url, pp.status, pp.created_at,
           pl.plot_no,
           CASE WHEN UPPER(pp.booked_by) = UPPER($2) THEN 'BOOKED BY'
                WHEN UPPER(pp.buyer_name) = UPPER($2) THEN 'BUYER'
                ELSE 'RECEIVED BY' END as entry_type,
           'PLOT PAYMENT' as source
    FROM plot_payments pp
    LEFT JOIN plots pl ON pl.id = pp.plot_id
    WHERE pp.site_id = $1
      AND (UPPER(pp.booked_by) = UPPER($2) OR UPPER(pp.buyer_name) = UPPER($2) OR UPPER(pp.received_by) = UPPER($2))
      AND (pp.cheque_status IS NULL OR pp.cheque_status NOT IN ('BOUNCED','RETURNED'))
      AND COALESCE(pp.status, '') <> 'rejected'
    ORDER BY pp.date DESC, pp.id DESC
  `;

  const [expResult, dbResult, ppResult] = await Promise.all([
    pool.query(expensesQuery, [siteId, memberId, memberName]),
    pool.query(daybookQuery, [siteId, memberId, memberName]),
    pool.query(plotPaymentsQuery, [siteId, memberName]),
  ]);

  const expenses = expResult.rows;
  const daybook = dbResult.rows;
  const plotPayments = ppResult.rows;

  // Combine and sort by date DESC
  const all = [...expenses, ...daybook, ...plotPayments].sort((a, b) => {
    const da = new Date(a.date), db = new Date(b.date);
    return db - da || b.id - a.id;
  });

  // Summary
  const totalDebit = all.reduce((s, t) => s + (parseFloat(t.debit) || 0), 0);
  const totalCredit = all.reduce((s, t) => s + (parseFloat(t.credit) || 0), 0);

  res.json({
    transactions: all,
    summary: {
      total_debit: totalDebit,
      total_credit: totalCredit,
      net: totalCredit - totalDebit,
      count: all.length,
    },
  });
});

/** GET /members/:id/financial-info?site_id=X */
export const getMemberFinancialInfo = asyncHandler(async (req, res) => {
  const memberId = parseInt(req.params.id);
  const { site_id } = req.query;
  if (!site_id) return res.status(400).json({ message: 'site_id is required' });

  const member = await memberModel.findById(memberId, pool);
  if (!member) return res.status(404).json({ message: 'Member not found' });

  const siteId = parseInt(site_id);
  const memberName = member.full_name;

  // Run all queries in parallel using name matching + FK where available
  const [expRes, commRes, plotPayRes, farmerPayRes, firmRes] = await Promise.all([
    // 1. Expenses — by assigned_user_id or name match
    pool.query(
      `SELECT e.id, e.date, e.from_entity, e.to_entity, e.payment_mode,
              e.debit, e.credit, e.remark, e.category, e.status, e.voucher_url
       FROM expenses e
       WHERE e.site_id = $1
         AND (e.assigned_user_id = $2 OR UPPER(e.to_entity) = UPPER($3) OR UPPER(e.from_entity) = UPPER($3))
       ORDER BY e.date DESC, e.id DESC`,
      [siteId, memberId, memberName]
    ),
    // 2. Plot Commissions — by particular (person name)
    pool.query(
      `SELECT pc.id, pc.date, pc.particular, pc.amount, pc.plot_no, pc.plot_size,
              pc.by_note, pc.remarks, pc.status, pc.voucher_url
       FROM plot_commissions pc
       WHERE pc.site_id = $1 AND UPPER(pc.particular) = UPPER($2)
       ORDER BY pc.date DESC, pc.id DESC`,
      [siteId, memberName]
    ),
    // 3. Plot Payments — by payment_from (buyer name) or buyer_name on plot
    pool.query(
      `SELECT pp.id, pp.date, pp.amount, pp.payment_type, pp.bank_details,
              pp.narration, pp.payment_from, pp.received_by,
              p.plot_no, p.block, p.buyer_name
       FROM plot_payments pp
       JOIN plots p ON p.id = pp.plot_id
       WHERE pp.site_id = $1
         AND (UPPER(pp.payment_from) = UPPER($2) OR UPPER(p.buyer_name) = UPPER($2))
       ORDER BY pp.date DESC, pp.id DESC`,
      [siteId, memberName]
    ),
    // 4. Farmer Payments — via farmers.member_id
    pool.query(
      `SELECT fp.id, fp.date, fp.amount, fp.particular, fp.payment_mode,
              fp.cash_amount, fp.bank_amount, fp.remarks, fp.by_note,
              f.name AS farmer_name
       FROM farmer_payments fp
       JOIN farmers f ON f.id = fp.farmer_id
       WHERE f.site_id = $1 AND f.member_id = $2
       ORDER BY fp.date DESC, fp.id DESC`,
      [siteId, memberId]
    ),
    // 5. Firm Transactions — by name
    pool.query(
      `SELECT ft.id, ft.date, ft.debit, ft.credit, ft.description, ft.purpose,
              ft.remark, ft.cheque_no, ft.name,
              fi.name AS firm_name
       FROM firm_transactions ft
       JOIN firms fi ON fi.id = ft.firm_id
       WHERE fi.site_id = $1 AND UPPER(ft.name) = UPPER($2)
       ORDER BY ft.date DESC, ft.id DESC`,
      [siteId, memberName]
    ),
  ]);

  const expenses = expRes.rows;
  const commissions = commRes.rows;
  const plotPayments = plotPayRes.rows;
  const farmerPayments = farmerPayRes.rows;
  const firmTransactions = firmRes.rows;

  // Summaries per category
  const expTotal = expenses.reduce((s, e) => ({ debit: s.debit + (parseFloat(e.debit) || 0), credit: s.credit + (parseFloat(e.credit) || 0) }), { debit: 0, credit: 0 });
  const commTotal = commissions.reduce((s, c) => s + (parseFloat(c.amount) || 0), 0);
  const plotPayTotal = plotPayments.reduce((s, p) => s + (parseFloat(p.amount) || 0), 0);
  const farmerPayTotal = farmerPayments.reduce((s, p) => s + (parseFloat(p.amount) || 0), 0);
  const firmTotal = firmTransactions.reduce((s, f) => ({ debit: s.debit + (parseFloat(f.debit) || 0), credit: s.credit + (parseFloat(f.credit) || 0) }), { debit: 0, credit: 0 });

  res.json({
    expenses,
    commissions,
    plot_payments: plotPayments,
    farmer_payments: farmerPayments,
    firm_transactions: firmTransactions,
    summary: {
      expenses: { count: expenses.length, debit: expTotal.debit, credit: expTotal.credit },
      commissions: { count: commissions.length, total: commTotal },
      plot_payments: { count: plotPayments.length, total: plotPayTotal },
      farmer_payments: { count: farmerPayments.length, total: farmerPayTotal },
      firm_transactions: { count: firmTransactions.length, debit: firmTotal.debit, credit: firmTotal.credit },
      grand_total_entries: expenses.length + commissions.length + plotPayments.length + farmerPayments.length + firmTransactions.length,
    },
  });
});

/**
 * The modules the ledger unions, in display order. `key` matches the `module`
 * column emitted by LEDGER_SQL below, and is what the UI filters on.
 */
export const LEDGER_MODULES = [
  { key: 'plot_payments', label: 'Plot Payments' },
  { key: 'expenses', label: 'Expenses' },
  { key: 'day_book', label: 'Day Book' },
  { key: 'farmer_payments', label: 'Farmer Payments' },
  { key: 'plot_commission_payments', label: 'Commissions' },
  { key: 'vendor_payments', label: 'Vendor Payments' },
  { key: 'firm_transactions', label: 'Firm Transactions' },
  { key: 'cash_flow', label: 'Cash Flow' },
];

// Bounced/returned cheques deliberately KEEP their amount so history can still
// show them (see the sync_cashflow_from_modules notes in database.sql), so every
// branch below must exclude them or the ledger overstates. Rejected rows never count.
const liveRows = (alias) => `
      AND (${alias}.cheque_status IS NULL OR ${alias}.cheque_status NOT IN ('BOUNCED','RETURNED'))
      AND COALESCE(${alias}.status, '') <> 'rejected'`;

/**
 * Every money row touching one member, across all modules, in one shape:
 *   module, id, date, particular, counterparty, mode, ref, debit, credit,
 *   status, remark, role
 * `role` says WHY the row is in this member's ledger (Booked By / Buyer / Vendor…).
 *
 * $1 = site_id, $2 = member_id, $3 = UPPER(TRIM(member.full_name))
 *
 * TWO MIRROR TRAPS, both verified against the triggers in database.sql:
 *  1. cash_flow_entries mirrors every other module (source_module = the source
 *     table name), so it contributes ONLY its hand-entered rows
 *     (source_module IS NULL). Unioning the rest of it would double every row.
 *  2. day_book is mirrored INTO from cash_flow_entries, vendor_payments,
 *     farmer_payments, commissions, firm_transactions and plot_payments, so its
 *     branch repeats the 6-FK "originated here" predicate that the approvals
 *     feed already uses (approval.controller.js) — without it, a vendor payment
 *     would appear as both vendor_payments and day_book.
 *
 * Member linkage is by name for most modules because these tables store free
 * text, not a members FK. UPPER() is applied to the COLUMN (not just the param)
 * because legacy rows predate the trim+UPPER normalisation the controllers do now.
 */
export const LEDGER_SQL = `
    SELECT 'plot_payments'::text AS module, pp.id::int AS id, pp.date::date AS date,
           ('Plot ' || COALESCE(pl.plot_no, '—'))::text AS particular,
           COALESCE(pp.buyer_name, pp.payment_from)::text AS counterparty,
           pp.payment_type::text AS mode, pp.cheque_no::text AS ref,
           0::numeric AS debit, COALESCE(pp.amount, 0)::numeric AS credit,
           pp.status::text AS status, pp.narration::text AS remark,
           (CASE WHEN UPPER(pp.booked_by) = $3 THEN 'Booked By'
                 WHEN UPPER(pp.buyer_name) = $3 THEN 'Buyer'
                 ELSE 'Received By' END)::text AS role
    FROM plot_payments pp
    LEFT JOIN plots pl ON pl.id = pp.plot_id
    WHERE pp.site_id = $1
      AND (UPPER(pp.booked_by) = $3 OR UPPER(pp.buyer_name) = $3 OR UPPER(pp.received_by) = $3)
      ${liveRows('pp')}

    UNION ALL
    SELECT 'expenses'::text, e.id::int, e.date::date,
           COALESCE(NULLIF(e.category, ''), 'Expense')::text,
           NULLIF(CONCAT_WS(' → ', e.from_entity, e.to_entity), '')::text,
           e.payment_mode::text, e.cheque_no::text,
           COALESCE(e.debit, 0)::numeric, COALESCE(e.credit, 0)::numeric,
           e.status::text, e.remark::text,
           (CASE WHEN e.assigned_user_id = $2 THEN 'Assigned'
                 WHEN UPPER(e.to_entity) = $3 THEN 'Paid To'
                 ELSE 'Paid From' END)::text
    FROM expenses e
    WHERE e.site_id = $1
      AND (e.assigned_user_id = $2 OR UPPER(e.to_entity) = $3 OR UPPER(e.from_entity) = $3)
      ${liveRows('e')}

    UNION ALL
    SELECT 'day_book'::text, d.id::int, d.date::date,
           COALESCE(NULLIF(d.particular, ''), d.entry_type)::text,
           NULLIF(CONCAT_WS(' → ', d.from_entity, d.to_entity), '')::text,
           d.payment_mode::text, d.cheque_no::text,
           COALESCE(d.debit, 0)::numeric, COALESCE(d.credit, 0)::numeric,
           d.status::text, d.remarks::text,
           d.entry_type::text
    FROM day_book d
    WHERE d.site_id = $1
      AND (d.assigned_user_id = $2 OR UPPER(d.to_entity) = $3 OR UPPER(d.from_entity) = $3)
      AND d.farmer_payment_id IS NULL AND d.commission_id IS NULL AND d.cash_flow_entry_id IS NULL
      AND d.firm_transaction_id IS NULL AND d.plot_payment_id IS NULL AND d.vendor_payment_id IS NULL
      -- day_book has NO expense_id, so the FK block above cannot catch the
      -- day_book EXPENSE row that imprest writes alongside its expenses row
      -- (imprest.controller.js dual-writes both, unlinked). Without this the
      -- same imprest payment is counted by BOTH the expenses and day_book
      -- branches and total_debit doubles. Mirrors getMemberTransactions, which
      -- has always carried this guard.
      -- ponytail: a hand-entered day_book EXPENSE with no expenses row is not
      -- shown; link the imprest day_book row to its expense to lift this.
      AND d.entry_type <> 'EXPENSE'
      -- Commission payouts are mirrored into day_book on approval with no FK
      -- back to plot_commission_payments, so they'd double against that branch.
      AND d.entry_type <> 'PLOT COMMISSION'
      ${liveRows('d')}

    UNION ALL
    SELECT 'farmer_payments'::text, fp.id::int, fp.date::date,
           COALESCE(NULLIF(fp.particular, ''), 'Farmer Payment')::text,
           f.name::text,
           fp.payment_mode::text, fp.cheque_no::text,
           COALESCE(fp.amount, 0)::numeric, 0::numeric,
           fp.status::text, fp.remarks::text,
           'Farmer'::text
    FROM farmer_payments fp
    JOIN farmers f ON f.id = fp.farmer_id
    WHERE f.site_id = $1
      AND (f.member_id = $2 OR UPPER(f.name) = $3)
      ${liveRows('fp')}

    UNION ALL
    SELECT 'plot_commission_payments'::text, pcp.id::int, pcp.date::date,
           ('Commission' || COALESCE(' · Plot ' || pl2.plot_no, ''))::text,
           am.full_name::text,
           pcp.payment_mode::text, COALESCE(pcp.cheque_no, pcp.transaction_id)::text,
           -- A commission "get" is stored as a NEGATIVE amount (see
           -- PlotCommissionDetail.jsx), so split the sign across the two
           -- columns instead of emitting a negative debit, which would make
           -- the running balance and the module totals read backwards.
           GREATEST(COALESCE(pcp.amount, 0), 0)::numeric,
           GREATEST(-COALESCE(pcp.amount, 0), 0)::numeric,
           pcp.status::text, pcp.remarks::text,
           'Agent'::text
    FROM plot_commission_payments pcp
    JOIN plot_commissions_v2 pcm ON pcm.id = pcp.plot_commission_id
    LEFT JOIN plots pl2 ON pl2.id = pcm.plot_id
    LEFT JOIN members am ON am.id = pcm.agent_id
    WHERE pcm.site_id = $1 AND pcm.agent_id = $2
      ${liveRows('pcp')}

    UNION ALL
    SELECT 'vendor_payments'::text, vp.id::int, vp.payment_date::date,
           COALESCE(NULLIF(vc.work_title, ''), 'Vendor Payment')::text,
           vc.vendor_name::text,
           vp.payment_mode::text, COALESCE(vp.cheque_no, vp.reference_no)::text,
           COALESCE(vp.amount, 0)::numeric, 0::numeric,
           vp.status::text, vp.note::text,
           'Vendor'::text
    FROM vendor_payments vp
    JOIN vendor_commitments vc ON vc.id = vp.commitment_id
    WHERE vp.site_id = $1
      AND (vc.vendor_member_id = $2
           OR (vc.vendor_member_id IS NULL AND UPPER(TRIM(vc.vendor_name)) = $3))
      ${liveRows('vp')}

    UNION ALL
    SELECT 'firm_transactions'::text, ft.id::int, ft.date::date,
           COALESCE(NULLIF(ft.description, ''), ft.purpose, 'Firm Transaction')::text,
           fi.name::text,
           ft.payment_mode::text, ft.cheque_no::text,
           COALESCE(ft.debit, 0)::numeric, COALESCE(ft.credit, 0)::numeric,
           ft.status::text, ft.remark::text,
           'Named'::text
    FROM firm_transactions ft
    JOIN firms fi ON fi.id = ft.firm_id
    WHERE ft.site_id = $1 AND UPPER(ft.name) = $3
      ${liveRows('ft')}

    UNION ALL
    SELECT 'cash_flow'::text, cfe.id::int, cfe.date::date,
           cfe.particular::text,
           COALESCE(cfe.to_name, cfm.ledger_name)::text,
           cfe.cash_type::text, cfe.cheque_no::text,
           COALESCE(cfe.debit, 0)::numeric, COALESCE(cfe.credit, 0)::numeric,
           cfe.status::text, cfe.remarks::text,
           (CASE WHEN LOWER(cfm.ledger_type) = 'person' AND UPPER(cfm.ledger_name) = $3
                 THEN 'Personal Ledger' ELSE 'Named' END)::text
    FROM cash_flow_entries cfe
    JOIN cash_flow_months cfm ON cfm.id = cfe.cash_flow_month_id
    WHERE cfe.site_id = $1
      AND cfe.source_module IS NULL
      AND ((LOWER(cfm.ledger_type) = 'person' AND UPPER(cfm.ledger_name) = $3)
           OR UPPER(cfe.to_name) = $3)
      ${liveRows('cfe')}

    ORDER BY date DESC, id DESC`;

/**
 * GET /members/:id/ledger?site_id=X
 * Full cross-module money ledger for one member. Returns every row plus
 * per-module totals, so the UI can render its filter chips without a 2nd call.
 */
export const getMemberLedger = asyncHandler(async (req, res) => {
  const memberId = parseInt(req.params.id);
  const { site_id } = req.query;
  if (!site_id) return res.status(400).json({ message: 'site_id is required' });

  const member = await memberModel.findById(memberId, pool);
  if (!member) return res.status(404).json({ message: 'Member not found' });

  const siteId = parseInt(site_id);
  const name = String(member.full_name || '').trim().toUpperCase();

  const { rows } = await pool.query(LEDGER_SQL, [siteId, memberId, name]);

  const num = (v) => parseFloat(v) || 0;
  const modules = LEDGER_MODULES.map((m) => {
    const mine = rows.filter((r) => r.module === m.key);
    return {
      ...m,
      count: mine.length,
      debit: mine.reduce((s, r) => s + num(r.debit), 0),
      credit: mine.reduce((s, r) => s + num(r.credit), 0),
    };
  });

  const totalDebit = rows.reduce((s, r) => s + num(r.debit), 0);
  const totalCredit = rows.reduce((s, r) => s + num(r.credit), 0);

  res.json({
    member: { id: member.id, full_name: member.full_name, member_type: member.member_type, phone: member.phone },
    transactions: rows,
    modules,
    summary: {
      total_debit: totalDebit,
      total_credit: totalCredit,
      net: totalCredit - totalDebit,
      count: rows.length,
    },
  });
});
