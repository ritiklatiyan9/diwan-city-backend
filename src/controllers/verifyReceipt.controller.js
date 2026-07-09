import { verifyReceiptToken } from '../utils/receiptToken.js';

/**
 * GET /verify-receipt?token=...
 * Public — verifies an HMAC-signed receipt token embedded in the QR code on
 * any printed receipt (expense, vendor, plot, commission, daybook, farmer...).
 * Token payload shape is module-agnostic (see receiptToken.js), so one
 * handler covers every receipt type.
 */
export const verifyReceipt = (req, res) => {
  const result = verifyReceiptToken(req.query?.token);
  if (!result.valid) {
    return res.status(400).json({ valid: false, message: result.reason });
  }
  return res.json({ valid: true, receipt: result.payload });
};
