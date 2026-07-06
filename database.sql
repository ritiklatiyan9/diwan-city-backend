--
-- PostgreSQL schema dump (schema only, no data)
-- Source database: rgaccount
-- Server: PostgreSQL 17.10 (98a80fa) on aarch64-unknown-linux-gnu, compiled by gcc (Debian 12.2.0-14+deb12u1) 12.2.0, 64-bit
-- Generated via catalog introspection (pg_get_* functions)
-- Restore order: extensions, types, functions, sequences, tables,
--   defaults, constraints (PK/UNIQUE/CHECK), foreign keys, indexes, triggers, views.
--

SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

-- ============================ FUNCTIONS ============================
CREATE OR REPLACE FUNCTION public.ensure_site_cashflow_month(p_site_id integer, p_entry_date date, p_created_by integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
      DECLARE
        v_month INTEGER;
        v_year INTEGER;
        v_month_id INTEGER;
        v_prev_id INTEGER;
        v_opening NUMERIC(15,2) := 0;
      BEGIN
        v_month := EXTRACT(MONTH FROM p_entry_date)::INTEGER;
        v_year := EXTRACT(YEAR FROM p_entry_date)::INTEGER;

        SELECT id INTO v_month_id
        FROM cash_flow_months
        WHERE site_id = p_site_id
          AND month = v_month
          AND year = v_year
          AND COALESCE(ledger_name, '') = ''
          AND COALESCE(ledger_type, 'site') = 'site'
        LIMIT 1;

        IF v_month_id IS NOT NULL THEN
          RETURN v_month_id;
        END IF;

        SELECT cfm.id INTO v_prev_id
        FROM cash_flow_months cfm
        WHERE cfm.site_id = p_site_id
          AND COALESCE(cfm.ledger_name, '') = ''
          AND COALESCE(cfm.ledger_type, 'site') = 'site'
          AND (cfm.year < v_year OR (cfm.year = v_year AND cfm.month < v_month))
        ORDER BY cfm.year DESC, cfm.month DESC
        LIMIT 1;

        IF v_prev_id IS NOT NULL THEN
          SELECT
            COALESCE(cfm.opening_balance, 0)
              + COALESCE(SUM(cfe.credit), 0)
              - COALESCE(SUM(cfe.debit), 0)
          INTO v_opening
          FROM cash_flow_months cfm
          LEFT JOIN cash_flow_entries cfe ON cfe.cash_flow_month_id = cfm.id
          WHERE cfm.id = v_prev_id
          GROUP BY cfm.opening_balance;
        END IF;

        INSERT INTO cash_flow_months (
          site_id, month, year, ledger_name, ledger_type, opening_balance, created_by
        ) VALUES (
          p_site_id, v_month, v_year, '', 'site', COALESCE(v_opening, 0), p_created_by
        )
        ON CONFLICT (site_id, month, year, ledger_name)
        DO NOTHING;

        SELECT id INTO v_month_id
        FROM cash_flow_months
        WHERE site_id = p_site_id
          AND month = v_month
          AND year = v_year
          AND COALESCE(ledger_name, '') = ''
          AND COALESCE(ledger_type, 'site') = 'site'
        LIMIT 1;

        RETURN v_month_id;
      END;
      $function$;

CREATE OR REPLACE FUNCTION public.sync_cashflow_from_modules()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
      DECLARE
        v_site_id INTEGER;
        v_entry_date DATE;
        v_particular VARCHAR(500);
        v_debit NUMERIC(15,2) := 0;
        v_credit NUMERIC(15,2) := 0;
        v_cash_type VARCHAR(20) := 'bank';
        v_remarks TEXT;
        v_created_by INTEGER;
        v_month_id INTEGER;
        v_source_module VARCHAR(50);
        v_source_id INTEGER;
        v_assigned_admin_id INTEGER;
        v_voucher_url TEXT;
        v_status VARCHAR(20) := 'pending';
        v_approved_by INTEGER;
        v_approved_at TIMESTAMPTZ;
        v_cheque_status VARCHAR(20);
        v_cheque_no VARCHAR(50);
      BEGIN
        v_source_module := TG_TABLE_NAME;

        IF TG_OP = 'DELETE' THEN
          DELETE FROM cash_flow_entries cfe
          WHERE cfe.source_module = v_source_module
            AND cfe.source_id = OLD.id;
          RETURN OLD;
        END IF;

        v_source_id := NEW.id;

        -- Safe assignments from NEW (only if columns exist in the table)
        IF TG_TABLE_NAME IN ('farmer_payments', 'plot_commission_payments', 'firm_transactions', 'vendor_payments', 'plot_payments', 'expenses', 'plot_registry_payments', 'day_book', 'plot_commissions', 'plot_installment_payments') THEN
          BEGIN
            v_cheque_status := NEW.cheque_status;
            v_cheque_no := NEW.cheque_no;
          EXCEPTION WHEN OTHERS THEN
            v_cheque_status := NULL;
            v_cheque_no := NULL;
          END;
        END IF;

        -- ── CASE: farmer_payments ──
        IF TG_TABLE_NAME = 'farmer_payments' THEN
          SELECT f.site_id, f.name INTO v_site_id, v_particular FROM farmers f WHERE f.id = NEW.farmer_id;
          v_entry_date := COALESCE(NEW.date, CURRENT_DATE);
          v_particular := ('FARMER PAYMENT - ' || COALESCE(v_particular, 'FARMER'))::VARCHAR(500);
          v_debit := COALESCE(NEW.amount, 0);
          v_cash_type := CASE 
            WHEN UPPER(COALESCE(NEW.payment_mode, 'CASH')) = 'CASH'   THEN 'cash' 
            WHEN UPPER(COALESCE(NEW.payment_mode, 'CASH')) = 'CHEQUE' THEN 'cheque'
            ELSE 'bank' 
          END;
          v_status := COALESCE(NEW.status, 'pending');
          v_remarks := NEW.remarks;
          v_assigned_admin_id := NEW.assigned_admin_id;

        -- ── CASE: plot_commissions ──
        ELSIF TG_TABLE_NAME = 'plot_commissions' THEN
          v_site_id := NEW.site_id;
          v_entry_date := COALESCE(NEW.date, CURRENT_DATE);
          v_particular := ('PLOT COMMISSION - ' || COALESCE(NEW.particular, 'COMMISSION'))::VARCHAR(500);
          v_debit := COALESCE(NEW.amount, 0);
          v_cash_type := CASE 
            WHEN UPPER(COALESCE(NEW.by_note, 'CASH')) LIKE '%CHEQUE%' THEN 'cheque'
            WHEN UPPER(COALESCE(NEW.by_note, 'CASH')) LIKE '%BANK%'   THEN 'bank'
            WHEN UPPER(COALESCE(NEW.by_note, 'CASH')) LIKE '%ONLINE%' THEN 'bank'
            ELSE 'cash' 
          END;
          v_status := COALESCE(NEW.status, 'pending');
          v_created_by := NEW.created_by;
          v_remarks := NEW.remarks;

        -- ── CASE: plot_commission_payments ──
        ELSIF TG_TABLE_NAME = 'plot_commission_payments' THEN
          SELECT COALESCE(m.full_name, 'AGENT') INTO v_particular FROM plot_commissions_v2 pcm LEFT JOIN members m ON m.id = pcm.agent_id WHERE pcm.id = NEW.plot_commission_id;
          v_site_id := NEW.site_id;
          v_entry_date := COALESCE(NEW.date, CURRENT_DATE);
          v_particular := ('PLOT COMMISSION PAYMENT - ' || COALESCE(v_particular, 'AGENT'))::VARCHAR(500);
          v_debit := COALESCE(NEW.amount, 0);
          v_cash_type := CASE 
            WHEN UPPER(COALESCE(NEW.payment_mode, 'CASH')) = 'CASH'   THEN 'cash' 
            WHEN UPPER(COALESCE(NEW.payment_mode, 'CASH')) = 'CHEQUE' THEN 'cheque'
            ELSE 'bank' 
          END;
          v_status := COALESCE(NEW.status, 'pending');
          v_created_by := NEW.created_by;

        -- ── CASE: firm_transactions ──
        ELSIF TG_TABLE_NAME = 'firm_transactions' THEN
          v_site_id := NEW.site_id;
          v_entry_date := COALESCE(NEW.date, CURRENT_DATE);
          v_particular := ('FIRM TRANSACTION - ' || COALESCE(NEW.description, 'TRANSACTION'))::VARCHAR(500);
          v_debit := COALESCE(NEW.debit, 0);
          v_credit := COALESCE(NEW.credit, 0);
          v_cash_type := CASE 
            WHEN UPPER(COALESCE(NEW.payment_mode, 'CASH')) = 'CASH'   THEN 'cash' 
            WHEN UPPER(COALESCE(NEW.payment_mode, 'CASH')) = 'CHEQUE' THEN 'cheque'
            ELSE 'bank' 
          END;
          v_status := 'approved';
          v_created_by := NEW.created_by;
          v_remarks := NEW.remark;

        -- ── CASE: plot_payments ──
        ELSIF TG_TABLE_NAME = 'plot_payments' THEN
          v_site_id := NEW.site_id;
          v_entry_date := COALESCE(NEW.date, CURRENT_DATE);
          v_particular := ('PLOT PAYMENT - ' || COALESCE(NEW.buyer_name, NEW.payment_from, 'PLOT'))::VARCHAR(500);
          v_credit := COALESCE(NEW.amount, 0);
          v_cash_type := CASE 
            WHEN UPPER(COALESCE(NEW.payment_type, 'CASH')) = 'CASH'   THEN 'cash' 
            WHEN UPPER(COALESCE(NEW.payment_type, 'CASH')) = 'CHEQUE' THEN 'cheque'
            ELSE 'bank' 
          END;
          v_status := COALESCE(NEW.status, 'pending');
          v_created_by := NEW.created_by;
          v_remarks := NEW.narration;

        -- ── CASE: expenses ──
        ELSIF TG_TABLE_NAME = 'expenses' THEN
          v_site_id := NEW.site_id;
          v_entry_date := COALESCE(NEW.date, CURRENT_DATE);
          v_particular := COALESCE(NEW.remark, 'EXPENSE ENTRY')::VARCHAR(500);
          v_debit := COALESCE(NEW.debit, 0);
          v_credit := COALESCE(NEW.credit, 0);
          v_cash_type := CASE 
            WHEN UPPER(COALESCE(NEW.payment_mode, 'CASH')) LIKE '%CHEQUE%' THEN 'cheque'
            WHEN UPPER(COALESCE(NEW.payment_mode, 'CASH')) LIKE '%BANK%'   THEN 'bank'
            ELSE 'cash' 
          END;
          v_status := COALESCE(NEW.status, 'pending');
          v_created_by := NEW.created_by;
          v_remarks := CONCAT_WS(' | ', NEW.from_entity, NEW.to_entity, NEW.category);

        -- ── CASE: vendor_payments ──
        ELSIF TG_TABLE_NAME = 'vendor_payments' THEN
          SELECT vc.vendor_name INTO v_particular FROM vendor_commitments vc WHERE vc.id = NEW.commitment_id;
          v_site_id := NEW.site_id;
          v_entry_date := COALESCE(NEW.payment_date, CURRENT_DATE);
          v_particular := ('VENDOR PAYMENT - ' || COALESCE(v_particular, 'VENDOR'))::VARCHAR(500);
          v_debit := COALESCE(NEW.amount, 0);
          v_cash_type := CASE 
            WHEN LOWER(COALESCE(NEW.payment_mode, 'cash')) = 'cheque' THEN 'cheque'
            WHEN LOWER(COALESCE(NEW.payment_mode, 'cash')) = 'bank'   THEN 'bank'
            ELSE 'cash' 
          END;
          v_status := COALESCE(NEW.status, 'pending');
          v_created_by := NEW.created_by;
          v_remarks := NEW.note;

        -- ── CASE: plot_installment_payments ──
        ELSIF TG_TABLE_NAME = 'plot_installment_payments' THEN
          SELECT plot_no, buyer_name, site_id INTO v_particular, v_remarks, v_site_id FROM plots WHERE id = NEW.plot_id;
          v_entry_date := COALESCE(NEW.payment_date, CURRENT_DATE);
          v_particular := ('INST. PAYMENT - ' || COALESCE(v_particular, 'PLOT') || ' (' || COALESCE(v_remarks, 'BUYER') || ')')::VARCHAR(500);
          v_credit := COALESCE(NEW.amount, 0);
          v_cash_type := CASE 
            WHEN UPPER(COALESCE(NEW.payment_mode, 'CASH')) = 'CASH'   THEN 'cash' 
            WHEN UPPER(COALESCE(NEW.payment_mode, 'CASH')) = 'CHEQUE' THEN 'cheque'
            ELSE 'bank' 
          END;
          v_status := 'approved';
          v_created_by := NEW.created_by;
          v_remarks := NEW.notes;

        -- ── CASE: plot_registry_payments ──
        ELSIF TG_TABLE_NAME = 'plot_registry_payments' THEN
          SELECT p.plot_no, p.buyer_name, p.site_id INTO v_particular, v_remarks, v_site_id FROM plot_registries pr JOIN plots p ON pr.plot_id = p.id WHERE pr.id = NEW.registry_id;
          v_entry_date := COALESCE(NEW.payment_date, CURRENT_DATE);
          v_particular := ('REGISTRY PAYMENT - ' || COALESCE(v_particular, 'PLOT') || ' (' || COALESCE(v_remarks, 'BUYER') || ')')::VARCHAR(500);
          v_debit := COALESCE(NEW.amount, 0);
          v_cash_type := CASE 
            WHEN UPPER(COALESCE(NEW.payment_mode, 'CASH')) = 'CASH'   THEN 'cash' 
            WHEN UPPER(COALESCE(NEW.payment_mode, 'CASH')) = 'CHEQUE' THEN 'cheque'
            ELSE 'bank' 
          END;
          v_status := 'approved';
          v_created_by := NEW.created_by;
          v_remarks := NEW.notes;

        -- ── CASE: day_book ──
        -- Day_book entries whose entry_type belongs to another module (FARMER PAYMENT,
        -- PLOT COMMISSION, VENDOR PAYMENT, FIRM TRANSACTION, PLOT PAYMENT, CASH FLOW)
        -- are always linked back to that module's own table via farmer_payment_id /
        -- commission_id / vendor_payment_id / firm_transaction_id / plot_payment_id /
        -- cash_flow_entry_id. The module table already has its own CFE via its own
        -- trigger, so the day_book entry must NOT create a duplicate CFE.
        ELSIF TG_TABLE_NAME = 'day_book' THEN
          IF UPPER(COALESCE(NEW.entry_type, 'GENERAL')) IN ('CASH FLOW', 'FARMER PAYMENT', 'PLOT COMMISSION', 'FIRM TRANSACTION', 'PLOT PAYMENT', 'VENDOR PAYMENT')
             AND (NEW.cash_flow_entry_id IS NOT NULL
                  OR NEW.firm_transaction_id IS NOT NULL
                  OR NEW.plot_payment_id IS NOT NULL
                  OR NEW.farmer_payment_id IS NOT NULL
                  OR NEW.commission_id IS NOT NULL
                  OR NEW.vendor_payment_id IS NOT NULL)
          THEN
            DELETE FROM cash_flow_entries WHERE source_module = 'day_book' AND source_id = NEW.id;
            RETURN NEW;
          END IF;
          v_site_id := NEW.site_id;
          v_entry_date := NEW.date;
          v_particular := COALESCE(NEW.particular, 'DAY BOOK ENTRY')::VARCHAR(500);
          v_debit := COALESCE(NEW.debit, 0);
          v_credit := COALESCE(NEW.credit, 0);
          v_cash_type := CASE 
            WHEN UPPER(COALESCE(NEW.payment_mode, 'CASH')) = 'CASH'   THEN 'cash' 
            WHEN UPPER(COALESCE(NEW.payment_mode, 'CASH')) = 'CHEQUE' THEN 'cheque'
            ELSE 'bank' 
          END;
          v_status := COALESCE(NEW.status, 'pending');
          v_created_by := NEW.created_by;
          v_remarks := NEW.remarks;
        END IF;

        -- NOTE: Bounced/returned cheques keep their actual amounts here.
        -- All financial sum queries already exclude them via:
        --   (cheque_status IS NULL OR cheque_status NOT IN ('BOUNCED', 'RETURNED'))
        -- Storing the amount allows the transaction history (e.g. Dashboard) to display it.

        IF v_site_id IS NULL OR (COALESCE(v_debit, 0) = 0 AND COALESCE(v_credit, 0) = 0 AND v_cheque_status IS NULL) THEN
          DELETE FROM cash_flow_entries cfe WHERE cfe.source_module = v_source_module AND cfe.source_id = v_source_id;
          RETURN NEW;
        END IF;

        v_month_id := ensure_site_cashflow_month(v_site_id, v_entry_date, v_created_by);

        INSERT INTO cash_flow_entries (
          cash_flow_month_id, site_id, date, particular, debit, credit, cash_type, remarks,
          status, source_module, source_id, created_by, created_at,
          assigned_admin_id, cheque_status, cheque_no
        ) VALUES (
          v_month_id, v_site_id, v_entry_date, v_particular, v_debit, v_credit, v_cash_type, v_remarks,
          v_status, v_source_module, v_source_id, v_created_by, NEW.created_at,
          NEW.assigned_admin_id, v_cheque_status, v_cheque_no
        )
        ON CONFLICT (source_module, source_id)
        DO UPDATE SET
          cash_flow_month_id = EXCLUDED.cash_flow_month_id, site_id = EXCLUDED.site_id, 
          date = EXCLUDED.date, particular = EXCLUDED.particular,
          debit = EXCLUDED.debit, credit = EXCLUDED.credit, cash_type = EXCLUDED.cash_type,
          remarks = EXCLUDED.remarks, status = EXCLUDED.status, created_by = EXCLUDED.created_by,
          assigned_admin_id = EXCLUDED.assigned_admin_id, 
          cheque_status = EXCLUDED.cheque_status, cheque_no = EXCLUDED.cheque_no, updated_at = NOW();

        RETURN NEW;
      END;
      $function$;

CREATE OR REPLACE FUNCTION public.sync_cashflow_status_from_source()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
      BEGIN
        IF TG_TABLE_NAME = 'day_book' THEN
          UPDATE cash_flow_entries cfe
          SET
            status = COALESCE(NEW.status, cfe.status),
            approved_by = NEW.approved_by,
            approved_at = NEW.approved_at,
            assigned_admin_id = NEW.assigned_admin_id,
            updated_at = NOW()
          WHERE cfe.source_module = 'day_book'
            AND cfe.source_id = NEW.id;

        ELSIF TG_TABLE_NAME = 'expenses' THEN
          UPDATE cash_flow_entries cfe
          SET
            status = COALESCE(NEW.status, cfe.status),
            approved_by = NEW.approved_by,
            approved_at = NEW.approved_at,
            voucher_url = COALESCE(NEW.voucher_url, cfe.voucher_url),
            updated_at = NOW()
          WHERE cfe.source_module = 'expenses'
            AND cfe.source_id = NEW.id;

        ELSIF TG_TABLE_NAME = 'firm_transactions' THEN
          UPDATE cash_flow_entries cfe
          SET
            status = COALESCE(NEW.status, cfe.status),
            voucher_url = COALESCE(NEW.voucher_url, cfe.voucher_url),
            updated_at = NOW()
          WHERE cfe.source_module = 'firm_transactions'
            AND cfe.source_id = NEW.id;

        ELSIF TG_TABLE_NAME = 'plot_payments' THEN
          UPDATE cash_flow_entries cfe
          SET
            status = COALESCE(NEW.status, cfe.status),
            voucher_url = COALESCE(NEW.voucher_url, cfe.voucher_url),
            updated_at = NOW()
          WHERE cfe.source_module = 'plot_payments'
            AND cfe.source_id = NEW.id;

        ELSIF TG_TABLE_NAME = 'vendor_payments' THEN
          UPDATE cash_flow_entries cfe
          SET
            status = COALESCE(NEW.status, cfe.status),
            approved_by = NEW.approved_by,
            approved_at = NEW.approved_at,
            voucher_url = COALESCE(NEW.voucher_url, cfe.voucher_url),
            updated_at = NOW()
          WHERE cfe.source_module = 'vendor_payments'
            AND cfe.source_id = NEW.id;
        END IF;

        RETURN NEW;
      END;
      $function$;

CREATE OR REPLACE FUNCTION public.sync_daybook_from_vendor_payments()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
      DECLARE
        v_vendor_name VARCHAR(255);
      BEGIN
        SELECT COALESCE(vc.vendor_name, 'VENDOR') INTO v_vendor_name
        FROM vendor_commitments vc
        WHERE vc.id = NEW.commitment_id;

        IF TG_OP = 'INSERT' THEN
          INSERT INTO day_book (
            site_id, date, particular, entry_type,
            debit, credit, remarks, payment_mode,
            category, from_entity, to_entity,
            status, approved_by, approved_at,
            vendor_payment_id, created_by
          ) VALUES (
            NEW.site_id,
            COALESCE(NEW.payment_date, CURRENT_DATE),
            ('VENDOR PAYMENT - ' || COALESCE(v_vendor_name, 'VENDOR'))::VARCHAR(500),
            'VENDOR PAYMENT',
            COALESCE(NEW.amount, 0),
            0,
            NEW.note,
            UPPER(COALESCE(NEW.payment_mode, 'CASH')),
            'VENDOR',
            'COMPANY',
            COALESCE(v_vendor_name, NEW.reference_no, 'VENDOR'),
            COALESCE(NEW.status, 'pending'),
            NEW.approved_by,
            NEW.approved_at,
            NEW.id,
            NEW.created_by
          )
          ON CONFLICT DO NOTHING;
        ELSE
          UPDATE day_book db
          SET
            site_id = NEW.site_id,
            date = COALESCE(NEW.payment_date, db.date),
            particular = ('VENDOR PAYMENT - ' || COALESCE(v_vendor_name, 'VENDOR'))::VARCHAR(500),
            debit = COALESCE(NEW.amount, 0),
            credit = 0,
            remarks = NEW.note,
            payment_mode = UPPER(COALESCE(NEW.payment_mode, db.payment_mode, 'CASH')),
            category = 'VENDOR',
            from_entity = 'COMPANY',
            to_entity = COALESCE(v_vendor_name, db.to_entity),
            status = COALESCE(NEW.status, db.status),
            approved_by = NEW.approved_by,
            approved_at = NEW.approved_at,
            updated_at = NOW()
          WHERE db.vendor_payment_id = NEW.id;
        END IF;

        RETURN NEW;
      END;
      $function$;

CREATE OR REPLACE FUNCTION public.sync_vendor_inventory_order()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
      DECLARE
        v_order_id INTEGER;
        v_paid     NUMERIC(14,2);
        v_rcvd     NUMERIC(14,3);
        v_ordered  NUMERIC(14,3);
        v_net      NUMERIC(14,2);
        v_status   VARCHAR(20);
      BEGIN
        -- determine order_id from whichever table fired
        IF TG_TABLE_NAME = 'vendor_inventory_payments' THEN
          v_order_id := COALESCE(NEW.order_id, OLD.order_id);
        ELSE
          v_order_id := COALESCE(NEW.order_id, OLD.order_id);
        END IF;

        SELECT COALESCE(SUM(amount), 0) INTO v_paid
        FROM vendor_inventory_payments WHERE order_id = v_order_id;

        SELECT COALESCE(SUM(qty), 0) INTO v_rcvd
        FROM vendor_inventory_deliveries WHERE order_id = v_order_id;

        SELECT qty_ordered INTO v_ordered
        FROM vendor_inventory_orders WHERE id = v_order_id;

        -- derive net_amount inline (mirrors generated column logic)
        SELECT ROUND(v_rcvd * rate
          - COALESCE(CASE WHEN discount_pct > 0 THEN ROUND(v_rcvd * rate * discount_pct / 100, 2)
                         ELSE discount_amount END, 0), 2)
        INTO v_net
        FROM vendor_inventory_orders WHERE id = v_order_id;

        -- status logic
        IF v_rcvd = 0 THEN
          v_status := 'open';
        ELSIF v_rcvd >= v_ordered THEN
          v_status := 'completed';
        ELSE
          v_status := 'partial';
        END IF;

        UPDATE vendor_inventory_orders
        SET total_paid   = v_paid,
            qty_received = v_rcvd,
            status       = v_status,
            updated_at   = CURRENT_TIMESTAMP
        WHERE id = v_order_id;

        RETURN NULL;
      END;
      $function$;

CREATE OR REPLACE FUNCTION public.update_modified_column()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
      BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
      $function$;

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$function$;

-- ============================ SEQUENCES ============================
CREATE SEQUENCE IF NOT EXISTS public.agent_activity_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.agent_ledger_entries_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.bookings_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.cash_flow_entries_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.cash_flow_months_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.conversations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.dashboard_component_permissions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.day_book_daily_balance_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.day_book_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.documents_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.edit_requests_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.excel_files_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.expense_categories_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.expenses_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.farmer_payments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.farmers_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.file_folders_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.firm_transactions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.firms_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.imprest_allocations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.imprest_expense_requests_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.imprest_ledger_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.imprest_returns_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.kyc_cases_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.member_categories_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.members_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.messages_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.ocr_results_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.plot_commission_payments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.plot_commissions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.plot_commissions_v2_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.plot_installment_payments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.plot_installments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.plot_payments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.plot_registries_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.plot_registry_payments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.plots_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.project_settings_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.sites_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.teams_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.user_approval_modules_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.user_permissions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.user_sessions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.user_sites_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.users_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.vendor_commitments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.vendor_heads_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.vendor_inventory_deliveries_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.vendor_inventory_orders_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.vendor_inventory_payments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;
CREATE SEQUENCE IF NOT EXISTS public.vendor_payments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    MINVALUE 1
    MAXVALUE 2147483647
    CACHE 1;

-- ============================ TABLES ===============================
CREATE TABLE public.agent_activity_log (
    id integer DEFAULT nextval('agent_activity_log_id_seq'::regclass) NOT NULL,
    actor_user_id integer,
    target_user_id integer,
    action text NOT NULL,
    detail jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.agent_ledger_entries (
    id integer DEFAULT nextval('agent_ledger_entries_id_seq'::regclass) NOT NULL,
    user_id integer NOT NULL,
    entry_type text NOT NULL,
    direction text NOT NULL,
    amount numeric(14,2) NOT NULL,
    status text DEFAULT 'PENDING'::text NOT NULL,
    booking_id integer,
    plot_id integer,
    site_id integer,
    narration text,
    meta jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_by integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.bookings (
    id integer DEFAULT nextval('bookings_id_seq'::regclass) NOT NULL,
    site_id integer NOT NULL,
    plot_id integer,
    client_member_id integer,
    booking_no character varying(40),
    booking_date date DEFAULT CURRENT_DATE NOT NULL,
    sale_price numeric(15,2) DEFAULT 0 NOT NULL,
    token_amount numeric(15,2) DEFAULT 0 NOT NULL,
    payment_plan character varying(20) DEFAULT 'FULL'::character varying NOT NULL,
    status character varying(20) DEFAULT 'DRAFT'::character varying NOT NULL,
    kyc_status character varying(20) DEFAULT 'NOT_STARTED'::character varying NOT NULL,
    buyer_name character varying(255),
    booked_by character varying(255),
    notes text,
    created_by integer,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    booking_agent_id integer,
    token_payment_id integer,
    token_payment_from character varying(100) DEFAULT 'CASH'::character varying,
    token_payment_date date,
    token_bank_name character varying(150),
    token_branch character varying(150),
    token_bank_details character varying(255),
    token_cheque_no character varying(50),
    token_narration text,
    token_received_by character varying(255),
    agent_user_id integer,
    team_id integer
);

CREATE TABLE public.cash_flow_entries (
    id integer DEFAULT nextval('cash_flow_entries_id_seq'::regclass) NOT NULL,
    cash_flow_month_id integer NOT NULL,
    site_id integer NOT NULL,
    date date DEFAULT CURRENT_DATE NOT NULL,
    particular character varying(500) NOT NULL,
    debit numeric(15,2) DEFAULT 0 NOT NULL,
    credit numeric(15,2) DEFAULT 0 NOT NULL,
    remarks text,
    created_by integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    cash_type character varying(20) DEFAULT 'bank'::character varying NOT NULL,
    voucher_url character varying(1000),
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    approved_by integer,
    approved_at timestamp with time zone,
    is_firm_transaction boolean DEFAULT false NOT NULL,
    from_firm_id integer,
    to_firm_id integer,
    to_name character varying(255),
    source_module character varying(50),
    source_id integer,
    assigned_admin_id integer,
    cheque_status character varying(20) DEFAULT NULL::character varying,
    cheque_no character varying(50) DEFAULT NULL::character varying
);

CREATE TABLE public.cash_flow_months (
    id integer DEFAULT nextval('cash_flow_months_id_seq'::regclass) NOT NULL,
    site_id integer NOT NULL,
    month integer NOT NULL,
    year integer NOT NULL,
    opening_balance numeric(15,2) DEFAULT 0 NOT NULL,
    notes text,
    is_locked boolean DEFAULT false,
    created_by integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    ledger_name character varying(255),
    ledger_type character varying(20) DEFAULT 'site'::character varying
);

CREATE TABLE public.conversations (
    id integer DEFAULT nextval('conversations_id_seq'::regclass) NOT NULL,
    user1_id integer,
    user2_id integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE public.dashboard_component_permissions (
    id integer DEFAULT nextval('dashboard_component_permissions_id_seq'::regclass) NOT NULL,
    user_id integer NOT NULL,
    component character varying(60) NOT NULL,
    allowed boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.day_book (
    id integer DEFAULT nextval('day_book_id_seq'::regclass) NOT NULL,
    site_id integer NOT NULL,
    date date DEFAULT CURRENT_DATE NOT NULL,
    particular character varying(500) NOT NULL,
    entry_type character varying(50) DEFAULT 'GENERAL'::character varying NOT NULL,
    debit numeric(15,2) DEFAULT 0 NOT NULL,
    credit numeric(15,2) DEFAULT 0 NOT NULL,
    remarks text,
    payment_mode character varying(50),
    category character varying(100),
    from_entity character varying(255),
    to_entity character varying(255),
    account_no character varying(100),
    branch character varying(255),
    created_by integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    farmer_payment_id integer,
    commission_id integer,
    cash_flow_entry_id integer,
    firm_transaction_id integer,
    plot_payment_id integer,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    approved_by integer,
    approved_at timestamp with time zone,
    imprest_allocation_id integer,
    assigned_user_id integer,
    voucher_url character varying(1000),
    vendor_payment_id integer,
    assigned_admin_id integer,
    cheque_status character varying(20) DEFAULT NULL::character varying,
    cheque_no character varying(50) DEFAULT NULL::character varying
);

CREATE TABLE public.day_book_daily_balance (
    id integer DEFAULT nextval('day_book_daily_balance_id_seq'::regclass) NOT NULL,
    site_id integer NOT NULL,
    date date NOT NULL,
    opening_balance numeric(14,2) DEFAULT 0 NOT NULL,
    closing_balance numeric(14,2) DEFAULT 0 NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE public.documents (
    id integer DEFAULT nextval('documents_id_seq'::regclass) NOT NULL,
    kyc_case_id integer,
    client_member_id integer,
    site_id integer,
    type character varying(40) DEFAULT 'OTHER'::character varying NOT NULL,
    file_path text NOT NULL,
    file_hash character varying(80),
    mime_type character varying(120),
    file_size integer,
    ocr_status character varying(20) DEFAULT 'PENDING'::character varying NOT NULL,
    ocr_job_id character varying(120),
    ocr_engine character varying(40),
    ocr_error text,
    ocr_started_at timestamp with time zone,
    ocr_completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    plot_id integer,
    original_name text,
    title text,
    category character varying(40),
    uploaded_source character varying(20) DEFAULT 'BOOKING'::character varying,
    uploaded_by integer
);

CREATE TABLE public.edit_requests (
    id integer DEFAULT nextval('edit_requests_id_seq'::regclass) NOT NULL,
    requested_by integer NOT NULL,
    site_id integer,
    module character varying(50) NOT NULL,
    record_id integer NOT NULL,
    original_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    proposed_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    proof_photo_url text,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    reviewed_by integer,
    reviewed_at timestamp without time zone,
    rejection_reason text,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now(),
    review_photo_url text
);

CREATE TABLE public.excel_files (
    id integer DEFAULT nextval('excel_files_id_seq'::regclass) NOT NULL,
    name character varying(255) DEFAULT 'Untitled Spreadsheet'::character varying NOT NULL,
    created_by integer,
    updated_by integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    s3_key character varying(255),
    size_bytes integer,
    folder_id integer,
    file_type character varying(20) DEFAULT 'excel'::character varying,
    site_id integer
);

CREATE TABLE public.expense_categories (
    id integer DEFAULT nextval('expense_categories_id_seq'::regclass) NOT NULL,
    name character varying(100) NOT NULL,
    icon character varying(50) DEFAULT 'Tag'::character varying,
    color character varying(30) DEFAULT 'slate'::character varying,
    grp character varying(80) DEFAULT 'Custom'::character varying,
    created_at timestamp without time zone DEFAULT now()
);

CREATE TABLE public.expenses (
    id integer DEFAULT nextval('expenses_id_seq'::regclass) NOT NULL,
    site_id integer NOT NULL,
    date date DEFAULT CURRENT_DATE NOT NULL,
    from_entity character varying(255),
    to_entity character varying(255),
    payment_mode character varying(50),
    debit numeric(15,2) DEFAULT 0 NOT NULL,
    credit numeric(15,2) DEFAULT 0 NOT NULL,
    remark text,
    account_no character varying(100),
    branch character varying(255),
    category character varying(100),
    created_by integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    approved_by integer,
    approved_at timestamp with time zone,
    assigned_user_id integer,
    voucher_url character varying(1000),
    assigned_admin_id integer,
    bill_url text,
    cheque_status character varying(20) DEFAULT NULL::character varying,
    cheque_no character varying(50) DEFAULT NULL::character varying
);

CREATE TABLE public.farmer_payments (
    id integer DEFAULT nextval('farmer_payments_id_seq'::regclass) NOT NULL,
    farmer_id integer NOT NULL,
    date date DEFAULT CURRENT_DATE NOT NULL,
    particular character varying(255) NOT NULL,
    amount numeric(15,2) DEFAULT 0 NOT NULL,
    by_note character varying(500),
    interest_rate numeric(5,2) DEFAULT 0,
    interest_amount numeric(15,2) DEFAULT 0,
    remarks text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    payment_mode character varying(20) DEFAULT 'CASH'::character varying,
    cash_amount numeric(15,2) DEFAULT 0,
    bank_amount numeric(15,2) DEFAULT 0,
    bank_name character varying(255),
    bank_account_no character varying(100),
    bank_reference character varying(255),
    bank_ifsc character varying(20),
    voucher_url character varying(1000),
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    approved_by integer,
    approved_at timestamp with time zone,
    assigned_admin_id integer,
    cheque_status character varying(20) DEFAULT NULL::character varying,
    cheque_no character varying(50) DEFAULT NULL::character varying,
    created_by integer
);

CREATE TABLE public.farmers (
    id integer DEFAULT nextval('farmers_id_seq'::regclass) NOT NULL,
    name character varying(255) NOT NULL,
    phone character varying(20),
    address text,
    total_amount numeric(15,2) DEFAULT 0 NOT NULL,
    interest_rate numeric(5,2) DEFAULT 0 NOT NULL,
    site_id integer,
    created_by integer,
    notes text,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    member_id integer,
    payment_mode character varying(10) DEFAULT 'CASH'::character varying,
    cash_amount numeric(15,2) DEFAULT 0,
    bank_amount numeric(15,2) DEFAULT 0,
    bank_name character varying(255),
    bank_account_no character varying(50),
    bank_reference character varying(100),
    bank_ifsc character varying(20),
    land_size_bigha numeric(10,2) DEFAULT NULL::numeric,
    land_rate numeric(15,2) DEFAULT NULL::numeric,
    commission_percentage numeric(5,2) DEFAULT NULL::numeric,
    commission_amount numeric(15,2) DEFAULT NULL::numeric
);

CREATE TABLE public.file_folders (
    id integer DEFAULT nextval('file_folders_id_seq'::regclass) NOT NULL,
    name character varying(255) NOT NULL,
    parent_id integer,
    created_by integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    site_id integer
);

CREATE TABLE public.firm_transactions (
    id integer DEFAULT nextval('firm_transactions_id_seq'::regclass) NOT NULL,
    firm_id integer NOT NULL,
    site_id integer NOT NULL,
    date date DEFAULT CURRENT_DATE NOT NULL,
    description text NOT NULL,
    debit numeric(15,2) DEFAULT 0 NOT NULL,
    credit numeric(15,2) DEFAULT 0 NOT NULL,
    name character varying(255),
    purpose character varying(500),
    remark character varying(100),
    cheque_no character varying(50),
    created_by integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    cash_flow_entry_id integer,
    voucher_url character varying(1000),
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    approved_by integer,
    approved_at timestamp with time zone,
    payment_mode character varying(20) DEFAULT 'cash'::character varying NOT NULL,
    assigned_admin_id integer,
    is_firm_to_firm_transfer boolean DEFAULT false NOT NULL,
    transfer_to_site_id integer,
    transfer_to_firm_id integer,
    transfer_group_id character varying(80),
    transfer_direction character varying(10),
    transaction_no character varying(50),
    cheque_status character varying(20) DEFAULT NULL::character varying,
    remark2 character varying(255)
);

CREATE TABLE public.firms (
    id integer DEFAULT nextval('firms_id_seq'::regclass) NOT NULL,
    site_id integer NOT NULL,
    name character varying(255) NOT NULL,
    account_number character varying(50),
    bank_name character varying(255),
    ifsc_code character varying(20),
    notes text,
    created_by integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    opening_balance numeric(15,2) DEFAULT 0 NOT NULL
);

CREATE TABLE public.imprest_allocations (
    id integer DEFAULT nextval('imprest_allocations_id_seq'::regclass) NOT NULL,
    admin_id integer NOT NULL,
    sub_admin_id integer NOT NULL,
    amount numeric(15,2) NOT NULL,
    remark text,
    status character varying(30) DEFAULT 'PENDING_RECEIPT'::character varying NOT NULL,
    confirmation_remark text,
    created_at timestamp with time zone DEFAULT now(),
    confirmed_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now(),
    assigned_admin_id integer,
    site_id integer
);

CREATE TABLE public.imprest_expense_requests (
    id integer DEFAULT nextval('imprest_expense_requests_id_seq'::regclass) NOT NULL,
    sub_admin_id integer NOT NULL,
    site_id integer NOT NULL,
    amount numeric(15,2) NOT NULL,
    expense_data jsonb NOT NULL,
    reason text,
    status character varying(30) DEFAULT 'PENDING'::character varying NOT NULL,
    reviewed_by integer,
    reviewed_at timestamp with time zone,
    review_remark text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    assigned_admin_id integer,
    request_type character varying(20) DEFAULT 'EXPENSE'::character varying NOT NULL
);

CREATE TABLE public.imprest_ledger (
    id integer DEFAULT nextval('imprest_ledger_id_seq'::regclass) NOT NULL,
    user_id integer NOT NULL,
    type character varying(30) NOT NULL,
    reference_id integer,
    amount numeric(15,2) NOT NULL,
    balance_after numeric(15,2) DEFAULT 0 NOT NULL,
    remarks text,
    created_by integer,
    created_at timestamp with time zone DEFAULT now(),
    site_id integer
);

CREATE TABLE public.imprest_returns (
    id integer DEFAULT nextval('imprest_returns_id_seq'::regclass) NOT NULL,
    sub_admin_id integer NOT NULL,
    amount numeric(15,2) NOT NULL,
    reason text,
    payment_mode character varying(30) DEFAULT 'CASH'::character varying,
    status character varying(30) DEFAULT 'PENDING'::character varying NOT NULL,
    reviewed_by integer,
    reviewed_at timestamp with time zone,
    review_remark text,
    site_id integer,
    assigned_admin_id integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);

CREATE TABLE public.kyc_cases (
    id integer DEFAULT nextval('kyc_cases_id_seq'::regclass) NOT NULL,
    booking_id integer NOT NULL,
    client_member_id integer,
    site_id integer,
    mode character varying(20) DEFAULT 'MANUAL_OCR'::character varying NOT NULL,
    status character varying(20) DEFAULT 'OPEN'::character varying NOT NULL,
    verified_by integer,
    verified_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE public.member_categories (
    id integer DEFAULT nextval('member_categories_id_seq'::regclass) NOT NULL,
    name character varying(100) NOT NULL,
    slug character varying(100) NOT NULL,
    description text,
    is_predefined boolean DEFAULT false,
    icon character varying(50),
    color character varying(50),
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);

CREATE TABLE public.members (
    id integer DEFAULT nextval('members_id_seq'::regclass) NOT NULL,
    site_id integer NOT NULL,
    member_type character varying(30) DEFAULT 'CLIENT'::character varying NOT NULL,
    full_name character varying(255) NOT NULL,
    father_name character varying(255),
    photo character varying(500),
    gender character varying(10),
    date_of_birth date,
    blood_group character varying(5),
    phone character varying(20),
    alt_phone character varying(20),
    email character varying(255),
    whatsapp character varying(20),
    address text,
    city character varying(100),
    state character varying(100),
    pincode character varying(10),
    aadhar_no character varying(20),
    pan_no character varying(15),
    voter_id character varying(30),
    bank_name character varying(100),
    account_no character varying(30),
    ifsc_code character varying(15),
    branch character varying(100),
    occupation character varying(100),
    company_name character varying(255),
    reference character varying(255),
    notes text,
    status character varying(20) DEFAULT 'ACTIVE'::character varying NOT NULL,
    created_by integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    mother_name character varying(255),
    spouse_name character varying(255),
    nationality character varying(50) DEFAULT 'INDIAN'::character varying,
    religion character varying(50),
    caste character varying(100),
    marital_status character varying(20),
    anniversary_date date,
    qualification character varying(100),
    passport_no character varying(20),
    driving_license_no character varying(30),
    gst_no character varying(20),
    tin_no character varying(20),
    emergency_contact_name character varying(255),
    emergency_contact_phone character varying(20),
    emergency_contact_relation character varying(50),
    nominee_name character varying(255),
    nominee_relation character varying(50),
    nominee_phone character varying(20),
    employee_id character varying(50),
    designation character varying(100),
    department character varying(100),
    date_of_joining date,
    salary numeric(15,2),
    employment_type character varying(30),
    resume_url character varying(500),
    marksheet_10th_url character varying(500),
    marksheet_12th_url character varying(500),
    degree_certificate_url character varying(500),
    experience_certificate_url character varying(500),
    offer_letter_url character varying(500),
    other_certificate_url character varying(500),
    aadhar_front_url character varying(500),
    aadhar_back_url character varying(500),
    pan_card_url character varying(500),
    voter_id_url character varying(500),
    passport_url character varying(500),
    driving_license_url character varying(500),
    cheque_url character varying(500),
    other_kyc_url character varying(500),
    land_area character varying(100),
    crop_type character varying(200),
    farm_location character varying(200),
    irrigation_type character varying(100),
    farming_experience character varying(50),
    license_number character varying(100),
    commission_rate character varying(50),
    operating_areas text,
    business_name character varying(200),
    service_type character varying(200),
    payment_terms character varying(200),
    team character varying(50)
);

CREATE TABLE public.messages (
    id integer DEFAULT nextval('messages_id_seq'::regclass) NOT NULL,
    conversation_id integer,
    sender_id integer,
    message_text text,
    attachment_url text,
    is_read boolean DEFAULT false,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE public.ocr_results (
    id integer DEFAULT nextval('ocr_results_id_seq'::regclass) NOT NULL,
    document_id integer NOT NULL,
    raw_text jsonb,
    extracted_fields jsonb,
    confidence_overall numeric(6,3),
    confidence_map jsonb,
    engine character varying(40),
    processed_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE public.plot_commission_payments (
    id integer DEFAULT nextval('plot_commission_payments_id_seq'::regclass) NOT NULL,
    site_id integer,
    plot_commission_id integer,
    date date DEFAULT CURRENT_DATE NOT NULL,
    amount numeric(12,2) DEFAULT 0 NOT NULL,
    balance_after_payment numeric(12,2) DEFAULT 0 NOT NULL,
    payment_mode character varying(20) DEFAULT 'CASH'::character varying,
    bank_name character varying(100),
    transaction_id character varying(100),
    remarks text,
    status character varying(20) DEFAULT 'pending'::character varying,
    voucher_number character varying(50),
    voucher_url text,
    created_by integer,
    approved_by integer,
    approved_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    assigned_admin_id integer,
    cheque_status character varying(20) DEFAULT NULL::character varying,
    cheque_no character varying(50) DEFAULT NULL::character varying
);

CREATE TABLE public.plot_commissions (
    id integer DEFAULT nextval('plot_commissions_id_seq'::regclass) NOT NULL,
    site_id integer NOT NULL,
    date date DEFAULT CURRENT_DATE NOT NULL,
    particular character varying(255) NOT NULL,
    plot_no character varying(50),
    amount numeric(15,2) DEFAULT 0 NOT NULL,
    by_note character varying(500),
    remarks text,
    created_by integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    plot_size character varying(50),
    plot_rate character varying(50),
    father_name character varying(255),
    voucher_url character varying(1000),
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    approved_by integer,
    approved_at timestamp with time zone,
    assigned_admin_id integer,
    cheque_status character varying(20) DEFAULT NULL::character varying,
    cheque_no character varying(50) DEFAULT NULL::character varying
);

CREATE TABLE public.plot_commissions_v2 (
    id integer DEFAULT nextval('plot_commissions_v2_id_seq'::regclass) NOT NULL,
    site_id integer,
    plot_id integer,
    agent_id integer,
    total_commission numeric(12,2) DEFAULT 0 NOT NULL,
    remarks text,
    status character varying(20) DEFAULT 'Pending'::character varying,
    created_by integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE public.plot_installment_payments (
    id integer DEFAULT nextval('plot_installment_payments_id_seq'::regclass) NOT NULL,
    installment_id integer NOT NULL,
    plot_id integer NOT NULL,
    amount numeric(15,2) DEFAULT 0 NOT NULL,
    payment_date date DEFAULT CURRENT_DATE NOT NULL,
    payment_mode character varying(50),
    reference character varying(255),
    notes text,
    created_by integer,
    created_at timestamp with time zone DEFAULT now(),
    cheque_status character varying(20) DEFAULT NULL::character varying,
    cheque_no character varying(50) DEFAULT NULL::character varying
);

CREATE TABLE public.plot_installments (
    id integer DEFAULT nextval('plot_installments_id_seq'::regclass) NOT NULL,
    plot_id integer NOT NULL,
    installment_name character varying(255),
    amount numeric(15,2) DEFAULT 0 NOT NULL,
    due_date date NOT NULL,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    paid_amount numeric(15,2) DEFAULT 0 NOT NULL,
    interest_amount numeric(15,2) DEFAULT 0 NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);

CREATE TABLE public.plot_payments (
    id integer DEFAULT nextval('plot_payments_id_seq'::regclass) NOT NULL,
    plot_id integer NOT NULL,
    site_id integer NOT NULL,
    date date DEFAULT CURRENT_DATE NOT NULL,
    payment_from character varying(100),
    bank_details character varying(255),
    narration text,
    received_by character varying(255),
    amount numeric(15,2) DEFAULT 0 NOT NULL,
    created_by integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    payment_type character varying(20) DEFAULT 'CASH'::character varying,
    voucher_url character varying(1000),
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    approved_by integer,
    approved_at timestamp with time zone,
    assigned_admin_id integer,
    bank_name character varying(150),
    branch character varying(150),
    cheque_status character varying(20) DEFAULT NULL::character varying,
    cheque_no character varying(50) DEFAULT NULL::character varying,
    buyer_name character varying(255),
    booked_by character varying(255)
);

CREATE TABLE public.plot_registries (
    id integer DEFAULT nextval('plot_registries_id_seq'::regclass) NOT NULL,
    site_id integer NOT NULL,
    plot_no character varying(50) NOT NULL,
    customer_name character varying(255),
    size_meter numeric(10,2),
    size_sqyard numeric(10,2),
    registry_date date,
    farmer_name character varying(255),
    registry_payment numeric(15,2) DEFAULT 0,
    notes text,
    created_by integer,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now(),
    assigned_admin_id integer,
    plot_id integer,
    circle_rate numeric DEFAULT 0,
    firm_name character varying(255),
    seller_name character varying(255),
    created_entry_date date,
    bank_amount numeric DEFAULT 0
);

CREATE TABLE public.plot_registry_payments (
    id integer DEFAULT nextval('plot_registry_payments_id_seq'::regclass) NOT NULL,
    registry_id integer NOT NULL,
    site_id integer NOT NULL,
    payment_date date,
    amount numeric(15,2) DEFAULT 0,
    payment_mode character varying(50),
    tally_date date,
    tally_amount numeric(15,2),
    notes text,
    created_by integer,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now(),
    assigned_admin_id integer,
    source_plot_payment_id integer,
    cheque_status character varying(20) DEFAULT NULL::character varying,
    cheque_no character varying(50) DEFAULT NULL::character varying
);

CREATE TABLE public.plots (
    id integer DEFAULT nextval('plots_id_seq'::regclass) NOT NULL,
    site_id integer NOT NULL,
    plot_no character varying(20) NOT NULL,
    block character varying(10),
    buyer_name character varying(255),
    plot_size numeric(10,2),
    plot_rate numeric(15,2),
    sale_price numeric(15,2) DEFAULT 0 NOT NULL,
    booking_by character varying(255),
    booking_date date,
    status character varying(50) DEFAULT 'BOOKED'::character varying,
    notes text,
    created_by integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    registry_area numeric(10,2) DEFAULT 0,
    circle_rate numeric(15,2) DEFAULT 0,
    to_receive_bank numeric(15,2) DEFAULT 0,
    first_installment numeric(15,2) DEFAULT 0,
    plc_charges numeric(15,2) DEFAULT 0,
    team character varying(10),
    installments_enabled boolean DEFAULT false NOT NULL,
    interest_enabled boolean DEFAULT false NOT NULL,
    interest_rate numeric(8,4) DEFAULT 0,
    interest_type character varying(20) DEFAULT 'per_month'::character varying,
    assigned_admin_id integer,
    commission_enabled boolean DEFAULT false NOT NULL,
    commission_type character varying(20) DEFAULT 'PERCENTAGE'::character varying NOT NULL,
    commission_value numeric(15,2) DEFAULT 0 NOT NULL,
    plot_size_mtr numeric(10,2),
    commission_rate numeric(15,2) DEFAULT 0,
    plot_commission numeric(15,2) DEFAULT 0,
    original_plot_rate numeric(15,2) DEFAULT 0,
    discount_rate numeric(15,2) DEFAULT 0,
    penalty_enabled boolean DEFAULT false NOT NULL,
    penalty_rate numeric(10,4) DEFAULT 0,
    penalty_type character varying(20) DEFAULT 'per_day'::character varying,
    free_to_sale_days integer DEFAULT 0,
    plot_tag character varying(20)
);

CREATE TABLE public.project_settings (
    id integer DEFAULT nextval('project_settings_id_seq'::regclass) NOT NULL,
    site_id integer,
    company_legal_name character varying(255),
    company_brand_name character varying(255),
    company_address text,
    company_city character varying(160),
    company_phone character varying(60),
    company_email character varying(160),
    company_gstin character varying(40),
    company_website character varying(160),
    payable_to character varying(160),
    logo_url character varying(500),
    bank_name character varying(160),
    bank_account_no character varying(60),
    bank_ifsc character varying(40),
    bank_branch character varying(160),
    payment_terms text,
    milestones jsonb DEFAULT '[]'::jsonb,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);

CREATE TABLE public.sites (
    id integer DEFAULT nextval('sites_id_seq'::regclass) NOT NULL,
    name character varying(255) NOT NULL,
    code character varying(50),
    address text,
    city character varying(100),
    state character varying(100),
    description text,
    status character varying(20) DEFAULT 'active'::character varying NOT NULL,
    created_by integer,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);

CREATE TABLE public.team_members (
    team_id integer NOT NULL,
    user_id integer NOT NULL,
    is_head boolean DEFAULT false NOT NULL,
    joined_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.teams (
    id integer DEFAULT nextval('teams_id_seq'::regclass) NOT NULL,
    name text NOT NULL,
    site_id integer,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    created_by integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.user_approval_modules (
    id integer DEFAULT nextval('user_approval_modules_id_seq'::regclass) NOT NULL,
    user_id integer NOT NULL,
    module character varying(50) NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);

CREATE TABLE public.user_permissions (
    id integer DEFAULT nextval('user_permissions_id_seq'::regclass) NOT NULL,
    user_id integer NOT NULL,
    module character varying(50) NOT NULL,
    can_read boolean DEFAULT true,
    can_write boolean DEFAULT true,
    can_update boolean DEFAULT true,
    can_delete boolean DEFAULT false,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);

CREATE TABLE public.user_sessions (
    id integer DEFAULT nextval('user_sessions_id_seq'::regclass) NOT NULL,
    user_id integer,
    login_time timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    logout_time timestamp with time zone,
    ip_address character varying(45)
);

CREATE TABLE public.user_sites (
    id integer DEFAULT nextval('user_sites_id_seq'::regclass) NOT NULL,
    user_id integer NOT NULL,
    site_id integer NOT NULL,
    assigned_at timestamp with time zone DEFAULT now()
);

CREATE TABLE public.users (
    id integer DEFAULT nextval('users_id_seq'::regclass) NOT NULL,
    name character varying(255) NOT NULL,
    email character varying(255) NOT NULL,
    password character varying(255) NOT NULL,
    phone character varying(20),
    photo character varying(500),
    role character varying(20) DEFAULT 'sub_admin'::character varying NOT NULL,
    created_by integer,
    is_active boolean DEFAULT true,
    refresh_token character varying(500),
    token_version integer DEFAULT 1,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    parent_user_id integer,
    referral_code text,
    designation text,
    agent_status text DEFAULT 'ACTIVE'::text NOT NULL,
    team_id integer,
    can_register_agents boolean DEFAULT false NOT NULL
);

CREATE TABLE public.vendor_commitments (
    id integer DEFAULT nextval('vendor_commitments_id_seq'::regclass) NOT NULL,
    site_id integer NOT NULL,
    vendor_member_id integer,
    vendor_name character varying(200) NOT NULL,
    head_id integer,
    head_name character varying(120),
    work_title character varying(220) NOT NULL,
    contract_amount numeric(14,2) DEFAULT 0 NOT NULL,
    start_date date,
    due_date date,
    note text,
    status character varying(20) DEFAULT 'open'::character varying NOT NULL,
    created_by integer,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    assigned_admin_id integer
);

CREATE TABLE public.vendor_heads (
    id integer DEFAULT nextval('vendor_heads_id_seq'::regclass) NOT NULL,
    site_id integer NOT NULL,
    name character varying(120) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by integer,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE public.vendor_inventory_deliveries (
    id integer DEFAULT nextval('vendor_inventory_deliveries_id_seq'::regclass) NOT NULL,
    order_id integer NOT NULL,
    site_id integer NOT NULL,
    delivery_date date NOT NULL,
    qty numeric(14,3) NOT NULL,
    note text,
    created_by integer,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE public.vendor_inventory_orders (
    id integer DEFAULT nextval('vendor_inventory_orders_id_seq'::regclass) NOT NULL,
    site_id integer NOT NULL,
    vendor_member_id integer,
    vendor_name character varying(200) NOT NULL,
    item_name character varying(200) NOT NULL,
    item_category character varying(120),
    unit character varying(40) DEFAULT 'pcs'::character varying NOT NULL,
    qty_ordered numeric(14,3) DEFAULT 0 NOT NULL,
    qty_received numeric(14,3) DEFAULT 0 NOT NULL,
    rate numeric(14,4) DEFAULT 0 NOT NULL,
    discount_pct numeric(6,3) DEFAULT 0 NOT NULL,
    discount_amount numeric(14,2) DEFAULT 0 NOT NULL,
    gross_amount numeric(14,2) GENERATED ALWAYS AS (round((qty_received * rate), 2)) STORED,
    net_amount numeric(14,2) GENERATED ALWAYS AS (round(((qty_received * rate) - COALESCE(
CASE
    WHEN (discount_pct > (0)::numeric) THEN round((((qty_received * rate) * discount_pct) / (100)::numeric), 2)
    ELSE discount_amount
END, (0)::numeric)), 2)) STORED,
    total_paid numeric(14,2) DEFAULT 0 NOT NULL,
    order_date date NOT NULL,
    expected_date date,
    note text,
    status character varying(20) DEFAULT 'open'::character varying NOT NULL,
    created_by integer,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    commitment_id integer
);

CREATE TABLE public.vendor_inventory_payments (
    id integer DEFAULT nextval('vendor_inventory_payments_id_seq'::regclass) NOT NULL,
    order_id integer NOT NULL,
    site_id integer NOT NULL,
    payment_date date NOT NULL,
    amount numeric(14,2) NOT NULL,
    payment_mode character varying(20) DEFAULT 'cash'::character varying NOT NULL,
    reference_no character varying(120),
    cheque_no character varying(50),
    note text,
    voucher_url text,
    created_by integer,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE public.vendor_payments (
    id integer DEFAULT nextval('vendor_payments_id_seq'::regclass) NOT NULL,
    commitment_id integer NOT NULL,
    site_id integer NOT NULL,
    payment_date date NOT NULL,
    amount numeric(14,2) NOT NULL,
    payment_mode character varying(20) DEFAULT 'cash'::character varying NOT NULL,
    reference_no character varying(120),
    note text,
    voucher_url text,
    created_by integer,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    approved_by integer,
    approved_at timestamp with time zone,
    assigned_admin_id integer,
    cheque_status character varying(20) DEFAULT NULL::character varying,
    cheque_no character varying(50) DEFAULT NULL::character varying
);

-- ===================== SEQUENCE OWNERSHIP ==========================
ALTER SEQUENCE public.agent_activity_log_id_seq OWNED BY public.agent_activity_log.id;
ALTER SEQUENCE public.agent_ledger_entries_id_seq OWNED BY public.agent_ledger_entries.id;
ALTER SEQUENCE public.bookings_id_seq OWNED BY public.bookings.id;
ALTER SEQUENCE public.cash_flow_entries_id_seq OWNED BY public.cash_flow_entries.id;
ALTER SEQUENCE public.cash_flow_months_id_seq OWNED BY public.cash_flow_months.id;
ALTER SEQUENCE public.conversations_id_seq OWNED BY public.conversations.id;
ALTER SEQUENCE public.dashboard_component_permissions_id_seq OWNED BY public.dashboard_component_permissions.id;
ALTER SEQUENCE public.day_book_daily_balance_id_seq OWNED BY public.day_book_daily_balance.id;
ALTER SEQUENCE public.day_book_id_seq OWNED BY public.day_book.id;
ALTER SEQUENCE public.documents_id_seq OWNED BY public.documents.id;
ALTER SEQUENCE public.edit_requests_id_seq OWNED BY public.edit_requests.id;
ALTER SEQUENCE public.excel_files_id_seq OWNED BY public.excel_files.id;
ALTER SEQUENCE public.expense_categories_id_seq OWNED BY public.expense_categories.id;
ALTER SEQUENCE public.expenses_id_seq OWNED BY public.expenses.id;
ALTER SEQUENCE public.farmer_payments_id_seq OWNED BY public.farmer_payments.id;
ALTER SEQUENCE public.farmers_id_seq OWNED BY public.farmers.id;
ALTER SEQUENCE public.file_folders_id_seq OWNED BY public.file_folders.id;
ALTER SEQUENCE public.firm_transactions_id_seq OWNED BY public.firm_transactions.id;
ALTER SEQUENCE public.firms_id_seq OWNED BY public.firms.id;
ALTER SEQUENCE public.imprest_allocations_id_seq OWNED BY public.imprest_allocations.id;
ALTER SEQUENCE public.imprest_expense_requests_id_seq OWNED BY public.imprest_expense_requests.id;
ALTER SEQUENCE public.imprest_ledger_id_seq OWNED BY public.imprest_ledger.id;
ALTER SEQUENCE public.imprest_returns_id_seq OWNED BY public.imprest_returns.id;
ALTER SEQUENCE public.kyc_cases_id_seq OWNED BY public.kyc_cases.id;
ALTER SEQUENCE public.member_categories_id_seq OWNED BY public.member_categories.id;
ALTER SEQUENCE public.members_id_seq OWNED BY public.members.id;
ALTER SEQUENCE public.messages_id_seq OWNED BY public.messages.id;
ALTER SEQUENCE public.ocr_results_id_seq OWNED BY public.ocr_results.id;
ALTER SEQUENCE public.plot_commission_payments_id_seq OWNED BY public.plot_commission_payments.id;
ALTER SEQUENCE public.plot_commissions_id_seq OWNED BY public.plot_commissions.id;
ALTER SEQUENCE public.plot_commissions_v2_id_seq OWNED BY public.plot_commissions_v2.id;
ALTER SEQUENCE public.plot_installment_payments_id_seq OWNED BY public.plot_installment_payments.id;
ALTER SEQUENCE public.plot_installments_id_seq OWNED BY public.plot_installments.id;
ALTER SEQUENCE public.plot_payments_id_seq OWNED BY public.plot_payments.id;
ALTER SEQUENCE public.plot_registries_id_seq OWNED BY public.plot_registries.id;
ALTER SEQUENCE public.plot_registry_payments_id_seq OWNED BY public.plot_registry_payments.id;
ALTER SEQUENCE public.plots_id_seq OWNED BY public.plots.id;
ALTER SEQUENCE public.project_settings_id_seq OWNED BY public.project_settings.id;
ALTER SEQUENCE public.sites_id_seq OWNED BY public.sites.id;
ALTER SEQUENCE public.teams_id_seq OWNED BY public.teams.id;
ALTER SEQUENCE public.user_approval_modules_id_seq OWNED BY public.user_approval_modules.id;
ALTER SEQUENCE public.user_permissions_id_seq OWNED BY public.user_permissions.id;
ALTER SEQUENCE public.user_sessions_id_seq OWNED BY public.user_sessions.id;
ALTER SEQUENCE public.user_sites_id_seq OWNED BY public.user_sites.id;
ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;
ALTER SEQUENCE public.vendor_commitments_id_seq OWNED BY public.vendor_commitments.id;
ALTER SEQUENCE public.vendor_heads_id_seq OWNED BY public.vendor_heads.id;
ALTER SEQUENCE public.vendor_inventory_deliveries_id_seq OWNED BY public.vendor_inventory_deliveries.id;
ALTER SEQUENCE public.vendor_inventory_orders_id_seq OWNED BY public.vendor_inventory_orders.id;
ALTER SEQUENCE public.vendor_inventory_payments_id_seq OWNED BY public.vendor_inventory_payments.id;
ALTER SEQUENCE public.vendor_payments_id_seq OWNED BY public.vendor_payments.id;

-- ================= PRIMARY / UNIQUE / CHECK CONSTRAINTS =============
ALTER TABLE public.agent_activity_log ADD CONSTRAINT agent_activity_log_pkey PRIMARY KEY (id);
ALTER TABLE public.agent_ledger_entries ADD CONSTRAINT agent_ledger_entries_pkey PRIMARY KEY (id);
ALTER TABLE public.agent_ledger_entries ADD CONSTRAINT agent_ledger_entries_amount_check CHECK ((amount >= (0)::numeric));
ALTER TABLE public.agent_ledger_entries ADD CONSTRAINT agent_ledger_entries_direction_check CHECK ((direction = ANY (ARRAY['CREDIT'::text, 'DEBIT'::text])));
ALTER TABLE public.bookings ADD CONSTRAINT bookings_booking_no_key UNIQUE (booking_no);
ALTER TABLE public.bookings ADD CONSTRAINT bookings_pkey PRIMARY KEY (id);
ALTER TABLE public.bookings ADD CONSTRAINT bookings_kyc_status_check CHECK (((kyc_status)::text = ANY ((ARRAY['NOT_STARTED'::character varying, 'OCR_PENDING'::character varying, 'OCR_DONE'::character varying, 'VERIFIED'::character varying, 'REJECTED'::character varying])::text[])));
ALTER TABLE public.bookings ADD CONSTRAINT bookings_payment_plan_check CHECK (((payment_plan)::text = ANY ((ARRAY['FULL'::character varying, 'INSTALLMENT'::character varying])::text[])));
ALTER TABLE public.bookings ADD CONSTRAINT bookings_status_check CHECK (((status)::text = ANY ((ARRAY['DRAFT'::character varying, 'KYC_PENDING'::character varying, 'KYC_DONE'::character varying, 'CONFIRMED'::character varying, 'CANCELLED'::character varying])::text[])));
ALTER TABLE public.cash_flow_entries ADD CONSTRAINT cash_flow_entries_pkey PRIMARY KEY (id);
ALTER TABLE public.cash_flow_entries ADD CONSTRAINT cash_flow_entries_cash_type_check CHECK (((cash_type)::text = ANY ((ARRAY['cash'::character varying, 'bank'::character varying, 'cheque'::character varying])::text[])));
ALTER TABLE public.cash_flow_months ADD CONSTRAINT cash_flow_months_site_month_year_name_key UNIQUE (site_id, month, year, ledger_name);
ALTER TABLE public.cash_flow_months ADD CONSTRAINT cash_flow_months_pkey PRIMARY KEY (id);
ALTER TABLE public.cash_flow_months ADD CONSTRAINT cash_flow_months_ledger_type_check CHECK (((ledger_type)::text = ANY ((ARRAY['site'::character varying, 'person'::character varying])::text[])));
ALTER TABLE public.cash_flow_months ADD CONSTRAINT cash_flow_months_month_check CHECK (((month >= 1) AND (month <= 12)));
ALTER TABLE public.conversations ADD CONSTRAINT conversations_user1_id_user2_id_key UNIQUE (user1_id, user2_id);
ALTER TABLE public.conversations ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);
ALTER TABLE public.dashboard_component_permissions ADD CONSTRAINT dashboard_component_permissions_user_id_component_key UNIQUE (user_id, component);
ALTER TABLE public.dashboard_component_permissions ADD CONSTRAINT dashboard_component_permissions_pkey PRIMARY KEY (id);
ALTER TABLE public.day_book ADD CONSTRAINT day_book_pkey PRIMARY KEY (id);
ALTER TABLE public.day_book ADD CONSTRAINT day_book_entry_type_check CHECK (((entry_type)::text = ANY ((ARRAY['GENERAL'::character varying, 'EXPENSE'::character varying, 'INCOME'::character varying, 'PAYMENT'::character varying, 'RECEIPT'::character varying, 'TRANSFER'::character varying, 'ADJUSTMENT'::character varying, 'OTHER'::character varying, 'FARMER PAYMENT'::character varying, 'PLOT COMMISSION'::character varying, 'CASH FLOW'::character varying, 'FIRM TRANSACTION'::character varying, 'PLOT PAYMENT'::character varying, 'IMPREST'::character varying, 'VENDOR PAYMENT'::character varying])::text[])));
ALTER TABLE public.day_book ADD CONSTRAINT day_book_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'approved'::character varying, 'rejected'::character varying])::text[])));
ALTER TABLE public.day_book_daily_balance ADD CONSTRAINT day_book_daily_balance_site_id_date_key UNIQUE (site_id, date);
ALTER TABLE public.day_book_daily_balance ADD CONSTRAINT day_book_daily_balance_pkey PRIMARY KEY (id);
ALTER TABLE public.documents ADD CONSTRAINT documents_pkey PRIMARY KEY (id);
ALTER TABLE public.documents ADD CONSTRAINT documents_ocr_status_check CHECK (((ocr_status)::text = ANY ((ARRAY['PENDING'::character varying, 'PROCESSING'::character varying, 'DONE'::character varying, 'FAILED'::character varying])::text[])));
ALTER TABLE public.documents ADD CONSTRAINT documents_type_check CHECK (((type)::text = ANY ((ARRAY['AADHAAR'::character varying, 'PAN'::character varying, 'PHOTO'::character varying, 'CHEQUE'::character varying, 'VOTER_ID'::character varying, 'PASSPORT'::character varying, 'DL'::character varying, 'DOMICILE'::character varying, 'INCOME'::character varying, 'FINAL_APPROVED_BOOKED_FORM'::character varying, 'OTHER'::character varying])::text[])));
ALTER TABLE public.edit_requests ADD CONSTRAINT edit_requests_pkey PRIMARY KEY (id);
ALTER TABLE public.excel_files ADD CONSTRAINT excel_files_pkey PRIMARY KEY (id);
ALTER TABLE public.expense_categories ADD CONSTRAINT expense_categories_name_key UNIQUE (name);
ALTER TABLE public.expense_categories ADD CONSTRAINT expense_categories_pkey PRIMARY KEY (id);
ALTER TABLE public.expenses ADD CONSTRAINT expenses_pkey PRIMARY KEY (id);
ALTER TABLE public.expenses ADD CONSTRAINT expenses_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'approved'::character varying, 'rejected'::character varying])::text[])));
ALTER TABLE public.farmer_payments ADD CONSTRAINT farmer_payments_pkey PRIMARY KEY (id);
ALTER TABLE public.farmers ADD CONSTRAINT farmers_pkey PRIMARY KEY (id);
ALTER TABLE public.farmers ADD CONSTRAINT farmers_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'completed'::character varying, 'inactive'::character varying])::text[])));
ALTER TABLE public.file_folders ADD CONSTRAINT file_folders_pkey PRIMARY KEY (id);
ALTER TABLE public.firm_transactions ADD CONSTRAINT firm_transactions_pkey PRIMARY KEY (id);
ALTER TABLE public.firm_transactions ADD CONSTRAINT firm_transactions_payment_mode_check CHECK (((payment_mode)::text = ANY ((ARRAY['cash'::character varying, 'bank'::character varying, 'cheque'::character varying])::text[])));
ALTER TABLE public.firm_transactions ADD CONSTRAINT firm_transactions_transfer_direction_check CHECK (((transfer_direction IS NULL) OR ((transfer_direction)::text = ANY ((ARRAY['OUT'::character varying, 'IN'::character varying])::text[]))));
ALTER TABLE public.firms ADD CONSTRAINT firms_site_id_name_key UNIQUE (site_id, name);
ALTER TABLE public.firms ADD CONSTRAINT firms_pkey PRIMARY KEY (id);
ALTER TABLE public.imprest_allocations ADD CONSTRAINT imprest_allocations_pkey PRIMARY KEY (id);
ALTER TABLE public.imprest_allocations ADD CONSTRAINT imprest_allocations_status_check CHECK (((status)::text = ANY ((ARRAY['PENDING_RECEIPT'::character varying, 'RECEIVED'::character varying, 'CANCELLED'::character varying])::text[])));
ALTER TABLE public.imprest_expense_requests ADD CONSTRAINT imprest_expense_requests_pkey PRIMARY KEY (id);
ALTER TABLE public.imprest_expense_requests ADD CONSTRAINT imprest_expense_requests_request_type_check CHECK (((request_type)::text = ANY ((ARRAY['IMPREST'::character varying, 'EXPENSE'::character varying])::text[])));
ALTER TABLE public.imprest_expense_requests ADD CONSTRAINT imprest_expense_requests_status_check CHECK (((status)::text = ANY ((ARRAY['PENDING'::character varying, 'APPROVED'::character varying, 'REJECTED'::character varying])::text[])));
ALTER TABLE public.imprest_ledger ADD CONSTRAINT imprest_ledger_pkey PRIMARY KEY (id);
ALTER TABLE public.imprest_ledger ADD CONSTRAINT imprest_ledger_type_check CHECK (((type)::text = ANY ((ARRAY['ALLOCATION'::character varying, 'EXPENSE'::character varying, 'ADJUSTMENT'::character varying, 'REFUND'::character varying])::text[])));
ALTER TABLE public.imprest_returns ADD CONSTRAINT imprest_returns_pkey PRIMARY KEY (id);
ALTER TABLE public.imprest_returns ADD CONSTRAINT imprest_returns_status_check CHECK (((status)::text = ANY ((ARRAY['PENDING'::character varying, 'ACCEPTED'::character varying, 'REJECTED'::character varying])::text[])));
ALTER TABLE public.kyc_cases ADD CONSTRAINT kyc_cases_pkey PRIMARY KEY (id);
ALTER TABLE public.kyc_cases ADD CONSTRAINT kyc_cases_mode_check CHECK (((mode)::text = ANY ((ARRAY['MANUAL_OCR'::character varying, 'AADHAAR_EKYC'::character varying])::text[])));
ALTER TABLE public.kyc_cases ADD CONSTRAINT kyc_cases_status_check CHECK (((status)::text = ANY ((ARRAY['OPEN'::character varying, 'OCR_PENDING'::character varying, 'OCR_DONE'::character varying, 'VERIFIED'::character varying, 'REJECTED'::character varying])::text[])));
ALTER TABLE public.member_categories ADD CONSTRAINT member_categories_slug_key UNIQUE (slug);
ALTER TABLE public.member_categories ADD CONSTRAINT member_categories_pkey PRIMARY KEY (id);
ALTER TABLE public.members ADD CONSTRAINT members_pkey PRIMARY KEY (id);
ALTER TABLE public.members ADD CONSTRAINT members_gender_check CHECK (((gender)::text = ANY ((ARRAY['MALE'::character varying, 'FEMALE'::character varying, 'OTHER'::character varying])::text[])));
ALTER TABLE public.members ADD CONSTRAINT members_member_type_check CHECK (((member_type)::text = ANY ((ARRAY['CLIENT'::character varying, 'FARMER'::character varying, 'MEMBER'::character varying, 'BROKER'::character varying, 'PARTNER'::character varying, 'VENDOR'::character varying, 'EMPLOYEE'::character varying, 'OTHER'::character varying])::text[])));
ALTER TABLE public.members ADD CONSTRAINT members_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying, 'BLOCKED'::character varying])::text[])));
ALTER TABLE public.messages ADD CONSTRAINT messages_pkey PRIMARY KEY (id);
ALTER TABLE public.ocr_results ADD CONSTRAINT ocr_results_pkey PRIMARY KEY (id);
ALTER TABLE public.plot_commission_payments ADD CONSTRAINT plot_commission_payments_voucher_number_key UNIQUE (voucher_number);
ALTER TABLE public.plot_commission_payments ADD CONSTRAINT plot_commission_payments_pkey PRIMARY KEY (id);
ALTER TABLE public.plot_commissions ADD CONSTRAINT plot_commissions_pkey PRIMARY KEY (id);
ALTER TABLE public.plot_commissions_v2 ADD CONSTRAINT plot_commissions_v2_pkey PRIMARY KEY (id);
ALTER TABLE public.plot_installment_payments ADD CONSTRAINT plot_installment_payments_pkey PRIMARY KEY (id);
ALTER TABLE public.plot_installments ADD CONSTRAINT plot_installments_pkey PRIMARY KEY (id);
ALTER TABLE public.plot_installments ADD CONSTRAINT plot_installments_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'partially_paid'::character varying, 'paid'::character varying, 'overdue'::character varying])::text[])));
ALTER TABLE public.plot_payments ADD CONSTRAINT plot_payments_pkey PRIMARY KEY (id);
ALTER TABLE public.plot_payments ADD CONSTRAINT plot_payments_payment_type_check CHECK (((payment_type)::text = ANY ((ARRAY['CASH'::character varying, 'BANK'::character varying, 'CHEQUE'::character varying])::text[])));
ALTER TABLE public.plot_registries ADD CONSTRAINT plot_registries_site_id_plot_no_key UNIQUE (site_id, plot_no);
ALTER TABLE public.plot_registries ADD CONSTRAINT plot_registries_pkey PRIMARY KEY (id);
ALTER TABLE public.plot_registry_payments ADD CONSTRAINT plot_registry_payments_pkey PRIMARY KEY (id);
ALTER TABLE public.plots ADD CONSTRAINT plots_pkey PRIMARY KEY (id);
ALTER TABLE public.plots ADD CONSTRAINT chk_plots_commission_type CHECK (((commission_type)::text = ANY ((ARRAY['PERCENTAGE'::character varying, 'FIXED'::character varying])::text[])));
ALTER TABLE public.plots ADD CONSTRAINT plots_interest_type_check CHECK (((interest_type)::text = ANY ((ARRAY['per_day'::character varying, 'per_month'::character varying, 'per_quarter'::character varying, 'per_year'::character varying])::text[])));
ALTER TABLE public.project_settings ADD CONSTRAINT project_settings_site_id_key UNIQUE (site_id);
ALTER TABLE public.project_settings ADD CONSTRAINT project_settings_pkey PRIMARY KEY (id);
ALTER TABLE public.sites ADD CONSTRAINT sites_code_key UNIQUE (code);
ALTER TABLE public.sites ADD CONSTRAINT sites_pkey PRIMARY KEY (id);
ALTER TABLE public.sites ADD CONSTRAINT sites_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'inactive'::character varying, 'completed'::character varying])::text[])));
ALTER TABLE public.team_members ADD CONSTRAINT team_members_pkey PRIMARY KEY (team_id, user_id);
ALTER TABLE public.teams ADD CONSTRAINT teams_pkey PRIMARY KEY (id);
ALTER TABLE public.user_approval_modules ADD CONSTRAINT user_approval_modules_user_id_module_key UNIQUE (user_id, module);
ALTER TABLE public.user_approval_modules ADD CONSTRAINT user_approval_modules_pkey PRIMARY KEY (id);
ALTER TABLE public.user_permissions ADD CONSTRAINT user_permissions_user_id_module_key UNIQUE (user_id, module);
ALTER TABLE public.user_permissions ADD CONSTRAINT user_permissions_pkey PRIMARY KEY (id);
ALTER TABLE public.user_sessions ADD CONSTRAINT user_sessions_pkey PRIMARY KEY (id);
ALTER TABLE public.user_sites ADD CONSTRAINT user_sites_user_id_site_id_key UNIQUE (user_id, site_id);
ALTER TABLE public.user_sites ADD CONSTRAINT user_sites_pkey PRIMARY KEY (id);
ALTER TABLE public.users ADD CONSTRAINT users_email_key UNIQUE (email);
ALTER TABLE public.users ADD CONSTRAINT users_pkey PRIMARY KEY (id);
ALTER TABLE public.users ADD CONSTRAINT users_role_check CHECK (((role)::text = ANY ((ARRAY['super_admin'::character varying, 'admin'::character varying, 'sub_admin'::character varying, 'agent'::character varying])::text[])));
ALTER TABLE public.vendor_commitments ADD CONSTRAINT vendor_commitments_pkey PRIMARY KEY (id);
ALTER TABLE public.vendor_commitments ADD CONSTRAINT vendor_commitments_contract_amount_check CHECK ((contract_amount >= (0)::numeric));
ALTER TABLE public.vendor_commitments ADD CONSTRAINT vendor_commitments_status_check CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'closed'::character varying, 'cancelled'::character varying])::text[])));
ALTER TABLE public.vendor_heads ADD CONSTRAINT vendor_heads_pkey PRIMARY KEY (id);
ALTER TABLE public.vendor_inventory_deliveries ADD CONSTRAINT vendor_inventory_deliveries_pkey PRIMARY KEY (id);
ALTER TABLE public.vendor_inventory_deliveries ADD CONSTRAINT vendor_inventory_deliveries_qty_check CHECK ((qty > (0)::numeric));
ALTER TABLE public.vendor_inventory_orders ADD CONSTRAINT vendor_inventory_orders_pkey PRIMARY KEY (id);
ALTER TABLE public.vendor_inventory_orders ADD CONSTRAINT vendor_inventory_orders_discount_amount_check CHECK ((discount_amount >= (0)::numeric));
ALTER TABLE public.vendor_inventory_orders ADD CONSTRAINT vendor_inventory_orders_discount_pct_check CHECK (((discount_pct >= (0)::numeric) AND (discount_pct <= (100)::numeric)));
ALTER TABLE public.vendor_inventory_orders ADD CONSTRAINT vendor_inventory_orders_qty_ordered_check CHECK ((qty_ordered >= (0)::numeric));
ALTER TABLE public.vendor_inventory_orders ADD CONSTRAINT vendor_inventory_orders_qty_received_check CHECK ((qty_received >= (0)::numeric));
ALTER TABLE public.vendor_inventory_orders ADD CONSTRAINT vendor_inventory_orders_rate_check CHECK ((rate >= (0)::numeric));
ALTER TABLE public.vendor_inventory_orders ADD CONSTRAINT vendor_inventory_orders_status_check CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'partial'::character varying, 'completed'::character varying, 'cancelled'::character varying])::text[])));
ALTER TABLE public.vendor_inventory_payments ADD CONSTRAINT vendor_inventory_payments_pkey PRIMARY KEY (id);
ALTER TABLE public.vendor_inventory_payments ADD CONSTRAINT vendor_inventory_payments_amount_check CHECK ((amount > (0)::numeric));
ALTER TABLE public.vendor_inventory_payments ADD CONSTRAINT vendor_inventory_payments_payment_mode_check CHECK (((payment_mode)::text = ANY ((ARRAY['cash'::character varying, 'bank'::character varying, 'upi'::character varying, 'cheque'::character varying, 'neft'::character varying, 'rtgs'::character varying, 'imps'::character varying, 'other'::character varying])::text[])));
ALTER TABLE public.vendor_payments ADD CONSTRAINT vendor_payments_pkey PRIMARY KEY (id);
ALTER TABLE public.vendor_payments ADD CONSTRAINT vendor_payments_amount_check CHECK ((amount > (0)::numeric));
ALTER TABLE public.vendor_payments ADD CONSTRAINT vendor_payments_payment_mode_check CHECK (((payment_mode)::text = ANY ((ARRAY['cash'::character varying, 'bank'::character varying, 'upi'::character varying, 'cheque'::character varying, 'neft'::character varying, 'rtgs'::character varying, 'imps'::character varying, 'other'::character varying])::text[])));
ALTER TABLE public.vendor_payments ADD CONSTRAINT vendor_payments_status_check CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'approved'::character varying, 'rejected'::character varying])::text[])));

-- ========================= FOREIGN KEYS ============================
ALTER TABLE public.agent_ledger_entries ADD CONSTRAINT agent_ledger_entries_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE public.bookings ADD CONSTRAINT bookings_agent_user_id_fkey FOREIGN KEY (agent_user_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.bookings ADD CONSTRAINT bookings_booking_agent_id_fkey FOREIGN KEY (booking_agent_id) REFERENCES members(id) ON DELETE SET NULL;
ALTER TABLE public.bookings ADD CONSTRAINT bookings_client_member_id_fkey FOREIGN KEY (client_member_id) REFERENCES members(id) ON DELETE RESTRICT;
ALTER TABLE public.bookings ADD CONSTRAINT bookings_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.bookings ADD CONSTRAINT bookings_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES plots(id) ON DELETE SET NULL;
ALTER TABLE public.bookings ADD CONSTRAINT bookings_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE RESTRICT;
ALTER TABLE public.bookings ADD CONSTRAINT bookings_team_id_fkey FOREIGN KEY (team_id) REFERENCES teams(id) ON DELETE SET NULL;
ALTER TABLE public.bookings ADD CONSTRAINT bookings_token_payment_id_fkey FOREIGN KEY (token_payment_id) REFERENCES plot_payments(id) ON DELETE SET NULL;
ALTER TABLE public.cash_flow_entries ADD CONSTRAINT cash_flow_entries_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.cash_flow_entries ADD CONSTRAINT cash_flow_entries_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.cash_flow_entries ADD CONSTRAINT cash_flow_entries_cash_flow_month_id_fkey FOREIGN KEY (cash_flow_month_id) REFERENCES cash_flow_months(id) ON DELETE CASCADE;
ALTER TABLE public.cash_flow_entries ADD CONSTRAINT cash_flow_entries_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.cash_flow_entries ADD CONSTRAINT cash_flow_entries_from_firm_id_fkey FOREIGN KEY (from_firm_id) REFERENCES firms(id) ON DELETE SET NULL;
ALTER TABLE public.cash_flow_entries ADD CONSTRAINT cash_flow_entries_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.cash_flow_entries ADD CONSTRAINT cash_flow_entries_to_firm_id_fkey FOREIGN KEY (to_firm_id) REFERENCES firms(id) ON DELETE SET NULL;
ALTER TABLE public.cash_flow_months ADD CONSTRAINT cash_flow_months_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.cash_flow_months ADD CONSTRAINT cash_flow_months_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.conversations ADD CONSTRAINT conversations_user1_id_fkey FOREIGN KEY (user1_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE public.conversations ADD CONSTRAINT conversations_user2_id_fkey FOREIGN KEY (user2_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE public.dashboard_component_permissions ADD CONSTRAINT dashboard_component_permissions_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE public.day_book ADD CONSTRAINT day_book_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.day_book ADD CONSTRAINT day_book_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.day_book ADD CONSTRAINT day_book_assigned_user_id_fkey FOREIGN KEY (assigned_user_id) REFERENCES members(id) ON DELETE SET NULL;
ALTER TABLE public.day_book ADD CONSTRAINT day_book_cash_flow_entry_id_fkey FOREIGN KEY (cash_flow_entry_id) REFERENCES cash_flow_entries(id) ON DELETE SET NULL;
ALTER TABLE public.day_book ADD CONSTRAINT day_book_commission_id_fkey FOREIGN KEY (commission_id) REFERENCES plot_commissions(id) ON DELETE SET NULL;
ALTER TABLE public.day_book ADD CONSTRAINT day_book_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.day_book ADD CONSTRAINT day_book_farmer_payment_id_fkey FOREIGN KEY (farmer_payment_id) REFERENCES farmer_payments(id) ON DELETE SET NULL;
ALTER TABLE public.day_book ADD CONSTRAINT day_book_firm_transaction_id_fkey FOREIGN KEY (firm_transaction_id) REFERENCES firm_transactions(id) ON DELETE SET NULL;
ALTER TABLE public.day_book ADD CONSTRAINT day_book_imprest_allocation_id_fkey FOREIGN KEY (imprest_allocation_id) REFERENCES imprest_allocations(id) ON DELETE SET NULL;
ALTER TABLE public.day_book ADD CONSTRAINT day_book_plot_payment_id_fkey FOREIGN KEY (plot_payment_id) REFERENCES plot_payments(id) ON DELETE SET NULL;
ALTER TABLE public.day_book ADD CONSTRAINT day_book_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.day_book ADD CONSTRAINT day_book_vendor_payment_id_fkey FOREIGN KEY (vendor_payment_id) REFERENCES vendor_payments(id) ON DELETE SET NULL;
ALTER TABLE public.day_book_daily_balance ADD CONSTRAINT day_book_daily_balance_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.documents ADD CONSTRAINT documents_client_member_id_fkey FOREIGN KEY (client_member_id) REFERENCES members(id) ON DELETE SET NULL;
ALTER TABLE public.documents ADD CONSTRAINT documents_kyc_case_id_fkey FOREIGN KEY (kyc_case_id) REFERENCES kyc_cases(id) ON DELETE CASCADE;
ALTER TABLE public.documents ADD CONSTRAINT documents_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES plots(id) ON DELETE SET NULL;
ALTER TABLE public.documents ADD CONSTRAINT documents_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE SET NULL;
ALTER TABLE public.documents ADD CONSTRAINT documents_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.edit_requests ADD CONSTRAINT edit_requests_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES users(id);
ALTER TABLE public.edit_requests ADD CONSTRAINT edit_requests_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES users(id);
ALTER TABLE public.edit_requests ADD CONSTRAINT edit_requests_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id);
ALTER TABLE public.excel_files ADD CONSTRAINT excel_files_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.excel_files ADD CONSTRAINT excel_files_folder_id_fkey FOREIGN KEY (folder_id) REFERENCES file_folders(id) ON DELETE SET NULL;
ALTER TABLE public.excel_files ADD CONSTRAINT excel_files_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.excel_files ADD CONSTRAINT excel_files_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.expenses ADD CONSTRAINT expenses_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.expenses ADD CONSTRAINT expenses_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.expenses ADD CONSTRAINT expenses_assigned_user_id_fkey FOREIGN KEY (assigned_user_id) REFERENCES members(id) ON DELETE SET NULL;
ALTER TABLE public.expenses ADD CONSTRAINT expenses_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.expenses ADD CONSTRAINT expenses_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.farmer_payments ADD CONSTRAINT farmer_payments_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.farmer_payments ADD CONSTRAINT farmer_payments_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.farmer_payments ADD CONSTRAINT farmer_payments_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id);
ALTER TABLE public.farmer_payments ADD CONSTRAINT farmer_payments_farmer_id_fkey FOREIGN KEY (farmer_id) REFERENCES farmers(id) ON DELETE CASCADE;
ALTER TABLE public.farmers ADD CONSTRAINT farmers_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.farmers ADD CONSTRAINT farmers_member_id_fkey FOREIGN KEY (member_id) REFERENCES members(id) ON DELETE SET NULL;
ALTER TABLE public.farmers ADD CONSTRAINT farmers_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.file_folders ADD CONSTRAINT file_folders_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.file_folders ADD CONSTRAINT file_folders_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES file_folders(id) ON DELETE CASCADE;
ALTER TABLE public.file_folders ADD CONSTRAINT file_folders_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.firm_transactions ADD CONSTRAINT firm_transactions_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.firm_transactions ADD CONSTRAINT firm_transactions_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.firm_transactions ADD CONSTRAINT firm_transactions_cash_flow_entry_id_fkey FOREIGN KEY (cash_flow_entry_id) REFERENCES cash_flow_entries(id) ON DELETE SET NULL;
ALTER TABLE public.firm_transactions ADD CONSTRAINT firm_transactions_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.firm_transactions ADD CONSTRAINT firm_transactions_firm_id_fkey FOREIGN KEY (firm_id) REFERENCES firms(id) ON DELETE CASCADE;
ALTER TABLE public.firm_transactions ADD CONSTRAINT firm_transactions_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.firm_transactions ADD CONSTRAINT firm_transactions_transfer_to_firm_id_fkey FOREIGN KEY (transfer_to_firm_id) REFERENCES firms(id) ON DELETE SET NULL;
ALTER TABLE public.firm_transactions ADD CONSTRAINT firm_transactions_transfer_to_site_id_fkey FOREIGN KEY (transfer_to_site_id) REFERENCES sites(id) ON DELETE SET NULL;
ALTER TABLE public.firms ADD CONSTRAINT firms_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.firms ADD CONSTRAINT firms_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.imprest_allocations ADD CONSTRAINT imprest_allocations_admin_id_fkey FOREIGN KEY (admin_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE public.imprest_allocations ADD CONSTRAINT imprest_allocations_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.imprest_allocations ADD CONSTRAINT imprest_allocations_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id);
ALTER TABLE public.imprest_allocations ADD CONSTRAINT imprest_allocations_sub_admin_id_fkey FOREIGN KEY (sub_admin_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE public.imprest_expense_requests ADD CONSTRAINT imprest_expense_requests_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.imprest_expense_requests ADD CONSTRAINT imprest_expense_requests_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.imprest_expense_requests ADD CONSTRAINT imprest_expense_requests_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.imprest_expense_requests ADD CONSTRAINT imprest_expense_requests_sub_admin_id_fkey FOREIGN KEY (sub_admin_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE public.imprest_ledger ADD CONSTRAINT imprest_ledger_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.imprest_ledger ADD CONSTRAINT imprest_ledger_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id);
ALTER TABLE public.imprest_ledger ADD CONSTRAINT imprest_ledger_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE public.imprest_returns ADD CONSTRAINT imprest_returns_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.imprest_returns ADD CONSTRAINT imprest_returns_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.imprest_returns ADD CONSTRAINT imprest_returns_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE SET NULL;
ALTER TABLE public.imprest_returns ADD CONSTRAINT imprest_returns_sub_admin_id_fkey FOREIGN KEY (sub_admin_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE public.kyc_cases ADD CONSTRAINT kyc_cases_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES bookings(id) ON DELETE CASCADE;
ALTER TABLE public.kyc_cases ADD CONSTRAINT kyc_cases_client_member_id_fkey FOREIGN KEY (client_member_id) REFERENCES members(id) ON DELETE SET NULL;
ALTER TABLE public.kyc_cases ADD CONSTRAINT kyc_cases_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE SET NULL;
ALTER TABLE public.kyc_cases ADD CONSTRAINT kyc_cases_verified_by_fkey FOREIGN KEY (verified_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.members ADD CONSTRAINT members_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.members ADD CONSTRAINT members_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.messages ADD CONSTRAINT messages_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE;
ALTER TABLE public.messages ADD CONSTRAINT messages_sender_id_fkey FOREIGN KEY (sender_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE public.ocr_results ADD CONSTRAINT ocr_results_document_id_fkey FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE;
ALTER TABLE public.plot_commission_payments ADD CONSTRAINT plot_commission_payments_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.plot_commission_payments ADD CONSTRAINT plot_commission_payments_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.plot_commission_payments ADD CONSTRAINT plot_commission_payments_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.plot_commission_payments ADD CONSTRAINT plot_commission_payments_plot_commission_id_fkey FOREIGN KEY (plot_commission_id) REFERENCES plot_commissions_v2(id) ON DELETE CASCADE;
ALTER TABLE public.plot_commission_payments ADD CONSTRAINT plot_commission_payments_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.plot_commissions ADD CONSTRAINT plot_commissions_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.plot_commissions ADD CONSTRAINT plot_commissions_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.plot_commissions ADD CONSTRAINT plot_commissions_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.plot_commissions ADD CONSTRAINT plot_commissions_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.plot_commissions_v2 ADD CONSTRAINT plot_commissions_v2_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES members(id);
ALTER TABLE public.plot_commissions_v2 ADD CONSTRAINT plot_commissions_v2_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.plot_commissions_v2 ADD CONSTRAINT plot_commissions_v2_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES plots(id) ON DELETE RESTRICT;
ALTER TABLE public.plot_commissions_v2 ADD CONSTRAINT plot_commissions_v2_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.plot_installment_payments ADD CONSTRAINT plot_installment_payments_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.plot_installment_payments ADD CONSTRAINT plot_installment_payments_installment_id_fkey FOREIGN KEY (installment_id) REFERENCES plot_installments(id) ON DELETE CASCADE;
ALTER TABLE public.plot_installment_payments ADD CONSTRAINT plot_installment_payments_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES plots(id) ON DELETE CASCADE;
ALTER TABLE public.plot_installments ADD CONSTRAINT plot_installments_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES plots(id) ON DELETE CASCADE;
ALTER TABLE public.plot_payments ADD CONSTRAINT plot_payments_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.plot_payments ADD CONSTRAINT plot_payments_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.plot_payments ADD CONSTRAINT plot_payments_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.plot_payments ADD CONSTRAINT plot_payments_plot_id_fkey FOREIGN KEY (plot_id) REFERENCES plots(id) ON DELETE CASCADE;
ALTER TABLE public.plot_payments ADD CONSTRAINT plot_payments_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.plot_registries ADD CONSTRAINT plot_registries_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.plot_registries ADD CONSTRAINT plot_registries_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id);
ALTER TABLE public.plot_registries ADD CONSTRAINT plot_registries_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.plot_registry_payments ADD CONSTRAINT plot_registry_payments_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.plot_registry_payments ADD CONSTRAINT plot_registry_payments_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id);
ALTER TABLE public.plot_registry_payments ADD CONSTRAINT plot_registry_payments_registry_id_fkey FOREIGN KEY (registry_id) REFERENCES plot_registries(id) ON DELETE CASCADE;
ALTER TABLE public.plot_registry_payments ADD CONSTRAINT plot_registry_payments_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.plot_registry_payments ADD CONSTRAINT plot_registry_payments_source_plot_payment_id_fkey FOREIGN KEY (source_plot_payment_id) REFERENCES plot_payments(id) ON DELETE SET NULL;
ALTER TABLE public.plots ADD CONSTRAINT plots_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.plots ADD CONSTRAINT plots_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.plots ADD CONSTRAINT plots_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.project_settings ADD CONSTRAINT project_settings_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.sites ADD CONSTRAINT sites_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.team_members ADD CONSTRAINT team_members_team_id_fkey FOREIGN KEY (team_id) REFERENCES teams(id) ON DELETE CASCADE;
ALTER TABLE public.team_members ADD CONSTRAINT team_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE public.teams ADD CONSTRAINT teams_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.teams ADD CONSTRAINT teams_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE SET NULL;
ALTER TABLE public.user_approval_modules ADD CONSTRAINT user_approval_modules_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE public.user_permissions ADD CONSTRAINT user_permissions_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE public.user_sessions ADD CONSTRAINT user_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE public.user_sites ADD CONSTRAINT user_sites_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.user_sites ADD CONSTRAINT user_sites_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE public.users ADD CONSTRAINT users_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.users ADD CONSTRAINT users_parent_user_id_fkey FOREIGN KEY (parent_user_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_commitments ADD CONSTRAINT vendor_commitments_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_commitments ADD CONSTRAINT vendor_commitments_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_commitments ADD CONSTRAINT vendor_commitments_head_id_fkey FOREIGN KEY (head_id) REFERENCES vendor_heads(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_commitments ADD CONSTRAINT vendor_commitments_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.vendor_commitments ADD CONSTRAINT vendor_commitments_vendor_member_id_fkey FOREIGN KEY (vendor_member_id) REFERENCES members(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_heads ADD CONSTRAINT vendor_heads_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_heads ADD CONSTRAINT vendor_heads_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.vendor_inventory_deliveries ADD CONSTRAINT vendor_inventory_deliveries_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_inventory_deliveries ADD CONSTRAINT vendor_inventory_deliveries_order_id_fkey FOREIGN KEY (order_id) REFERENCES vendor_inventory_orders(id) ON DELETE CASCADE;
ALTER TABLE public.vendor_inventory_deliveries ADD CONSTRAINT vendor_inventory_deliveries_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.vendor_inventory_orders ADD CONSTRAINT vendor_inventory_orders_commitment_id_fkey FOREIGN KEY (commitment_id) REFERENCES vendor_commitments(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_inventory_orders ADD CONSTRAINT vendor_inventory_orders_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_inventory_orders ADD CONSTRAINT vendor_inventory_orders_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.vendor_inventory_orders ADD CONSTRAINT vendor_inventory_orders_vendor_member_id_fkey FOREIGN KEY (vendor_member_id) REFERENCES members(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_inventory_payments ADD CONSTRAINT vendor_inventory_payments_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_inventory_payments ADD CONSTRAINT vendor_inventory_payments_order_id_fkey FOREIGN KEY (order_id) REFERENCES vendor_inventory_orders(id) ON DELETE CASCADE;
ALTER TABLE public.vendor_inventory_payments ADD CONSTRAINT vendor_inventory_payments_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;
ALTER TABLE public.vendor_payments ADD CONSTRAINT vendor_payments_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_payments ADD CONSTRAINT vendor_payments_assigned_admin_id_fkey FOREIGN KEY (assigned_admin_id) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_payments ADD CONSTRAINT vendor_payments_commitment_id_fkey FOREIGN KEY (commitment_id) REFERENCES vendor_commitments(id) ON DELETE CASCADE;
ALTER TABLE public.vendor_payments ADD CONSTRAINT vendor_payments_created_by_fkey FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE public.vendor_payments ADD CONSTRAINT vendor_payments_site_id_fkey FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE;

-- ============================ INDEXES ==============================
CREATE INDEX agent_activity_target_idx ON public.agent_activity_log USING btree (target_user_id, created_at DESC);
CREATE INDEX agent_ledger_type_idx ON public.agent_ledger_entries USING btree (entry_type, status);
CREATE INDEX agent_ledger_user_idx ON public.agent_ledger_entries USING btree (user_id, created_at DESC);
CREATE INDEX bookings_agent_user_idx ON public.bookings USING btree (agent_user_id);
CREATE INDEX bookings_team_idx ON public.bookings USING btree (team_id);
CREATE INDEX idx_bookings_agent ON public.bookings USING btree (booking_agent_id);
CREATE INDEX idx_bookings_client ON public.bookings USING btree (client_member_id);
CREATE INDEX idx_bookings_kyc_status ON public.bookings USING btree (kyc_status);
CREATE INDEX idx_bookings_plot_id ON public.bookings USING btree (plot_id);
CREATE INDEX idx_bookings_site_id ON public.bookings USING btree (site_id);
CREATE INDEX idx_bookings_status ON public.bookings USING btree (status);
CREATE INDEX idx_bookings_token_payment ON public.bookings USING btree (token_payment_id);
CREATE INDEX idx_cash_flow_entries_assigned_admin_id ON public.cash_flow_entries USING btree (assigned_admin_id);
CREATE INDEX idx_cash_flow_entries_status ON public.cash_flow_entries USING btree (status);
CREATE INDEX idx_cf_entries_site_date ON public.cash_flow_entries USING btree (site_id, date);
CREATE INDEX idx_cfe_active_month ON public.cash_flow_entries USING btree (cash_flow_month_id) WHERE (((cheque_status IS NULL) OR ((cheque_status)::text <> ALL ((ARRAY['BOUNCED'::character varying, 'RETURNED'::character varying])::text[]))) AND ((status IS NULL) OR ((status)::text <> 'rejected'::text)));
CREATE INDEX idx_cfe_date ON public.cash_flow_entries USING btree (date);
CREATE INDEX idx_cfe_firm_active ON public.cash_flow_entries USING btree (from_firm_id, to_firm_id) WHERE ((is_firm_transaction = true) AND ((cheque_status IS NULL) OR ((cheque_status)::text <> ALL ((ARRAY['BOUNCED'::character varying, 'RETURNED'::character varying])::text[]))) AND ((status IS NULL) OR ((status)::text <> 'rejected'::text)));
CREATE INDEX idx_cfe_from_firm_id ON public.cash_flow_entries USING btree (from_firm_id);
CREATE INDEX idx_cfe_is_firm_transaction ON public.cash_flow_entries USING btree (is_firm_transaction);
CREATE INDEX idx_cfe_month ON public.cash_flow_entries USING btree (cash_flow_month_id);
CREATE INDEX idx_cfe_month_cash_type ON public.cash_flow_entries USING btree (cash_flow_month_id, cash_type);
CREATE INDEX idx_cfe_month_date ON public.cash_flow_entries USING btree (cash_flow_month_id, date, created_at);
CREATE INDEX idx_cfe_site ON public.cash_flow_entries USING btree (site_id);
CREATE INDEX idx_cfe_site_particular ON public.cash_flow_entries USING btree (site_id, particular);
CREATE INDEX idx_cfe_to_firm_id ON public.cash_flow_entries USING btree (to_firm_id);
CREATE INDEX idx_cfe_unified_debit ON public.cash_flow_entries USING btree (site_id, date DESC) WHERE ((debit > (0)::numeric) AND ((cheque_status IS NULL) OR ((cheque_status)::text <> ALL ((ARRAY['BOUNCED'::character varying, 'RETURNED'::character varying])::text[]))) AND ((status IS NULL) OR ((status)::text <> 'rejected'::text)));
CREATE UNIQUE INDEX uq_cfe_source_module_source_id ON public.cash_flow_entries USING btree (source_module, source_id);
CREATE INDEX idx_cfm_ledger_name ON public.cash_flow_months USING btree (ledger_name);
CREATE INDEX idx_cfm_ledger_type ON public.cash_flow_months USING btree (ledger_type);
CREATE INDEX idx_cfm_period ON public.cash_flow_months USING btree (year, month);
CREATE INDEX idx_cfm_site ON public.cash_flow_months USING btree (site_id);
CREATE INDEX idx_cfm_site_ledger_period ON public.cash_flow_months USING btree (site_id, ledger_name, year DESC, month DESC);
CREATE INDEX idx_dcp_user_id ON public.dashboard_component_permissions USING btree (user_id);
CREATE INDEX idx_day_book_assigned_admin_id ON public.day_book USING btree (assigned_admin_id);
CREATE INDEX idx_day_book_cash_flow_entry_id ON public.day_book USING btree (cash_flow_entry_id);
CREATE INDEX idx_day_book_commission_id ON public.day_book USING btree (commission_id);
CREATE INDEX idx_day_book_date ON public.day_book USING btree (date);
CREATE INDEX idx_day_book_expense_unified ON public.day_book USING btree (site_id, date DESC) WHERE (((entry_type)::text = 'EXPENSE'::text) AND (farmer_payment_id IS NULL) AND (commission_id IS NULL) AND (vendor_payment_id IS NULL) AND ((cheque_status IS NULL) OR ((cheque_status)::text <> ALL ((ARRAY['BOUNCED'::character varying, 'RETURNED'::character varying])::text[]))) AND ((status)::text <> 'rejected'::text));
CREATE INDEX idx_day_book_farmer_payment ON public.day_book USING btree (farmer_payment_id);
CREATE INDEX idx_day_book_farmer_payment_id ON public.day_book USING btree (farmer_payment_id) WHERE (farmer_payment_id IS NOT NULL);
CREATE INDEX idx_day_book_firm_transaction_id ON public.day_book USING btree (firm_transaction_id);
CREATE INDEX idx_day_book_imprest_alloc ON public.day_book USING btree (imprest_allocation_id);
CREATE INDEX idx_day_book_plot_payment_id ON public.day_book USING btree (plot_payment_id);
CREATE INDEX idx_day_book_site ON public.day_book USING btree (site_id);
CREATE INDEX idx_day_book_site_date ON public.day_book USING btree (site_id, date);
CREATE INDEX idx_day_book_status ON public.day_book USING btree (status);
CREATE INDEX idx_day_book_type ON public.day_book USING btree (entry_type);
CREATE INDEX idx_day_book_vendor_payment_id ON public.day_book USING btree (vendor_payment_id);
CREATE INDEX idx_daybook_site_date ON public.day_book USING btree (site_id, date DESC);
CREATE INDEX idx_daybook_site_date_exact ON public.day_book USING btree (site_id, date);
CREATE INDEX idx_daybook_site_type ON public.day_book USING btree (site_id, entry_type);
CREATE INDEX idx_daybook_site_type_date ON public.day_book USING btree (site_id, entry_type, date DESC);
CREATE INDEX idx_dbdb_site_date ON public.day_book_daily_balance USING btree (site_id, date DESC);
CREATE INDEX idx_documents_case ON public.documents USING btree (kyc_case_id);
CREATE INDEX idx_documents_ocr_status ON public.documents USING btree (ocr_status);
CREATE INDEX idx_documents_plot ON public.documents USING btree (plot_id);
CREATE INDEX idx_edit_requests_module ON public.edit_requests USING btree (module, record_id);
CREATE INDEX idx_edit_requests_requested_by ON public.edit_requests USING btree (requested_by);
CREATE INDEX idx_edit_requests_site ON public.edit_requests USING btree (site_id);
CREATE INDEX idx_edit_requests_status ON public.edit_requests USING btree (status);
CREATE INDEX idx_excel_files_created_by ON public.excel_files USING btree (created_by);
CREATE INDEX idx_excel_files_folder ON public.excel_files USING btree (folder_id);
CREATE INDEX idx_excel_files_site ON public.excel_files USING btree (site_id);
CREATE INDEX idx_excel_files_updated_at ON public.excel_files USING btree (updated_at);
CREATE INDEX idx_exp_active_site ON public.expenses USING btree (site_id, date DESC) WHERE (((cheque_status IS NULL) OR ((cheque_status)::text <> ALL ((ARRAY['BOUNCED'::character varying, 'RETURNED'::character varying])::text[]))) AND ((status)::text <> 'rejected'::text));
CREATE INDEX idx_exp_category ON public.expenses USING btree (category);
CREATE INDEX idx_exp_date ON public.expenses USING btree (date);
CREATE INDEX idx_exp_mode ON public.expenses USING btree (payment_mode);
CREATE INDEX idx_exp_site ON public.expenses USING btree (site_id);
CREATE INDEX idx_exp_site_category_active ON public.expenses USING btree (site_id, category) WHERE ((category IS NOT NULL) AND ((category)::text <> ''::text));
CREATE INDEX idx_exp_site_date ON public.expenses USING btree (site_id, date);
CREATE INDEX idx_exp_site_from_entity ON public.expenses USING btree (site_id, from_entity) WHERE ((from_entity IS NOT NULL) AND ((from_entity)::text <> ''::text));
CREATE INDEX idx_exp_site_payment_mode ON public.expenses USING btree (site_id, payment_mode) WHERE ((payment_mode IS NOT NULL) AND ((payment_mode)::text <> ''::text));
CREATE INDEX idx_exp_site_status ON public.expenses USING btree (site_id, status, date DESC);
CREATE INDEX idx_exp_site_to_entity ON public.expenses USING btree (site_id, to_entity) WHERE ((to_entity IS NOT NULL) AND ((to_entity)::text <> ''::text));
CREATE INDEX idx_exp_status ON public.expenses USING btree (status);
CREATE INDEX idx_expenses_assigned_admin_id ON public.expenses USING btree (assigned_admin_id);
CREATE INDEX idx_expenses_site_category ON public.expenses USING btree (site_id, category);
CREATE INDEX idx_expenses_site_created ON public.expenses USING btree (site_id, created_at DESC);
CREATE INDEX idx_expenses_site_date ON public.expenses USING btree (site_id, date DESC);
CREATE INDEX idx_expenses_site_mode ON public.expenses USING btree (site_id, payment_mode);
CREATE INDEX idx_expenses_site_to ON public.expenses USING btree (site_id, to_entity);
CREATE INDEX idx_farmer_payments_active ON public.farmer_payments USING btree (farmer_id) WHERE ((cheque_status IS NULL) OR ((cheque_status)::text <> ALL ((ARRAY['BOUNCED'::character varying, 'RETURNED'::character varying])::text[])));
CREATE INDEX idx_farmer_payments_assigned_admin_id ON public.farmer_payments USING btree (assigned_admin_id);
CREATE INDEX idx_farmer_payments_date ON public.farmer_payments USING btree (date);
CREATE INDEX idx_farmer_payments_farmer ON public.farmer_payments USING btree (farmer_id);
CREATE INDEX idx_farmer_payments_farmer_date ON public.farmer_payments USING btree (farmer_id, date);
CREATE INDEX idx_farmer_payments_site_date ON public.farmer_payments USING btree (farmer_id, date);
CREATE INDEX idx_farmer_payments_status ON public.farmer_payments USING btree (status);
CREATE INDEX idx_fp_active_for_unified ON public.farmer_payments USING btree (farmer_id, date DESC) WHERE (((cheque_status IS NULL) OR ((cheque_status)::text <> ALL ((ARRAY['BOUNCED'::character varying, 'RETURNED'::character varying])::text[]))) AND ((status)::text <> 'rejected'::text));
CREATE INDEX idx_farmers_created ON public.farmers USING btree (created_by);
CREATE INDEX idx_farmers_site ON public.farmers USING btree (site_id);
CREATE INDEX idx_farmers_site_created_at ON public.farmers USING btree (site_id, created_at DESC);
CREATE INDEX idx_farmers_site_status ON public.farmers USING btree (site_id, status);
CREATE INDEX idx_farmers_status ON public.farmers USING btree (status);
CREATE INDEX idx_file_folders_created_by ON public.file_folders USING btree (created_by);
CREATE INDEX idx_file_folders_parent ON public.file_folders USING btree (parent_id);
CREATE INDEX idx_file_folders_site ON public.file_folders USING btree (site_id);
CREATE INDEX idx_firm_transactions_assigned_admin_id ON public.firm_transactions USING btree (assigned_admin_id);
CREATE INDEX idx_firm_transactions_status ON public.firm_transactions USING btree (status);
CREATE INDEX idx_firm_txn_site_date ON public.firm_transactions USING btree (site_id, date);
CREATE INDEX idx_ft_active_firm ON public.firm_transactions USING btree (firm_id) WHERE ((cheque_status IS NULL) OR ((cheque_status)::text <> ALL ((ARRAY['BOUNCED'::character varying, 'RETURNED'::character varying])::text[])));
CREATE INDEX idx_ft_cash_flow_entry_id ON public.firm_transactions USING btree (cash_flow_entry_id);
CREATE INDEX idx_ft_date ON public.firm_transactions USING btree (date);
CREATE INDEX idx_ft_firm ON public.firm_transactions USING btree (firm_id);
CREATE INDEX idx_ft_firm_date ON public.firm_transactions USING btree (firm_id, date, created_at);
CREATE INDEX idx_ft_is_firm_to_firm_transfer ON public.firm_transactions USING btree (is_firm_to_firm_transfer);
CREATE INDEX idx_ft_payment_mode ON public.firm_transactions USING btree (payment_mode);
CREATE INDEX idx_ft_remark ON public.firm_transactions USING btree (remark);
CREATE INDEX idx_ft_site ON public.firm_transactions USING btree (site_id);
CREATE INDEX idx_ft_site_date ON public.firm_transactions USING btree (site_id, date DESC, created_at DESC);
CREATE INDEX idx_ft_site_name ON public.firm_transactions USING btree (site_id, name) WHERE ((name IS NOT NULL) AND ((name)::text <> ''::text));
CREATE INDEX idx_ft_site_purpose ON public.firm_transactions USING btree (site_id, purpose) WHERE ((purpose IS NOT NULL) AND ((purpose)::text <> ''::text));
CREATE INDEX idx_ft_site_remark ON public.firm_transactions USING btree (site_id, remark) WHERE ((remark IS NOT NULL) AND ((remark)::text <> ''::text));
CREATE INDEX idx_ft_transfer_group_id ON public.firm_transactions USING btree (transfer_group_id);
CREATE INDEX idx_ft_transfer_to_firm_id ON public.firm_transactions USING btree (transfer_to_firm_id);
CREATE INDEX idx_firms_site ON public.firms USING btree (site_id);
CREATE INDEX idx_firms_site_name_upper ON public.firms USING btree (site_id, upper((name)::text));
CREATE INDEX idx_ia_admin ON public.imprest_allocations USING btree (admin_id);
CREATE INDEX idx_ia_status ON public.imprest_allocations USING btree (status);
CREATE INDEX idx_ia_sub_admin ON public.imprest_allocations USING btree (sub_admin_id);
CREATE INDEX idx_imprest_allocations_assigned_admin_id ON public.imprest_allocations USING btree (assigned_admin_id);
CREATE INDEX idx_ier_site ON public.imprest_expense_requests USING btree (site_id);
CREATE INDEX idx_ier_status ON public.imprest_expense_requests USING btree (status);
CREATE INDEX idx_ier_sub_admin ON public.imprest_expense_requests USING btree (sub_admin_id);
CREATE INDEX idx_imprest_expense_requests_assigned_admin_id ON public.imprest_expense_requests USING btree (assigned_admin_id);
CREATE INDEX idx_il_created ON public.imprest_ledger USING btree (created_at);
CREATE INDEX idx_il_type ON public.imprest_ledger USING btree (type);
CREATE INDEX idx_il_user ON public.imprest_ledger USING btree (user_id);
CREATE INDEX idx_ir_status ON public.imprest_returns USING btree (status);
CREATE INDEX idx_ir_sub_admin ON public.imprest_returns USING btree (sub_admin_id);
CREATE INDEX idx_kyc_cases_booking ON public.kyc_cases USING btree (booking_id);
CREATE INDEX idx_kyc_cases_status ON public.kyc_cases USING btree (status);
CREATE INDEX idx_member_categories_slug ON public.member_categories USING btree (slug);
CREATE INDEX idx_members_name ON public.members USING btree (site_id, full_name);
CREATE INDEX idx_members_phone ON public.members USING btree (phone);
CREATE INDEX idx_members_site ON public.members USING btree (site_id);
CREATE INDEX idx_members_site_created_at ON public.members USING btree (site_id, created_at DESC);
CREATE INDEX idx_members_site_full_name_upper ON public.members USING btree (site_id, upper((full_name)::text));
CREATE INDEX idx_members_site_phone_lookup ON public.members USING btree (site_id, phone) WHERE (phone IS NOT NULL);
CREATE INDEX idx_members_site_status ON public.members USING btree (site_id, status);
CREATE INDEX idx_members_site_type_status ON public.members USING btree (site_id, member_type, status);
CREATE INDEX idx_members_type ON public.members USING btree (member_type);
CREATE INDEX idx_ocr_results_document ON public.ocr_results USING btree (document_id);
CREATE INDEX idx_pcp_active_approved ON public.plot_commission_payments USING btree (plot_commission_id) WHERE (((status)::text = 'approved'::text) AND ((cheque_status IS NULL) OR ((cheque_status)::text <> ALL ((ARRAY['BOUNCED'::character varying, 'RETURNED'::character varying])::text[]))));
CREATE INDEX idx_pcp_active_for_unified ON public.plot_commission_payments USING btree (site_id, date DESC) WHERE (((cheque_status IS NULL) OR ((cheque_status)::text <> ALL ((ARRAY['BOUNCED'::character varying, 'RETURNED'::character varying])::text[]))) AND ((status)::text <> 'rejected'::text));
CREATE INDEX idx_pcp_master_date ON public.plot_commission_payments USING btree (plot_commission_id, date DESC, created_at DESC);
CREATE INDEX idx_pcp_master_id ON public.plot_commission_payments USING btree (plot_commission_id);
CREATE INDEX idx_pcp_master_status ON public.plot_commission_payments USING btree (plot_commission_id, status);
CREATE INDEX idx_pcp_site_id ON public.plot_commission_payments USING btree (site_id);
CREATE INDEX idx_pcp_status ON public.plot_commission_payments USING btree (status);
CREATE INDEX idx_plot_commission_payments_assigned_admin_id ON public.plot_commission_payments USING btree (assigned_admin_id);
CREATE INDEX idx_plot_commissions_assigned_admin_id ON public.plot_commissions USING btree (assigned_admin_id);
CREATE INDEX idx_plot_commissions_date ON public.plot_commissions USING btree (date);
CREATE INDEX idx_plot_commissions_plot ON public.plot_commissions USING btree (plot_no);
CREATE INDEX idx_plot_commissions_site ON public.plot_commissions USING btree (site_id);
CREATE INDEX idx_plot_commissions_site_date ON public.plot_commissions USING btree (site_id, date);
CREATE INDEX idx_plot_commissions_status ON public.plot_commissions USING btree (status);
CREATE INDEX idx_pcv2_agent_id ON public.plot_commissions_v2 USING btree (agent_id);
CREATE INDEX idx_pcv2_plot_agent ON public.plot_commissions_v2 USING btree (plot_id, agent_id);
CREATE INDEX idx_pcv2_plot_id ON public.plot_commissions_v2 USING btree (plot_id);
CREATE INDEX idx_pcv2_plot_site ON public.plot_commissions_v2 USING btree (plot_id, site_id);
CREATE INDEX idx_pcv2_site_created_at ON public.plot_commissions_v2 USING btree (site_id, created_at DESC);
CREATE INDEX idx_pcv2_site_id ON public.plot_commissions_v2 USING btree (site_id);
CREATE INDEX idx_pip_installment ON public.plot_installment_payments USING btree (installment_id);
CREATE INDEX idx_pip_plot ON public.plot_installment_payments USING btree (plot_id);
CREATE INDEX idx_pi_due_date ON public.plot_installments USING btree (due_date);
CREATE INDEX idx_pi_plot ON public.plot_installments USING btree (plot_id);
CREATE INDEX idx_pi_status ON public.plot_installments USING btree (status);
CREATE INDEX idx_plot_installments_plot ON public.plot_installments USING btree (plot_id, sort_order, due_date);
CREATE INDEX idx_plot_payments_assigned_admin_id ON public.plot_payments USING btree (assigned_admin_id);
CREATE INDEX idx_plot_payments_site_date ON public.plot_payments USING btree (site_id, date);
CREATE INDEX idx_plot_payments_status ON public.plot_payments USING btree (status);
CREATE INDEX idx_pp_active_plot ON public.plot_payments USING btree (plot_id) WHERE ((cheque_status IS NULL) OR ((cheque_status)::text <> ALL ((ARRAY['BOUNCED'::character varying, 'RETURNED'::character varying])::text[])));
CREATE INDEX idx_pp_date ON public.plot_payments USING btree (date);
CREATE INDEX idx_pp_plot ON public.plot_payments USING btree (plot_id);
CREATE INDEX idx_pp_plot_date ON public.plot_payments USING btree (plot_id, date, created_at);
CREATE INDEX idx_pp_plot_type ON public.plot_payments USING btree (plot_id, payment_type);
CREATE INDEX idx_pp_site ON public.plot_payments USING btree (site_id);
CREATE INDEX idx_pp_site_booked_by ON public.plot_payments USING btree (site_id, booked_by) WHERE ((booked_by IS NOT NULL) AND ((booked_by)::text <> ''::text));
CREATE INDEX idx_pp_site_payment_from ON public.plot_payments USING btree (site_id, payment_from) WHERE ((payment_from IS NOT NULL) AND ((payment_from)::text <> ''::text));
CREATE INDEX idx_pp_site_received_by ON public.plot_payments USING btree (site_id, received_by) WHERE ((received_by IS NOT NULL) AND ((received_by)::text <> ''::text));
CREATE INDEX idx_plot_registries_assigned_admin_id ON public.plot_registries USING btree (assigned_admin_id);
CREATE INDEX idx_plot_registries_plot ON public.plot_registries USING btree (site_id, plot_no);
CREATE INDEX idx_plot_registries_site ON public.plot_registries USING btree (site_id);
CREATE INDEX idx_pr_site_created_entry_date ON public.plot_registries USING btree (site_id, created_entry_date DESC);
CREATE INDEX idx_pr_site_customer ON public.plot_registries USING btree (site_id, customer_name) WHERE ((customer_name IS NOT NULL) AND ((customer_name)::text <> ''::text));
CREATE INDEX idx_pr_site_farmer ON public.plot_registries USING btree (site_id, farmer_name) WHERE ((farmer_name IS NOT NULL) AND ((farmer_name)::text <> ''::text));
CREATE INDEX idx_pr_site_plot_no_upper ON public.plot_registries USING btree (site_id, upper((plot_no)::text));
CREATE INDEX idx_plot_registry_payments_assigned_admin_id ON public.plot_registry_payments USING btree (assigned_admin_id);
CREATE INDEX idx_plot_registry_payments_registry ON public.plot_registry_payments USING btree (registry_id);
CREATE INDEX idx_plot_registry_payments_site ON public.plot_registry_payments USING btree (site_id);
CREATE INDEX idx_prp_registry_date ON public.plot_registry_payments USING btree (registry_id, payment_date, created_at);
CREATE INDEX idx_prp_site_mode ON public.plot_registry_payments USING btree (site_id, payment_mode) WHERE ((payment_mode IS NOT NULL) AND ((payment_mode)::text <> ''::text));
CREATE INDEX idx_prp_source_plot_payment ON public.plot_registry_payments USING btree (source_plot_payment_id) WHERE (source_plot_payment_id IS NOT NULL);
CREATE UNIQUE INDEX uq_prp_source_plot_payment ON public.plot_registry_payments USING btree (source_plot_payment_id) WHERE (source_plot_payment_id IS NOT NULL);
CREATE INDEX idx_plots_assigned_admin_id ON public.plots USING btree (assigned_admin_id);
CREATE INDEX idx_plots_fts_candidates ON public.plots USING btree (site_id) WHERE ((installments_enabled = true) AND (free_to_sale_days > 0) AND ((status)::text <> ALL ((ARRAY['UNDER CANCELLATION'::character varying, 'CANCELLED'::character varying, 'RESALE'::character varying, 'TRANSFERRED'::character varying, 'COMPANY'::character varying])::text[])));
CREATE INDEX idx_plots_plot_no ON public.plots USING btree (plot_no);
CREATE INDEX idx_plots_site ON public.plots USING btree (site_id);
CREATE INDEX idx_plots_site_plot_no_upper ON public.plots USING btree (site_id, upper((plot_no)::text));
CREATE INDEX idx_plots_site_status ON public.plots USING btree (site_id, status);
CREATE INDEX idx_plots_status ON public.plots USING btree (status);
CREATE INDEX idx_sites_created_by ON public.sites USING btree (created_by);
CREATE INDEX idx_sites_status ON public.sites USING btree (status);
CREATE INDEX team_members_user_idx ON public.team_members USING btree (user_id);
CREATE INDEX idx_user_sessions_login_time ON public.user_sessions USING btree (login_time);
CREATE INDEX idx_user_sessions_user_id ON public.user_sessions USING btree (user_id);
CREATE INDEX idx_user_sites_site ON public.user_sites USING btree (site_id);
CREATE INDEX idx_user_sites_user ON public.user_sites USING btree (user_id);
CREATE INDEX idx_users_created_by ON public.users USING btree (created_by);
CREATE INDEX idx_users_email ON public.users USING btree (email);
CREATE INDEX idx_users_role ON public.users USING btree (role);
CREATE INDEX users_parent_idx ON public.users USING btree (parent_user_id);
CREATE UNIQUE INDEX users_referral_code_uq ON public.users USING btree (referral_code) WHERE (referral_code IS NOT NULL);
CREATE INDEX users_team_idx ON public.users USING btree (team_id);
CREATE INDEX idx_vc_site_created_at ON public.vendor_commitments USING btree (site_id, created_at DESC);
CREATE INDEX idx_vc_site_head ON public.vendor_commitments USING btree (site_id, head_id);
CREATE INDEX idx_vc_site_status ON public.vendor_commitments USING btree (site_id, status);
CREATE INDEX idx_vendor_commitments_assigned_admin_id ON public.vendor_commitments USING btree (assigned_admin_id);
CREATE INDEX idx_vendor_commitments_site_id ON public.vendor_commitments USING btree (site_id);
CREATE INDEX idx_vendor_commitments_vendor_member_id ON public.vendor_commitments USING btree (vendor_member_id);
CREATE UNIQUE INDEX uq_vendor_heads_site_name ON public.vendor_heads USING btree (site_id, name);
CREATE INDEX idx_vid_order_id ON public.vendor_inventory_deliveries USING btree (order_id);
CREATE INDEX idx_vio_commitment_id ON public.vendor_inventory_orders USING btree (commitment_id);
CREATE INDEX idx_vio_commitment_site ON public.vendor_inventory_orders USING btree (commitment_id, site_id);
CREATE INDEX idx_vio_order_date ON public.vendor_inventory_orders USING btree (order_date DESC);
CREATE INDEX idx_vio_site_category ON public.vendor_inventory_orders USING btree (site_id, lower((item_category)::text));
CREATE INDEX idx_vio_site_id ON public.vendor_inventory_orders USING btree (site_id);
CREATE INDEX idx_vio_site_status_date ON public.vendor_inventory_orders USING btree (site_id, status, order_date DESC);
CREATE INDEX idx_vio_vendor_member_id ON public.vendor_inventory_orders USING btree (vendor_member_id);
CREATE INDEX idx_vipay_order_id ON public.vendor_inventory_payments USING btree (order_id);
CREATE INDEX idx_vipay_site_date ON public.vendor_inventory_payments USING btree (site_id, payment_date DESC);
CREATE INDEX idx_vendor_payments_assigned_admin_id ON public.vendor_payments USING btree (assigned_admin_id);
CREATE INDEX idx_vendor_payments_commitment_id ON public.vendor_payments USING btree (commitment_id);
CREATE INDEX idx_vendor_payments_date ON public.vendor_payments USING btree (payment_date);
CREATE INDEX idx_vendor_payments_site_id ON public.vendor_payments USING btree (site_id);
CREATE INDEX idx_vendor_payments_status ON public.vendor_payments USING btree (status);
CREATE INDEX idx_vp_active_for_unified ON public.vendor_payments USING btree (site_id, payment_date DESC) WHERE (((cheque_status IS NULL) OR ((cheque_status)::text <> ALL ((ARRAY['BOUNCED'::character varying, 'RETURNED'::character varying])::text[]))) AND ((status)::text <> 'rejected'::text));
CREATE INDEX idx_vp_commitment_active ON public.vendor_payments USING btree (commitment_id) WHERE ((cheque_status IS NULL) OR ((cheque_status)::text <> ALL ((ARRAY['BOUNCED'::character varying, 'RETURNED'::character varying])::text[])));
CREATE INDEX idx_vp_site_date ON public.vendor_payments USING btree (site_id, payment_date DESC);

-- ============================ TRIGGERS =============================
CREATE TRIGGER trg_cash_flow_entries_updated_at BEFORE UPDATE ON public.cash_flow_entries FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_cash_flow_months_updated_at BEFORE UPDATE ON public.cash_flow_months FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_day_book_updated_at BEFORE UPDATE ON public.day_book FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_sync_cfe_day_book AFTER INSERT OR DELETE OR UPDATE ON public.day_book FOR EACH ROW EXECUTE FUNCTION sync_cashflow_from_modules();
CREATE TRIGGER trg_sync_cfe_status_day_book AFTER INSERT OR UPDATE ON public.day_book FOR EACH ROW EXECUTE FUNCTION sync_cashflow_status_from_source();
CREATE TRIGGER trg_excel_files_updated_at BEFORE UPDATE ON public.excel_files FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_expenses_updated_at BEFORE UPDATE ON public.expenses FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_sync_cfe_expenses AFTER INSERT OR DELETE OR UPDATE ON public.expenses FOR EACH ROW EXECUTE FUNCTION sync_cashflow_from_modules();
CREATE TRIGGER trg_sync_cfe_status_expenses AFTER INSERT OR UPDATE ON public.expenses FOR EACH ROW EXECUTE FUNCTION sync_cashflow_status_from_source();
CREATE TRIGGER trg_farmer_payments_updated_at BEFORE UPDATE ON public.farmer_payments FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_sync_cfe_farmer_payments AFTER INSERT OR DELETE OR UPDATE ON public.farmer_payments FOR EACH ROW EXECUTE FUNCTION sync_cashflow_from_modules();
CREATE TRIGGER trg_farmers_updated_at BEFORE UPDATE ON public.farmers FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_firm_transactions_updated_at BEFORE UPDATE ON public.firm_transactions FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_sync_cfe_firm_transactions AFTER INSERT OR DELETE OR UPDATE ON public.firm_transactions FOR EACH ROW EXECUTE FUNCTION sync_cashflow_from_modules();
CREATE TRIGGER trg_sync_cfe_status_firm_transactions AFTER INSERT OR UPDATE ON public.firm_transactions FOR EACH ROW EXECUTE FUNCTION sync_cashflow_status_from_source();
CREATE TRIGGER trg_firms_updated_at BEFORE UPDATE ON public.firms FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_imprest_allocations_updated_at BEFORE UPDATE ON public.imprest_allocations FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_imprest_expense_requests_updated_at BEFORE UPDATE ON public.imprest_expense_requests FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_imprest_returns_updated_at BEFORE UPDATE ON public.imprest_returns FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER update_members_modtime BEFORE UPDATE ON public.members FOR EACH ROW EXECUTE FUNCTION update_modified_column();
CREATE TRIGGER trg_sync_cfe_plot_commission_payments AFTER INSERT OR DELETE OR UPDATE ON public.plot_commission_payments FOR EACH ROW EXECUTE FUNCTION sync_cashflow_from_modules();
CREATE TRIGGER trg_plot_commissions_updated_at BEFORE UPDATE ON public.plot_commissions FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_sync_cfe_plot_commissions AFTER INSERT OR DELETE OR UPDATE ON public.plot_commissions FOR EACH ROW EXECUTE FUNCTION sync_cashflow_from_modules();
CREATE TRIGGER trg_sync_cfe_plot_installment_payments AFTER INSERT OR DELETE OR UPDATE ON public.plot_installment_payments FOR EACH ROW EXECUTE FUNCTION sync_cashflow_from_modules();
CREATE TRIGGER trg_plot_installments_updated_at BEFORE UPDATE ON public.plot_installments FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_plot_payments_updated_at BEFORE UPDATE ON public.plot_payments FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_sync_cfe_plot_payments AFTER INSERT OR DELETE OR UPDATE ON public.plot_payments FOR EACH ROW EXECUTE FUNCTION sync_cashflow_from_modules();
CREATE TRIGGER trg_sync_cfe_status_plot_payments AFTER INSERT OR UPDATE ON public.plot_payments FOR EACH ROW EXECUTE FUNCTION sync_cashflow_status_from_source();
CREATE TRIGGER update_plot_registries_modtime BEFORE UPDATE ON public.plot_registries FOR EACH ROW EXECUTE FUNCTION update_modified_column();
CREATE TRIGGER trg_sync_cfe_plot_registry_payments AFTER INSERT OR DELETE OR UPDATE ON public.plot_registry_payments FOR EACH ROW EXECUTE FUNCTION sync_cashflow_from_modules();
CREATE TRIGGER update_plot_registry_payments_modtime BEFORE UPDATE ON public.plot_registry_payments FOR EACH ROW EXECUTE FUNCTION update_modified_column();
CREATE TRIGGER trg_plots_updated_at BEFORE UPDATE ON public.plots FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_sites_updated_at BEFORE UPDATE ON public.sites FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_sync_inv_delivery AFTER INSERT OR DELETE OR UPDATE ON public.vendor_inventory_deliveries FOR EACH ROW EXECUTE FUNCTION sync_vendor_inventory_order();
CREATE TRIGGER trg_sync_inv_payment AFTER INSERT OR DELETE OR UPDATE ON public.vendor_inventory_payments FOR EACH ROW EXECUTE FUNCTION sync_vendor_inventory_order();
CREATE TRIGGER trg_sync_cfe_status_vendor_payments AFTER INSERT OR UPDATE ON public.vendor_payments FOR EACH ROW EXECUTE FUNCTION sync_cashflow_status_from_source();
CREATE TRIGGER trg_sync_cfe_vendor_payments AFTER INSERT OR DELETE OR UPDATE ON public.vendor_payments FOR EACH ROW EXECUTE FUNCTION sync_cashflow_from_modules();
CREATE TRIGGER trg_sync_daybook_vendor_payments AFTER INSERT OR UPDATE ON public.vendor_payments FOR EACH ROW EXECUTE FUNCTION sync_daybook_from_vendor_payments();

-- ============================ END ==================================