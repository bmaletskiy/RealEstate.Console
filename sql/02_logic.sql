BEGIN;
CREATE FUNCTION estate.require_actor(p_actor bigint) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM estate.users WHERE id=p_actor AND is_active) THEN
  RAISE EXCEPTION 'Користувач не існує або неактивний';
 END IF;
END $$;
CREATE FUNCTION estate.touch_row() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(NEW.updated_by);
 NEW.updated_at=clock_timestamp(); RETURN NEW;
END $$;
CREATE FUNCTION estate.audit_row() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 INSERT INTO estate.audit_log(table_name,record_id,operation,old_data,new_data,changed_by)
 VALUES(TG_TABLE_NAME,NEW.id::text,TG_OP,CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD) ELSE NULL END,to_jsonb(NEW),NEW.updated_by);
 RETURN NEW;
END $$;
CREATE FUNCTION estate.price_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='INSERT' THEN
  INSERT INTO estate.listing_price_history(listing_id,old_price,new_price,changed_by) VALUES(NEW.id,NULL,NEW.price,NEW.updated_by);
 ELSIF NEW.price IS DISTINCT FROM OLD.price THEN
  INSERT INTO estate.listing_price_history(listing_id,old_price,new_price,changed_by) VALUES(NEW.id,OLD.price,NEW.price,NEW.updated_by);
 END IF;
 RETURN NEW;
END $$;
CREATE FUNCTION estate.contract_balance(p_id uuid) RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT c.amount-COALESCE((SELECT sum(p.amount) FROM estate.payments p WHERE p.contract_id=c.id),0)
 FROM estate.contracts c WHERE c.id=p_id
$$;
CREATE TRIGGER tr_clients_touch BEFORE INSERT OR UPDATE ON estate.clients FOR EACH ROW EXECUTE FUNCTION estate.touch_row();
CREATE TRIGGER tr_clients_audit AFTER INSERT OR UPDATE ON estate.clients FOR EACH ROW EXECUTE FUNCTION estate.audit_row();
CREATE TRIGGER tr_properties_touch BEFORE INSERT OR UPDATE ON estate.properties FOR EACH ROW EXECUTE FUNCTION estate.touch_row();
CREATE TRIGGER tr_properties_audit AFTER INSERT OR UPDATE ON estate.properties FOR EACH ROW EXECUTE FUNCTION estate.audit_row();
CREATE TRIGGER tr_listings_touch BEFORE INSERT OR UPDATE ON estate.listings FOR EACH ROW EXECUTE FUNCTION estate.touch_row();
CREATE TRIGGER tr_listings_audit AFTER INSERT OR UPDATE ON estate.listings FOR EACH ROW EXECUTE FUNCTION estate.audit_row();
CREATE TRIGGER tr_contracts_touch BEFORE INSERT OR UPDATE ON estate.contracts FOR EACH ROW EXECUTE FUNCTION estate.touch_row();
CREATE TRIGGER tr_contracts_audit AFTER INSERT OR UPDATE ON estate.contracts FOR EACH ROW EXECUTE FUNCTION estate.audit_row();
CREATE TRIGGER tr_price_history AFTER INSERT OR UPDATE ON estate.listings FOR EACH ROW EXECUTE FUNCTION estate.price_history();

CREATE PROCEDURE estate.create_client(p_name text,p_phone text,p_email text,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); INSERT INTO estate.clients(full_name,phone,email,updated_by) VALUES(p_name,p_phone,NULLIF(p_email,''),p_actor);
END $$;

CREATE PROCEDURE estate.update_client(p_id bigint,p_name text,p_phone text,p_email text,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); UPDATE estate.clients SET full_name=p_name,phone=p_phone,email=NULLIF(p_email,''),updated_by=p_actor WHERE id=p_id AND deleted_at IS NULL; IF NOT FOUND THEN RAISE EXCEPTION 'Активного клієнта не знайдено'; END IF;
END $$;

CREATE PROCEDURE estate.create_property(p_type bigint,p_address text,p_area numeric,p_description text,p_owner bigint,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); PERFORM 1 FROM estate.clients WHERE id=p_owner AND deleted_at IS NULL FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Активного власника не знайдено'; END IF; WITH new_property AS (INSERT INTO estate.properties(type_id,address,area,description,updated_by) VALUES(p_type,p_address,p_area,p_description,p_actor) RETURNING id) INSERT INTO estate.property_owners(property_id,client_id) SELECT id,p_owner FROM new_property;
END $$;

CREATE PROCEDURE estate.update_property(p_id bigint,p_address text,p_area numeric,p_description text,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); UPDATE estate.properties SET address=p_address,area=p_area,description=p_description,updated_by=p_actor WHERE id=p_id AND deleted_at IS NULL; IF NOT FOUND THEN RAISE EXCEPTION 'Активного об’єкта не знайдено'; END IF;
END $$;

CREATE PROCEDURE estate.delete_client(p_id bigint,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); PERFORM 1 FROM estate.clients WHERE id=p_id AND deleted_at IS NULL FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Активного запису не знайдено'; END IF; IF EXISTS(SELECT 1 FROM estate.property_owners o JOIN estate.properties p ON p.id=o.property_id WHERE o.client_id=p_id AND p.deleted_at IS NULL) THEN RAISE EXCEPTION 'Спочатку видаліть активні об’єкти власника'; END IF; UPDATE estate.clients SET deleted_at=clock_timestamp(),deleted_by=p_actor,updated_by=p_actor WHERE id=p_id;
END $$;

CREATE PROCEDURE estate.restore_client(p_id bigint,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor);  UPDATE estate.clients SET deleted_at=NULL,deleted_by=NULL,updated_by=p_actor WHERE id=p_id AND deleted_at IS NOT NULL; IF NOT FOUND THEN RAISE EXCEPTION 'Видаленого запису не знайдено'; END IF;
END $$;

CREATE PROCEDURE estate.delete_property(p_id bigint,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); PERFORM 1 FROM estate.properties WHERE id=p_id AND deleted_at IS NULL FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Активного запису не знайдено'; END IF; IF EXISTS(SELECT 1 FROM estate.listings WHERE property_id=p_id AND deleted_at IS NULL AND status='active') THEN RAISE EXCEPTION 'Спочатку видаліть активні оголошення'; END IF; UPDATE estate.properties SET deleted_at=clock_timestamp(),deleted_by=p_actor,updated_by=p_actor WHERE id=p_id;
END $$;

CREATE PROCEDURE estate.restore_property(p_id bigint,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); IF EXISTS(SELECT 1 FROM estate.property_owners o JOIN estate.clients c ON c.id=o.client_id WHERE o.property_id=p_id AND c.deleted_at IS NOT NULL) THEN RAISE EXCEPTION 'Спочатку відновіть власників'; END IF; UPDATE estate.properties SET deleted_at=NULL,deleted_by=NULL,updated_by=p_actor WHERE id=p_id AND deleted_at IS NOT NULL; IF NOT FOUND THEN RAISE EXCEPTION 'Видаленого запису не знайдено'; END IF;
END $$;

CREATE PROCEDURE estate.delete_listing(p_id bigint,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); PERFORM 1 FROM estate.listings WHERE id=p_id AND deleted_at IS NULL FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Активного запису не знайдено'; END IF;  UPDATE estate.listings SET deleted_at=clock_timestamp(),deleted_by=p_actor,updated_by=p_actor WHERE id=p_id;
END $$;

CREATE PROCEDURE estate.restore_listing(p_id bigint,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); PERFORM 1 FROM estate.properties p JOIN estate.listings l ON l.property_id=p.id WHERE l.id=p_id AND p.deleted_at IS NULL FOR UPDATE OF p; IF NOT FOUND THEN RAISE EXCEPTION 'Спочатку відновіть об’єкт'; END IF; UPDATE estate.listings SET deleted_at=NULL,deleted_by=NULL,updated_by=p_actor WHERE id=p_id AND deleted_at IS NOT NULL; IF NOT FOUND THEN RAISE EXCEPTION 'Видаленого запису не знайдено'; END IF;
END $$;

CREATE PROCEDURE estate.create_listing(p_property bigint,p_kind text,p_price numeric,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); PERFORM 1 FROM estate.properties WHERE id=p_property AND deleted_at IS NULL FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Активного об’єкта не знайдено'; END IF; INSERT INTO estate.listings(property_id,agent_id,kind,price,updated_by) VALUES(p_property,p_actor,p_kind,p_price,p_actor);
END $$;

CREATE PROCEDURE estate.change_listing_price(p_id bigint,p_price numeric,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); UPDATE estate.listings SET price=p_price,updated_by=p_actor WHERE id=p_id AND deleted_at IS NULL AND status='active'; IF NOT FOUND THEN RAISE EXCEPTION 'Активного оголошення не знайдено'; END IF;
END $$;

CREATE PROCEDURE estate.create_contract(p_id uuid,p_listing bigint,p_amount numeric,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); PERFORM 1 FROM estate.listings l JOIN estate.properties p ON p.id=l.property_id WHERE l.id=p_listing AND l.deleted_at IS NULL AND l.status='active' AND p.deleted_at IS NULL FOR UPDATE OF l,p; IF NOT FOUND THEN RAISE EXCEPTION 'Оголошення недоступне'; END IF; INSERT INTO estate.contracts(id,listing_id,amount,updated_by) VALUES(p_id,p_listing,p_amount,p_actor);
END $$;

CREATE PROCEDURE estate.add_contract_participant(p_contract uuid,p_client bigint,p_role text,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); PERFORM 1 FROM estate.clients WHERE id=p_client AND deleted_at IS NULL FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Активного клієнта не знайдено'; END IF; IF p_role='owner' AND NOT EXISTS(SELECT 1 FROM estate.contracts c JOIN estate.listings l ON l.id=c.listing_id JOIN estate.property_owners o ON o.property_id=l.property_id WHERE c.id=p_contract AND o.client_id=p_client) THEN RAISE EXCEPTION 'Клієнт не є власником'; END IF; INSERT INTO estate.contract_participants(contract_id,client_id,role) VALUES(p_contract,p_client,p_role); UPDATE estate.contracts SET updated_by=p_actor WHERE id=p_contract;
END $$;

CREATE PROCEDURE estate.add_payment(p_contract uuid,p_amount numeric,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); PERFORM 1 FROM estate.contracts WHERE id=p_contract FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Договір не знайдено'; END IF; IF p_amount>estate.contract_balance(p_contract) THEN RAISE EXCEPTION 'Платіж перевищує залишок'; END IF; INSERT INTO estate.payments(contract_id,amount,recorded_by) VALUES(p_contract,p_amount,p_actor); UPDATE estate.contracts SET updated_by=p_actor WHERE id=p_contract;
END $$;

CREATE PROCEDURE estate.close_listing(p_id bigint,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); IF NOT EXISTS(SELECT 1 FROM estate.contracts WHERE listing_id=p_id) THEN RAISE EXCEPTION 'Договір не створено'; END IF; UPDATE estate.listings SET status='closed',updated_by=p_actor WHERE id=p_id AND status='active' AND deleted_at IS NULL; IF NOT FOUND THEN RAISE EXCEPTION 'Активного оголошення не знайдено'; END IF;
END $$;

CREATE PROCEDURE estate.schedule_viewing(p_listing bigint,p_client bigint,p_start timestamptz,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); IF p_start<=now() THEN RAISE EXCEPTION 'Оберіть майбутній час'; END IF; PERFORM 1 FROM estate.listings WHERE id=p_listing AND status='active' AND deleted_at IS NULL FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Активного оголошення не знайдено'; END IF; PERFORM 1 FROM estate.clients WHERE id=p_client AND deleted_at IS NULL FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Клієнта не знайдено'; END IF; INSERT INTO estate.viewing_appointments(listing_id,client_id,agent_id,starts_at) VALUES(p_listing,p_client,p_actor,p_start);
END $$;

CREATE PROCEDURE estate.create_offer(p_listing bigint,p_client bigint,p_amount numeric,p_actor bigint) LANGUAGE plpgsql AS $$
BEGIN
 PERFORM estate.require_actor(p_actor); PERFORM 1 FROM estate.listings WHERE id=p_listing AND status='active' AND deleted_at IS NULL FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Активного оголошення не знайдено'; END IF; PERFORM 1 FROM estate.clients WHERE id=p_client AND deleted_at IS NULL FOR UPDATE; IF NOT FOUND THEN RAISE EXCEPTION 'Клієнта не знайдено'; END IF; INSERT INTO estate.offers(listing_id,client_id,amount) VALUES(p_listing,p_client,p_amount);
END $$;

CREATE FUNCTION estate.validate_contract() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM estate.contract_participants WHERE contract_id=NEW.id AND role='customer')
 OR NOT EXISTS(SELECT 1 FROM estate.contract_participants WHERE contract_id=NEW.id AND role='owner')
 OR EXISTS(SELECT 1 FROM estate.property_owners o JOIN estate.listings l ON l.property_id=o.property_id
           WHERE l.id=NEW.listing_id AND NOT EXISTS(SELECT 1 FROM estate.contract_participants cp WHERE cp.contract_id=NEW.id AND cp.client_id=o.client_id AND cp.role='owner'))
 OR NOT EXISTS(SELECT 1 FROM estate.listings WHERE id=NEW.listing_id AND status='closed') THEN
  RAISE EXCEPTION 'Договір потребує покупця/орендаря, усіх власників та закритого оголошення';
 END IF;
 RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER tr_contract_complete AFTER INSERT OR UPDATE ON estate.contracts
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION estate.validate_contract();
CREATE VIEW estate.v_users AS SELECT id,full_name,login FROM estate.users WHERE is_active;
CREATE VIEW estate.v_property_types AS SELECT * FROM estate.property_types;
CREATE VIEW estate.v_clients AS SELECT * FROM estate.clients WHERE deleted_at IS NULL;
CREATE VIEW estate.v_deleted_clients AS SELECT * FROM estate.clients WHERE deleted_at IS NOT NULL;
CREATE VIEW estate.v_properties AS SELECT p.*,t.name AS type_name FROM estate.properties p JOIN estate.property_types t ON t.id=p.type_id WHERE p.deleted_at IS NULL;
CREATE VIEW estate.v_deleted_properties AS SELECT * FROM estate.properties WHERE deleted_at IS NOT NULL;
CREATE VIEW estate.v_property_owners AS SELECT o.property_id,o.client_id,c.full_name FROM estate.property_owners o JOIN estate.clients c ON c.id=o.client_id WHERE c.deleted_at IS NULL;
CREATE VIEW estate.v_active_listings AS SELECT l.*,p.address FROM estate.listings l JOIN estate.properties p ON p.id=l.property_id WHERE l.deleted_at IS NULL AND l.status='active' AND p.deleted_at IS NULL;
CREATE VIEW estate.v_deleted_listings AS SELECT * FROM estate.listings WHERE deleted_at IS NOT NULL;
CREATE VIEW estate.v_contracts AS SELECT c.*,estate.contract_balance(c.id) AS balance FROM estate.contracts c;
CREATE VIEW estate.v_payments AS SELECT * FROM estate.payments;
CREATE VIEW estate.v_participants AS SELECT cp.*,c.full_name FROM estate.contract_participants cp JOIN estate.clients c ON c.id=cp.client_id;
CREATE VIEW estate.v_audit AS SELECT * FROM estate.audit_log;
CREATE VIEW estate.v_price_history AS SELECT * FROM estate.listing_price_history;
CREATE VIEW estate.v_viewings AS SELECT * FROM estate.viewing_appointments;
CREATE VIEW estate.v_offers AS SELECT * FROM estate.offers;
COMMIT;
