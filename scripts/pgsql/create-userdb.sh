#!/bin/bash
pgurl="postgres://postgres:${OPERATOR_PASSWORD}@${FLY_APP_NAME}.internal:5432"
cdopts="ENCODING='UTF8' LC_COLLATE='C' LC_CTYPE='C' TEMPLATE=template0"
pguser=$(cut -d: -f1 <<<"$1")
pgpass=$(cut -d: -f2 <<<"$1")
if ! psql "$pgurl" -c "REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;"; then
  echo "PG_FAILED to revoke connect on template1 from public."
  exit 1
fi
if ! psql "$pgurl" -c "create user $pguser with encrypted password '$pgpass';"; then
  echo "PG_FAILED to create $pguser user"
  exit 1
fi
if ! psql "$pgurl" -c "create database $pguser WITH OWNER '$pguser' $cdopts;"; then
  echo "PG_FAILED to create $1 database"
  exit 1
fi
if ! psql "$pgurl" -c "REVOKE CONNECT ON DATABASE $pguser FROM PUBLIC;"; then
  echo "PG_FAILED to create $1 database"
  exit 1
fi
if ! psql "$pgurl" -c "grant all privileges on database $pguser to $pguser;"; then
  echo "PG_FAILED to grant privileges"
  exit 1
fi
exit 0
