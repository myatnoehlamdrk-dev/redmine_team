# Redmine + TiDB Cloud Serverless (MySQL protocol)
#
# TiDB Serverless refuses insecure (plaintext) connections, so the database
# connection must use TLS with full certificate verification. The official
# redmine image generates config/database.yml from environment variables that
# cannot express `sslca` / `ssl_mode`, so we bake the settings into the image.
#
# Reasoning per setting:
#   sslca      : CA bundle used to validate the server certificate
#                (ISRG Root X1, the root of Let's Encrypt's chain, which signs
#                TiDB Cloud's gateway certificate).
#   ssl_mode   : verify_identity (NOT verify_ca - see the note below).
#
# NOTE: this image ships MariaDB Connector/C 3.4.9, which mysql2 warns
# "does not support ssl_mode 0". mysql2 therefore:
#   - silently IGNORES `ssl_mode: verify_ca` (mapped to ssl_mode 0), i.e. the
#     CA is loaded but the chain is never verified;
#   - honours `ssl_mode: verify_identity`, which DOES verify both the chain
#     against sslca and the hostname.
# Verified by test: with a bogus CA `verify_ca` connects anyway while
# `verify_identity` fails with "unable to get local issuer certificate", and
# connecting by raw IP fails with "Hostname verification failed".
#
FROM redmine:6.1.5

USER root

COPY isrgrootx1.pem /usr/local/share/ca-certificates/isrgrootx1.pem
RUN update-ca-certificates \
    && cp /etc/ssl/certs/ca-certificates.crt /usr/local/share/redmine-ca-certificates.crt \
    && chmod 644 /usr/local/share/redmine-ca-certificates.crt

COPY config/database.yml /usr/src/redmine/config/database.yml
COPY config/initializers/tidb_compat.rb /usr/src/redmine/config/initializers/tidb_compat.rb

RUN chown redmine:redmine /usr/src/redmine/config/database.yml \
    && chown redmine:redmine /usr/src/redmine/config/initializers/tidb_compat.rb

USER redmine
