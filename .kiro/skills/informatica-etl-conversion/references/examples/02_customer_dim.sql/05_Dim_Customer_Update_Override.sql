UPDATE dim_customer SET email = :TU.email, last_name = :TU.last_name, updated_at = LOCALTIMESTAMP WHERE customer_key = :TU.customer_key
