-- Run on the installed sample database. All test changes are rolled back.
-- A failure raises an exception. Sequences can advance after rollback: this is normal.
BEGIN;
DO $$
DECLARE v_id bigint; v_owner bigint; v_count integer; v_audit bigint; v_contract uuid:= '22222222-2222-2222-2222-222222222222';
BEGIN
 SELECT count(*) INTO v_count FROM information_schema.tables WHERE table_schema='estate' AND table_type='BASE TABLE';
 IF v_count<>18 THEN RAISE EXCEPTION 'Expected 18 tables, got %',v_count; END IF;
 IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='estate' AND p.prokind='p')<10 THEN RAISE EXCEPTION 'Need >=10 procedures'; END IF;
 CALL estate.create_client('Тест перевірки','000','test@example.test',1);
 SELECT max(id) INTO v_id FROM estate.clients;
 CALL estate.update_client(v_id,'Оновлений тест','001','test@example.test',2);
 IF NOT EXISTS(SELECT 1 FROM estate.clients WHERE id=v_id AND updated_by=2 AND updated_at IS NOT NULL) THEN RAISE EXCEPTION 'Audit fields failed'; END IF;
 CALL estate.delete_client(v_id,2);
 IF EXISTS(SELECT 1 FROM estate.v_clients WHERE id=v_id) OR NOT EXISTS(SELECT 1 FROM estate.v_deleted_clients WHERE id=v_id AND deleted_by=2) THEN RAISE EXCEPTION 'Soft delete failed'; END IF;
 CALL estate.restore_client(v_id,1);
 IF NOT EXISTS(SELECT 1 FROM estate.v_clients WHERE id=v_id) THEN RAISE EXCEPTION 'Restore failed'; END IF;
 IF (SELECT count(*) FROM estate.audit_log WHERE table_name='clients' AND record_id=v_id::text)<>4 THEN RAISE EXCEPTION 'Audit trigger failed'; END IF;
 v_owner := v_id;
 CALL estate.create_property(1,'Тестова адреса',25,'тестпошук',v_id,1);
 SELECT max(id) INTO v_id FROM estate.properties;
 IF NOT EXISTS(SELECT 1 FROM estate.v_properties WHERE id=v_id AND to_tsvector('simple',address||' '||description) @@ plainto_tsquery('simple','тестпошук')) THEN RAISE EXCEPTION 'Search failed'; END IF;
 CALL estate.delete_property(v_id,1); CALL estate.restore_property(v_id,2);
 CALL estate.create_listing(v_id,'sale',1000,1);
 SELECT max(id) INTO v_id FROM estate.listings;
 CALL estate.change_listing_price(v_id,900,2);
 IF (SELECT count(*) FROM estate.listing_price_history WHERE listing_id=v_id)<>2 THEN RAISE EXCEPTION 'Price history failed'; END IF;
 CALL estate.delete_listing(v_id,1); CALL estate.restore_listing(v_id,2);
 SELECT count(*) INTO v_audit FROM estate.audit_log;
 -- Nested exception block is a PostgreSQL subtransaction.
 BEGIN
  CALL estate.create_contract(v_contract,v_id,900,1);
  CALL estate.add_contract_participant(v_contract,v_owner,'owner',1);
  CALL estate.add_contract_participant(v_contract,2,'customer',1);
  CALL estate.add_payment(v_contract,100,1);
  CALL estate.close_listing(v_id,1);
  CALL estate.add_payment(v_contract,-1,1);
  RAISE EXCEPTION 'Negative payment unexpectedly accepted';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
 IF EXISTS(SELECT 1 FROM estate.contracts WHERE id=v_contract) OR EXISTS(SELECT 1 FROM estate.payments WHERE contract_id=v_contract) OR EXISTS(SELECT 1 FROM estate.contract_participants WHERE contract_id=v_contract) THEN RAISE EXCEPTION 'Rollback failed'; END IF;
 IF NOT EXISTS(SELECT 1 FROM estate.v_active_listings WHERE id=v_id) OR (SELECT count(*) FROM estate.audit_log)<>v_audit THEN RAISE EXCEPTION 'Rollback of listing/audit failed'; END IF;
 -- Positive transaction and deferred integrity check.
 CALL estate.create_contract(v_contract,v_id,900,1);
 CALL estate.add_contract_participant(v_contract,v_owner,'owner',1);
 CALL estate.add_contract_participant(v_contract,2,'customer',1);
 CALL estate.add_payment(v_contract,100,1);
 CALL estate.close_listing(v_id,1);
 IF estate.contract_balance(v_contract)<>800 THEN RAISE EXCEPTION 'Balance failed'; END IF;
 BEGIN
  CALL estate.add_payment(v_contract,801,1);
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Overpayment unexpectedly accepted';
 EXCEPTION WHEN raise_exception THEN NULL;
 END;
 RAISE NOTICE 'All assertions passed; checking deferred constraints next.';
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
-- Inventory and index definitions for the defence.
SELECT p.proname,p.prokind FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='estate' ORDER BY p.prokind,p.proname;
SELECT indexname,indexdef FROM pg_indexes WHERE schemaname='estate' ORDER BY indexname;
EXPLAIN SELECT * FROM estate.v_active_listings WHERE price BETWEEN 1000000 AND 3000000;
EXPLAIN SELECT id FROM estate.v_properties WHERE to_tsvector('simple',address||' '||description) @@ plainto_tsquery('simple','квартира');
-- On a tiny sample Sequential Scan may be cheaper; index existence does not force usage.
