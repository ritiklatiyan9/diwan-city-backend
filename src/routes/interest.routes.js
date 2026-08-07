import express from 'express';
const router = express.Router();

import {
  listParties, getParty, createParty, updateParty, deleteParty,
  createLoan, updateLoan, deleteLoan,
  createTransaction, updateTransaction, deleteTransaction,
} from '../controllers/interest.controller.js';
import authMiddleware from '../middlewares/auth.middleware.js';
import requireRole from '../middlewares/role.middleware.js';
import requirePermission from '../middlewares/permission.middleware.js';

// ponytail: no response cache here. The module is small and write-heavy per
// party; add cacheResponse only if a site's party list gets slow.
router.use(authMiddleware);

const read = [requireRole('admin', 'sub_admin'), requirePermission('interest', 'read')];
const write = [requireRole('admin', 'sub_admin'), requirePermission('interest', 'write')];
const update = [requireRole('admin', 'sub_admin'), requirePermission('interest', 'update')];
const remove = [requireRole('admin', 'sub_admin'), requirePermission('interest', 'delete')];

// ── Parties ──
router.get('/parties', read, listParties);                 // ?site_id=X
router.get('/parties/:id', read, getParty);                // ?site_id=X
router.post('/parties', write, createParty);
router.put('/parties/:id', update, updateParty);
router.delete('/parties/:id', remove, deleteParty);

// ── Loans ──
router.post('/loans', write, createLoan);
router.put('/loans/:id', update, updateLoan);
router.delete('/loans/:id', remove, deleteLoan);

// ── Transactions ──
router.post('/transactions', write, createTransaction);
router.put('/transactions/:id', update, updateTransaction);
router.delete('/transactions/:id', remove, deleteTransaction);

export default router;
